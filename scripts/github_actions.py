#!/usr/bin/python3
"""
scripts/github_actions.py
Fetch the latest GitHub Actions workflow runs for a list of repositories.

Outputs a single normalized JSON object to stdout (same shape the panel
uses for Azure DevOps pipelines). Exits 0 on success, 1 on failure.

Usage:
    github_actions.py [--mock [--mock-error missing-dependency|generic]]
                      [--repo OWNER/REPO [--repo OWNER2/REPO2 ...]]

Authentication:
    Uses the existing `gh` CLI session (`gh auth login`).
    No credentials are stored, read or printed by this script.

Dependencies:
    - GitHub CLI (`gh`; Arch package: github-cli)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ── Constants ─────────────────────────────────────────────────────────────────

PROVIDER  = "github-actions"
MOCK_FILE = Path(__file__).parent.parent / "mock" / "github-actions.json"

TRUSTED_PATH = "/usr/local/bin:/usr/bin:/bin"

MAX_STDOUT_BYTES = 512 * 1024   # 512 KB — producer-side cap (reject at cap+1)
MAX_STDERR_BYTES = 16 * 1024    # 16 KB
MAX_OUTPUT_BYTES = 256 * 1024   # 256 KB — cap on final JSON output to QML
MAX_REPOS        = 20           # hard cap on number of --repo entries processed
MAX_RUNS         = 30           # recent runs requested per repository
MAX_WORKFLOWS    = 15           # workflows shown per repository
MAX_TEXT_LEN     = 120          # names / branches / events shown in the panel
CMD_TIMEOUT      = 30           # seconds — wall-clock deadline per gh call
CHECK_TIMEOUT    = 10           # seconds — deadline for `gh auth status`

# GitHub owner: alphanumerics and single hyphens, max 39 chars, no leading
# hyphen. Repository: alphanumerics, '-', '_' and '.', max 100 chars.
REPO_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$")

RUN_FIELDS = (
    "databaseId,workflowDatabaseId,workflowName,displayTitle,status,"
    "conclusion,headBranch,event,createdAt,startedAt,updatedAt,url"
)

ALLOWED_URL_PREFIX = "https://github.com/"

FAILED_CONCLUSIONS  = {"failure", "timed_out", "startup_failure"}
SKIPPED_CONCLUSIONS = {"skipped", "neutral", "stale"}

# Environment variables forwarded to gh, besides a fixed PATH. They are what
# gh needs to find the person's own login (config dir, Secret Service
# keyring via D-Bus) — nothing else from the parent environment is passed.
FORWARDED_ENV = (
    "HOME", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS",
    "GH_CONFIG_DIR", "GH_TOKEN", "GITHUB_TOKEN",
)


# ── Module-level cached gh path ───────────────────────────────────────────────

_GH_PATH: str | None = None
_GH_CONFIGURED: str = ""      # --gh-path (github.ghPath in config.json), if any

# Per-user install locations probed after the trusted system PATH. Only
# fixed, well-known places inside the user's own home (mise, ~/.local/bin).
_HOME_GH_PATTERNS = (
    ".local/bin/gh",
    ".local/share/mise/installs/gh/latest/bin/gh",
    ".local/share/mise/installs/gh/latest/*/bin/gh",
)


def _usable_gh(path: str) -> str | None:
    """Return the resolved path if `path` is an acceptable gh executable.

    Requirements: absolute, resolves to a regular executable file owned by
    the current user (or root) that is not world-writable, inside a directory
    that is not world-writable (unless sticky) either. This
    keeps "any path" from becoming "run whatever is dropped in a shared
    folder".
    """
    try:
        if not path or len(path) > 300 or not os.path.isabs(path):
            return None
        if any((not ch.isprintable()) for ch in path):
            return None
        real = os.path.realpath(path)
        st = os.stat(real)
        if not os.path.isfile(real) or not os.access(real, os.X_OK):
            return None
        if st.st_uid not in (0, os.geteuid()) or st.st_mode & 0o002:
            return None
        dst = os.stat(os.path.dirname(real))
        if dst.st_mode & 0o002 and not dst.st_mode & 0o1000:
            return None
        return real
    except OSError:
        return None


def _discover_home_gh() -> str | None:
    home = os.environ.get("HOME", "")
    if not home or not os.path.isabs(home):
        return None
    import glob
    for pattern in _HOME_GH_PATTERNS:
        for candidate in sorted(glob.glob(os.path.join(home, pattern)), reverse=True):
            found = _usable_gh(candidate)
            if found:
                return found
    return None


def _find_gh() -> str:
    global _GH_PATH
    if _GH_PATH is None:
        if _GH_CONFIGURED:
            path = _usable_gh(_GH_CONFIGURED)
            if not path:
                raise ValueError(
                    "github.ghPath is not a usable gh executable (needs an absolute path to an "
                    "executable you own that is not world-writable)")
        else:
            path = shutil.which("gh", path=TRUSTED_PATH) or _discover_home_gh()
        if not path:
            raise RuntimeError("gh CLI not found — install github-cli")
        _GH_PATH = path
    return _GH_PATH


# ── Active-process registry for signal-based cleanup ──────────────────────────
#
# gh is started with start_new_session=True so it lives in its own session,
# independent of this script's session. If this script itself is killed
# (e.g. QML calling terminate() on the Python process), the gh child would
# be orphaned and keep running unless we explicitly kill it here first.

_active_procs: set[subprocess.Popen] = set()


def _register_proc(proc: subprocess.Popen) -> None:
    _active_procs.add(proc)


def _unregister_proc(proc: subprocess.Popen) -> None:
    _active_procs.discard(proc)


def _kill_pgroup(proc: subprocess.Popen) -> None:
    """Kill the entire process group — handles gh spawning child processes."""
    try:
        pgid = os.getpgid(proc.pid)
        os.killpg(pgid, signal.SIGKILL)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


def _cleanup_and_exit(signum, frame) -> None:
    """
    Signal handler: if this script is terminated, kill every active
    gh child process group before exiting, so nothing is orphaned.
    """
    for proc in list(_active_procs):
        _kill_pgroup(proc)
    sys.exit(1)


signal.signal(signal.SIGTERM, _cleanup_and_exit)
signal.signal(signal.SIGINT,  _cleanup_and_exit)


# ── Security helpers ──────────────────────────────────────────────────────────

def _trusted_env() -> dict[str, str]:
    env = {
        "PATH":                  TRUSTED_PATH,
        "GH_HOST":               "github.com",  # repos always resolve on github.com
        "GH_PROMPT_DISABLED":    "1",
        "GH_NO_UPDATE_NOTIFIER": "1",
        "GH_SPINNER_DISABLED":   "1",
        "NO_COLOR":              "1",
    }
    for key in FORWARDED_ENV:
        value = os.environ.get(key)
        if value:
            env[key] = value
    return env


def _validate_repo(repo: str) -> bool:
    if not isinstance(repo, str) or not REPO_RE.match(repo):
        return False
    name = repo.split("/", 1)[1]
    return name not in (".", "..")


def _scrub(text: str) -> str:
    text = re.sub(r"gh[pousr]_[A-Za-z0-9]{20,}", "[REDACTED]", text)
    text = re.sub(r"github_pat_[A-Za-z0-9_]{20,}", "[REDACTED]", text)
    text = re.sub(r"[A-Za-z0-9+/]{40,}={0,2}", "[REDACTED]", text)
    return text


def _clean(value: Any, limit: int = MAX_TEXT_LEN) -> str:
    """Printable ASCII/Unicode text only, bounded length."""
    if not isinstance(value, str):
        return ""
    value = "".join(ch for ch in value if ch.isprintable())
    return value[:limit]


# ── Concurrent, deadline-bound stream draining ────────────────────────────────

def _drain_streams(
    proc: subprocess.Popen,
    cap_out: int,
    cap_err: int,
    deadline_s: float,
) -> tuple[bytes, bytes, bool, bool]:
    """
    Read stdout and stderr concurrently using select.poll(), bounded by a
    single wall-clock deadline. This avoids the sequential-read hang where
    a child that never closes stdout blocks forever before stderr — or the
    timeout — is ever reached, and avoids the pipe-buffer deadlock where the
    child fills stderr while we are blocked reading stdout.

    Returns (stdout_bytes, stderr_bytes, timed_out, overflowed).
    Caps are enforced during the read (producer-side), not after.
    """
    stdout_fd = proc.stdout.fileno()
    stderr_fd = proc.stderr.fileno()

    poller = select.poll()
    poller.register(stdout_fd, select.POLLIN | select.POLLHUP | select.POLLERR)
    poller.register(stderr_fd, select.POLLIN | select.POLLHUP | select.POLLERR)

    buffers: dict[int, bytearray] = {stdout_fd: bytearray(), stderr_fd: bytearray()}
    caps:    dict[int, int]       = {stdout_fd: cap_out, stderr_fd: cap_err}
    open_fds = {stdout_fd, stderr_fd}

    start = time.monotonic()

    while open_fds:
        remaining = deadline_s - (time.monotonic() - start)
        if remaining <= 0:
            return bytes(buffers[stdout_fd]), bytes(buffers[stderr_fd]), True, False

        events = poller.poll(remaining * 1000)  # milliseconds
        if not events:
            continue  # loop re-checks remaining time

        for fd, ev in events:
            if ev & select.POLLIN:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    chunk = b""
                if not chunk:
                    poller.unregister(fd)
                    open_fds.discard(fd)
                    continue
                buffers[fd].extend(chunk)
                if len(buffers[fd]) > caps[fd]:
                    return (
                        bytes(buffers[stdout_fd])[:caps[stdout_fd]],
                        bytes(buffers[stderr_fd])[:caps[stderr_fd]],
                        False,
                        True,
                    )
            elif ev & (select.POLLHUP | select.POLLERR):
                poller.unregister(fd)
                open_fds.discard(fd)

    return bytes(buffers[stdout_fd]), bytes(buffers[stderr_fd]), False, False



# ── Running gh ────────────────────────────────────────────────────────────────

def _exec(cmd: list[str], deadline_s: float) -> tuple[int, bytes, bytes, str | None]:
    """
    Run a command with concurrently-drained, byte-capped, deadline-bound
    output. Kills the whole process group on overflow or timeout.
    Returns (returncode, stdout, stderr, problem) where problem is None or a
    short human-readable reason. Never raises.
    """
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            env=_trusted_env(),
            start_new_session=True,   # own process group — killable as a tree
        )
    except FileNotFoundError:
        return -1, b"", b"", "gh CLI not found — install github-cli"
    except Exception as exc:
        return -1, b"", b"", _clean(str(exc), 200) or "could not start gh"

    _register_proc(proc)
    try:
        out, err, timed_out, overflowed = _drain_streams(
            proc, MAX_STDOUT_BYTES, MAX_STDERR_BYTES, deadline_s
        )
        if timed_out or overflowed:
            _kill_pgroup(proc)
            try:
                proc.wait(timeout=5)
            except Exception:
                pass
            if timed_out:
                return -1, b"", b"", f"Command timed out after {int(deadline_s)}s — process group killed"
            return -1, b"", b"", "Response exceeded byte cap — process group killed"
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            _kill_pgroup(proc)
            try:
                proc.wait(timeout=5)
            except Exception:
                pass
            return -1, b"", b"", "Process did not exit after streams closed — killed"
        return proc.returncode, out, err, None
    finally:
        _unregister_proc(proc)
        try:
            proc.stdout.close()
            proc.stderr.close()
        except Exception:
            pass


def check_gh() -> tuple[str | None, str | None, str | None]:
    """Return (error, error_code, dependency)."""
    try:
        _find_gh()
        return None, None, None
    except ValueError as exc:      # bad github.ghPath: a config problem, not a missing tool
        return str(exc), None, None
    except RuntimeError as exc:
        return str(exc), "missing_dependency", "github-cli"


def _logged_in() -> bool:
    rc, _, _, problem = _exec([_find_gh(), "auth", "status", "--hostname", "github.com"], CHECK_TIMEOUT)
    return problem is None and rc == 0


def _parse_runs(out: bytes) -> Any:
    """Parse gh's JSON; tolerate stray text around a single top-level array
    (a notice, a banner). Returns None when no JSON array can be read."""
    text = out.decode("utf-8", errors="replace").lstrip("\ufeff")
    try:
        return json.loads(text)
    except ValueError:
        pass
    start = text.find("[")
    if start < 0:
        return None
    try:
        value, _end = json.JSONDecoder().raw_decode(text[start:])
    except ValueError:
        return None
    return value if isinstance(value, list) else None


def _describe_bad_output(out: bytes) -> str:
    """Short, safe description of unparseable gh output (for the panel)."""
    sample = _clean(_scrub(out[:200].decode("utf-8", errors="replace")), 70)
    return f"JSON parse error in gh output ({len(out)} bytes, starts with: {sample})"


def _list_runs(repo: str) -> tuple[list[dict], str | None]:
    """Return (runs, error). Never raises."""
    cmd = [_find_gh(), "run", "list", "--repo", repo,
           "--limit", str(MAX_RUNS), "--json", RUN_FIELDS]
    rc, out, err, problem = _exec(cmd, CMD_TIMEOUT)
    if problem:
        return [], problem
    if rc != 0:
        text = _scrub(err.decode("utf-8", errors="replace").strip())
        return [], _clean(text, 200) or f"gh exited {rc}"
    if not out.strip():
        # Exit 0 with nothing on stdout: gh found no runs to list.
        return [], None
    data = _parse_runs(out)
    if data is None:
        return [], _describe_bad_output(out)
    if not isinstance(data, list):
        return [], "Unexpected gh output (expected a list of runs)"
    return [r for r in data if isinstance(r, dict)], None


# ── Normalisation ─────────────────────────────────────────────────────────────

def _state(run: dict) -> str:
    status = str(run.get("status") or "").lower()
    conclusion = str(run.get("conclusion") or "").lower()
    if status and status != "completed":
        return "running"
    if conclusion == "success":
        return "success"
    if conclusion in FAILED_CONCLUSIONS:
        return "failed"
    if conclusion == "cancelled":
        return "cancelled"
    if conclusion in SKIPPED_CONCLUSIONS:
        return "skipped"
    return "unknown"


def _parse_time(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _duration_minutes(run: dict, state: str) -> int:
    start = _parse_time(run.get("startedAt")) or _parse_time(run.get("createdAt"))
    if start is None:
        return -1
    end = datetime.now(timezone.utc) if state == "running" else _parse_time(run.get("updatedAt"))
    if end is None:
        return -1
    return max(0, int((end - start).total_seconds() / 60))


def _safe_url(value: Any) -> str:
    if isinstance(value, str) and value.startswith(ALLOWED_URL_PREFIX) and len(value) <= 300 \
            and all(ch.isprintable() and not ch.isspace() for ch in value):
        return value
    return ""


def _sort_key(run: dict) -> str:
    return str(run.get("createdAt") or "")


def build_repo(repo: str, runs: list[dict]) -> dict[str, Any]:
    groups: dict[str, list[dict]] = {}
    order: list[str] = []
    for run in sorted(runs, key=_sort_key, reverse=True):
        key = str(run.get("workflowDatabaseId") or run.get("workflowName") or run.get("displayTitle") or "?")
        if key not in groups:
            groups[key] = []
            order.append(key)
        groups[key].append(run)

    pipeline_list: list[dict[str, Any]] = []
    for key in order[:MAX_WORKFLOWS]:
        history = groups[key]
        latest = history[0]
        state = _state(latest)
        last_state = ""
        for previous in history[1:]:
            prev_state = _state(previous)
            if prev_state in ("success", "failed"):
                last_state = prev_state
                break
        branch = _clean(latest.get("headBranch"))
        event = _clean(latest.get("event"))
        pipeline_list.append({
            "name":        _clean(latest.get("workflowName") or latest.get("displayTitle")) or "workflow",
            "status":      state,
            "lastStatus":  last_state,
            "durationMin": _duration_minutes(latest, state),
            "url":         _safe_url(latest.get("url")),
            "detail":      " · ".join(part for part in (branch, event) if part),
        })

    counts = {"running": 0, "success": 0, "failed": 0}
    for item in pipeline_list:
        if item["status"] in counts:
            counts[item["status"]] += 1

    if counts["failed"] > 0:
        status = "warning"
    elif pipeline_list:
        status = "healthy"
    else:
        status = "unknown"

    return {
        "repo":         repo,
        "status":       status,
        "pipelines":    counts,
        "pipelineList": pipeline_list,
    }


def repo_error(repo: str, error: str) -> dict[str, Any]:
    return {
        "repo":         repo,
        "status":       "offline",
        "error":        error,
        "pipelines":    {"running": 0, "success": 0, "failed": 0},
        "pipelineList": [],
    }


def aggregate(repos: list[dict[str, Any]]) -> dict[str, Any]:
    totals = {k: sum(r["pipelines"][k] for r in repos) for k in ("running", "success", "failed")}
    statuses = [r["status"] for r in repos]
    payload: dict[str, Any] = {"provider": PROVIDER, "pipelines": totals, "repos": repos}

    if statuses and all(s == "offline" for s in statuses):
        payload["status"] = "offline"
        payload["error"] = _clean(f"Could not read any repository: {repos[0].get('error', '')}", 200)
    elif "warning" in statuses or "critical" in statuses or "offline" in statuses:
        payload["status"] = "warning"
    elif all(s == "unknown" for s in statuses):
        payload["status"] = "unknown"
    else:
        payload["status"] = "healthy"
    return payload


# ── Output — bounded to MAX_OUTPUT_BYTES ─────────────────────────────────────

def emit(payload: dict) -> None:
    output = json.dumps(payload)
    if len(output.encode()) > MAX_OUTPUT_BYTES:
        emit_error("Output exceeded size limit — reduce number of repositories")
        return
    print(output)


def emit_error(error: str, status: str = "offline",
               error_code: str | None = None, dependency: str | None = None,
               hint: str | None = None) -> None:
    payload = {"provider": PROVIDER, "status": status, "error": error}
    if error_code:
        payload["errorCode"] = error_code
    if dependency:
        payload["dependency"] = dependency
    if hint:
        payload["hint"] = hint
    print(json.dumps(payload))


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch GitHub Actions status")
    parser.add_argument("--mock", action="store_true")
    parser.add_argument("--mock-error", choices=["missing-dependency", "generic"], default=None,
                        help="Dev aid, only with --mock: emit a synthetic error instead of "
                             "the mock fixture, to test the panel's error UI without touching "
                             "the real gh CLI")
    parser.add_argument("--repo", action="append", dest="repos", metavar="OWNER/REPO")
    parser.add_argument("--gh-path", dest="gh_path", default="", metavar="PATH",
                        help="Absolute path to a gh executable (github.ghPath in config.json); "
                             "use when gh is installed outside /usr/bin, e.g. with mise")
    args = parser.parse_args()
    global _GH_CONFIGURED
    _GH_CONFIGURED = args.gh_path or ""

    if args.mock:
        if args.mock_error == "missing-dependency":
            emit_error("gh CLI not found — install github-cli",
                       error_code="missing_dependency", dependency="github-cli",
                       hint="or set github.ghPath in config.json")
            return 0
        if args.mock_error == "generic":
            emit_error("Not logged in to GitHub — run: gh auth login")
            return 0
        try:
            emit(json.loads(MOCK_FILE.read_text()))
        except Exception as exc:
            emit_error(f"Failed to load mock file: {_clean(str(exc), 120)}")
        return 0

    err, error_code, dependency = check_gh()
    if err:
        emit_error(err, error_code=error_code, dependency=dependency,
                   hint="or set github.ghPath in config.json" if error_code else None)
        return 1

    repos = args.repos or []
    if not repos:
        emit_error("No repositories configured — add owner/repo entries under github.repos in config.json")
        return 1
    if len(repos) > MAX_REPOS:
        emit_error(f"Too many repositories configured ({len(repos)}) — max is {MAX_REPOS}")
        return 1
    seen: list[str] = []
    for repo in repos:
        if not _validate_repo(repo):
            emit_error("Invalid repository (expected owner/name, letters, digits, '-', '_' and '.')")
            return 1
        if repo not in seen:
            seen.append(repo)

    results: list[dict[str, Any]] = []
    login_checked = False
    for repo in seen:
        runs, error = _list_runs(repo)
        if error and not login_checked:
            # Only on the first failure: tell "not logged in" apart from a
            # repository-specific problem, without an extra call per refresh.
            login_checked = True
            if not _logged_in():
                emit_error("Not logged in to GitHub — run: gh auth login")
                return 1
        results.append(repo_error(repo, error) if error else build_repo(repo, runs))

    emit(aggregate(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
