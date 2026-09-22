#!/usr/bin/python3
"""
scripts/azure_devops.py
Fetch Azure DevOps pipeline, release, and deployment status.

Supports multiple organizations and projects simultaneously.
Outputs a single normalized JSON object to stdout.
Exits 0 on success, 1 on unrecoverable failure.

Usage:
    azure_devops.py [--mock] [--top N]
                    [--target ORG PROJECT [--target ORG2 PROJECT2 ...]]

Authentication:
    Uses the existing `az` / `az devops` CLI session.
    No credentials are stored or printed.

Dependencies:
    - azure-cli  (az)
    - azure-devops extension  (az extension add --name azure-devops)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

# ── Constants ─────────────────────────────────────────────────────────────────

PROVIDER  = "azure-devops"
MOCK_FILE = Path(__file__).parent.parent / "mock" / "azure-devops.json"

ALLOWED_AZURE_HOSTS = {
    "dev.azure.com",
    "vsrm.dev.azure.com",
    "visualstudio.com",
}

MAX_STDOUT_BYTES   = 512 * 1024   # 512 KB — producer-side cap (reject at cap+1)
MAX_STDERR_BYTES   = 16  * 1024   # 16 KB
MAX_OUTPUT_BYTES   = 256 * 1024   # 256 KB — cap on final JSON output to QML
MAX_RELEASE_DETAIL = 10
MAX_TIMELINE_RUNS  = 3
MAX_TOP            = 100
MAX_ARG_LEN        = 256
CMD_TIMEOUT        = 30           # seconds per subprocess call

PIPELINE_RUNNING_STATES = {"inprogress", "running", "cancelling"}
PIPELINE_SUCCESS_STATES = {"succeeded", "success", "partiallysucceeded"}
PIPELINE_FAILED_STATES  = {"failed", "failure", "canceled", "cancelled"}

RELEASE_RUNNING_STATES  = {"inprogress", "active", "queued", "scheduled"}
RELEASE_SUCCESS_STATES  = {"succeeded", "success", "partiallysucceeded"}
RELEASE_FAILED_STATES   = {"failed", "failure", "rejected", "abandoned", "canceled", "cancelled"}

# ── Module-level cached az path ───────────────────────────────────────────────

_AZ_PATH: str | None = None


def _find_az() -> str:
    global _AZ_PATH
    if _AZ_PATH is None:
        path = shutil.which("az", path="/usr/local/bin:/usr/bin:/bin")
        if not path:
            raise RuntimeError("az CLI not found — install azure-cli")
        _AZ_PATH = path
    return _AZ_PATH


# ── Security helpers ──────────────────────────────────────────────────────────

def _trusted_env() -> dict[str, str]:
    home = os.environ.get("HOME", "")
    return {
        "HOME":                                home,
        "PATH":                                "/usr/local/bin:/usr/bin:/bin",
        "AZURE_CONFIG_DIR":                    os.path.join(home, ".azure"),
        "AZURE_EXTENSION_USE_DYNAMIC_INSTALL": "no",
    }


def _validate_azure_url(url: str) -> str:
    if not url:
        return ""
    try:
        parsed = urlparse(url)
        if parsed.scheme != "https":
            return ""
        host = parsed.netloc.lower().split(":")[0]
        if any(host == h or host.endswith("." + h) for h in ALLOWED_AZURE_HOSTS):
            return url
    except Exception:
        pass
    return ""


def _validate_org(org: str) -> bool:
    if not org or len(org) > MAX_ARG_LEN:
        return False
    return bool(_validate_azure_url(org.rstrip("/") + "/"))


def _validate_project(project: str) -> bool:
    if not project or len(project) > 64:
        return False
    return bool(re.match(r'^[\w][\w\s\-\.]{0,63}$', project))


def _scrub(text: str) -> str:
    return re.sub(r"[A-Za-z0-9+/]{40,}={0,2}", "[REDACTED]", text)


# ── Streaming subprocess with producer-side byte cap ─────────────────────────

def _read_capped(stream, cap: int) -> tuple[bytes, bool]:
    """
    Read at most cap bytes from stream.
    Returns (data, overflowed).
    If cap+1 bytes are available the overflow flag is set and
    the caller must kill the process group.
    """
    chunks = []
    total  = 0
    while True:
        chunk = stream.read(min(4096, cap - total + 1))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
        if total > cap:
            return b"".join(chunks)[:cap], True
    return b"".join(chunks), False


def _kill_pgroup(proc: subprocess.Popen) -> None:
    """Kill the entire process group — handles az spawning child processes."""
    try:
        pgid = os.getpgid(proc.pid)
        os.killpg(pgid, signal.SIGKILL)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


def _run(args: list[str]) -> tuple[list[Any], str | None]:
    """
    Run an az CLI command with streaming output capped at MAX_STDOUT_BYTES.
    Kills the process group on overflow or timeout.
    Returns (parsed_json_list, error_string). Never raises.
    """
    try:
        az = _find_az()
    except RuntimeError as exc:
        return [], str(exc)

    cmd = [az if a == "az" else a for a in args] + ["--output", "json"]

    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=_trusted_env(),
            start_new_session=True,   # new process group — killable as a tree
        )
    except FileNotFoundError:
        return [], "az CLI not found — install azure-cli"
    except Exception as exc:
        return [], str(exc)

    try:
        stdout_data, stdout_over = _read_capped(proc.stdout, MAX_STDOUT_BYTES)
        stderr_data, stderr_over = _read_capped(proc.stderr, MAX_STDERR_BYTES)

        if stdout_over or stderr_over:
            _kill_pgroup(proc)
            proc.wait(timeout=5)
            return [], "Response exceeded byte cap — process killed"

        try:
            proc.wait(timeout=CMD_TIMEOUT)
        except subprocess.TimeoutExpired:
            _kill_pgroup(proc)
            proc.wait(timeout=5)
            return [], f"Command timed out after {CMD_TIMEOUT}s — process killed"

    except Exception as exc:
        _kill_pgroup(proc)
        return [], str(exc)

    finally:
        try:
            proc.stdout.close()
            proc.stderr.close()
        except Exception:
            pass

    if proc.returncode != 0:
        err = _scrub(stderr_data.decode("utf-8", errors="replace").strip()) or f"az exited {proc.returncode}"
        return [], err

    try:
        data = json.loads(stdout_data)
        if isinstance(data, dict):
            data = [data]
        return data or [], None
    except json.JSONDecodeError as exc:
        return [], f"JSON parse error: {exc}"


def _run_simple(cmd: list[str]) -> tuple[int, bytes, bytes]:
    """
    Run a simple command (az --version, az account show, etc.) with
    streaming byte cap. Returns (returncode, stdout, stderr).
    """
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=_trusted_env(),
            start_new_session=True,
        )
        stdout_data, _ = _read_capped(proc.stdout, MAX_STDERR_BYTES)
        stderr_data, _ = _read_capped(proc.stderr, MAX_STDERR_BYTES)

        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            _kill_pgroup(proc)
            proc.wait(timeout=5)
            return -1, b"", b"timed out"
        return proc.returncode, stdout_data, stderr_data
    except Exception as exc:
        return -1, b"", str(exc).encode()
    finally:
        try:
            proc.stdout.close()
            proc.stderr.close()
        except Exception:
            pass


# ── Dependency / auth checks ──────────────────────────────────────────────────

def check_az() -> str | None:
    try:
        az = _find_az()
        rc, _, _ = _run_simple([az, "--version"])
        return None if rc == 0 else "az CLI returned non-zero on --version"
    except RuntimeError as exc:
        return str(exc)


def check_az_devops() -> str | None:
    try:
        az = _find_az()
        rc, _, _ = _run_simple([az, "extension", "show", "--name", "azure-devops"])
        return None if rc == 0 else (
            "az devops extension not installed — run: az extension add --name azure-devops"
        )
    except RuntimeError as exc:
        return str(exc)


def check_auth() -> str | None:
    try:
        az = _find_az()
        rc, _, _ = _run_simple([az, "account", "show"])
        return None if rc == 0 else "Not logged in to Azure — run: az login"
    except Exception as exc:
        return str(exc)


# ── State helpers ─────────────────────────────────────────────────────────────

def _run_state(run: dict) -> str:
    status = (run.get("status") or "").lower()
    result = (run.get("result") or "").lower()
    if status in PIPELINE_RUNNING_STATES:  return "running"
    if result in PIPELINE_SUCCESS_STATES:  return "success"
    if result in PIPELINE_FAILED_STATES:   return "failed"
    if status in PIPELINE_SUCCESS_STATES:  return "success"
    if status in PIPELINE_FAILED_STATES:   return "failed"
    return "unknown"


def _release_state(rel: dict) -> str:
    environments = rel.get("environments") or []
    if environments:
        env_statuses = [(e.get("status") or "").lower() for e in environments]
        if any(s in {"rejected", "failed", "canceled", "cancelling"} for s in env_statuses):
            return "failed"
        if any(s in {"inprogress", "queued", "scheduled"} for s in env_statuses):
            return "running"
        if all(s == "succeeded" for s in env_statuses if s != "notstarted"):
            return "success"
    raw = (rel.get("status") or "").lower()
    if raw in RELEASE_RUNNING_STATES:  return "running"
    if raw in RELEASE_SUCCESS_STATES:  return "success"
    if raw in RELEASE_FAILED_STATES:   return "failed"
    return "unknown"


def _duration_minutes(start: str, finish: str, is_running: bool) -> int:
    if not start:
        return -1
    try:
        def _parse(s: str) -> datetime:
            s = s.split(".")[0].rstrip("Z")
            return datetime.strptime(s, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
        t_start = _parse(start)
        t_end   = _parse(finish) if finish and not is_running else datetime.now(timezone.utc)
        return max(0, int((t_end - t_start).total_seconds() / 60))
    except Exception:
        return -1


# ── Per-target fetchers ───────────────────────────────────────────────────────

def fetch_target(org: str, project: str, top: int) -> dict[str, Any]:
    base = ["--org", org, "--project", project]

    runs,          runs_err     = _run(["az", "pipelines", "runs", "list",
                                        "--top", str(top), "--status", "all"] + base)
    releases_list, releases_err = _run(["az", "pipelines", "release", "list",
                                        "--top", str(top)] + base)

    releases: list[dict] = []
    for rel in releases_list[:MAX_RELEASE_DETAIL]:
        rel_id = rel.get("id")
        if rel_id:
            detail, _ = _run(["az", "pipelines", "release", "show",
                               "--id", str(rel_id)] + base)
            if detail:
                releases.extend(detail if isinstance(detail, list) else [detail])
            else:
                releases.append(rel)
        else:
            releases.append(rel)

    pipeline_counts = _count_states(runs,     PIPELINE_RUNNING_STATES, PIPELINE_SUCCESS_STATES, PIPELINE_FAILED_STATES)
    release_counts  = _count_states(releases, RELEASE_RUNNING_STATES,  RELEASE_SUCCESS_STATES,  RELEASE_FAILED_STATES)

    errors = [e for e in (runs_err, releases_err) if e]
    status = _derive_status(pipeline_counts, release_counts, bool(errors), bool(runs or releases))

    result: dict[str, Any] = {
        "organization":  org,
        "project":       project,
        "status":        status,
        "pipelines":     pipeline_counts,
        "deployments":   release_counts,
        "pipelineList":  _build_pipeline_list(runs, org, project),
        "releaseList":   _build_release_list(releases, org, project),
    }
    if errors:
        result["warnings"] = errors
    return result


def _build_pipeline_list(runs: list[dict], org: str, project: str) -> list[dict]:
    seen: dict[str, list[dict]] = {}
    for run in runs:
        name = run.get("pipeline", {}).get("name") or run.get("definition", {}).get("name") or "Unknown"
        if name not in seen:
            seen[name] = []
        if len(seen[name]) < 2:
            seen[name].append(run)

    running_count = 0
    result = []

    for name, pair in seen.items():
        current  = pair[0]
        previous = pair[1] if len(pair) > 1 else None

        current_state = _run_state(current)
        last_state    = _run_state(previous) if previous else None

        raw_url = ""
        links = current.get("_links", {})
        if isinstance(links, dict) and links.get("web", {}).get("href"):
            raw_url = links["web"]["href"]
        else:
            pipeline_id = (current.get("pipeline") or current.get("definition") or {}).get("id")
            if org and project and pipeline_id:
                raw_url = "{}/{}/_build?definitionId={}".format(org.rstrip("/"), project, pipeline_id)
        url = _validate_azure_url(raw_url)

        start_time   = current.get("startTime")  or current.get("createdDate")  or ""
        finish_time  = current.get("finishTime") or current.get("finishedDate") or ""
        is_running   = (current.get("status") or "").lower() in PIPELINE_RUNNING_STATES
        duration_min = _duration_minutes(start_time, finish_time, is_running)

        current_stage = ""
        if current_state == "running" and running_count < MAX_TIMELINE_RUNS:
            running_count += 1
            run_id = current.get("id")
            if run_id:
                timeline_result, _ = _run([
                    "az", "devops", "invoke",
                    "--org", org,
                    "--area", "build",
                    "--resource", "timeline",
                    "--route-parameters", "project=" + project, "buildId=" + str(run_id),
                    "--api-version", "7.1"
                ])
                timeline = timeline_result[0] if timeline_result else {}
                if isinstance(timeline, dict):
                    records = timeline.get("records") or []
                    running_stages = [
                        r for r in records
                        if (r.get("state") or "").lower() == "inprogress"
                        and (r.get("type") or "").lower() == "stage"
                    ]
                    if running_stages:
                        current_stage = running_stages[0].get("name") or ""
                    else:
                        any_running = [r for r in records if (r.get("state") or "").lower() == "inprogress"]
                        if any_running:
                            current_stage = any_running[0].get("name") or ""

        result.append({
            "name":         name,
            "status":       current_state,
            "lastStatus":   last_state,
            "url":          url,
            "durationMin":  duration_min,
            "currentStage": current_stage,
        })
    return result


def _build_release_list(releases: list[dict], org: str, project: str) -> list[dict]:
    seen: dict[str, list[dict]] = {}
    for rel in releases:
        name = (rel.get("releaseDefinition") or {}).get("name") or rel.get("name") or "Unknown"
        if name not in seen:
            seen[name] = []
        if len(seen[name]) < 2:
            seen[name].append(rel)

    result = []
    for name, pair in seen.items():
        current  = pair[0]
        previous = pair[1] if len(pair) > 1 else None

        current_state = _release_state(current)
        last_state    = _release_state(previous) if previous else None

        raw_url = ""
        links = current.get("_links") or {}
        if isinstance(links, dict) and links.get("web", {}).get("href"):
            raw_url = links["web"]["href"]
        else:
            release_id = current.get("id")
            if org and project and release_id:
                raw_url = "{}/{}/_releaseProgress?_a=release-pipeline-progress&releaseId={}".format(
                    org.rstrip("/"), project, release_id
                )
        url = _validate_azure_url(raw_url)

        start_time   = current.get("createdOn")  or current.get("createdDate")  or ""
        finish_time  = current.get("modifiedOn") or current.get("finishedDate") or ""
        duration_min = _duration_minutes(start_time, finish_time, current_state == "running")

        result.append({
            "name":        name,
            "releaseName": current.get("name") or "",
            "status":      current_state,
            "lastStatus":  last_state,
            "url":         url,
            "durationMin": duration_min,
        })
    return result


# ── State counting ────────────────────────────────────────────────────────────

def _count_states(items: list[dict], running_states: set, success_states: set, failed_states: set) -> dict[str, int]:
    running = success = failed = 0
    for item in items:
        status    = (item.get("status") or "").lower()
        result    = (item.get("result") or "").lower()
        effective = result if result else status
        if status in running_states:      running += 1
        elif effective in success_states: success += 1
        elif effective in failed_states:  failed  += 1
    return {"running": running, "success": success, "failed": failed}


def _derive_status(pipelines: dict, deployments: dict, has_errors: bool, has_data: bool) -> str:
    if pipelines["failed"] > 0 or deployments["failed"] > 0:
        return "warning"
    if has_errors and not has_data:
        return "offline"
    if has_data:
        return "healthy"
    return "unknown"


# ── Aggregation ───────────────────────────────────────────────────────────────

def aggregate(targets: list[dict[str, Any]]) -> dict[str, Any]:
    def _sum(key: str, subkey: str) -> int:
        return sum(t[key][subkey] for t in targets if key in t)

    total_pipelines   = {k: _sum("pipelines", k)   for k in ("running", "success", "failed")}
    total_deployments = {k: _sum("deployments", k) for k in ("running", "success", "failed")}

    statuses = [t["status"] for t in targets]
    if "warning" in statuses or "critical" in statuses: overall = "warning"
    elif "offline" in statuses:                          overall = "warning"
    elif all(s == "healthy" for s in statuses):          overall = "healthy"
    elif all(s == "unknown" for s in statuses):          overall = "unknown"
    else:                                                overall = "healthy"

    return {
        "provider":    PROVIDER,
        "status":      overall,
        "pipelines":   total_pipelines,
        "deployments": total_deployments,
        "targets":     targets,
    }


# ── Output — bounded to MAX_OUTPUT_BYTES ─────────────────────────────────────

def emit(payload: dict) -> None:
    output = json.dumps(payload)
    if len(output.encode()) > MAX_OUTPUT_BYTES:
        # Truncate targets to fit — keep structure intact
        emit_error("Output exceeded size limit — reduce number of targets or pipelines")
        return
    print(output)


def emit_error(error: str, status: str = "offline") -> None:
    print(json.dumps({"provider": PROVIDER, "status": status, "error": error}))


# ── Argument parsing ──────────────────────────────────────────────────────────

class TargetAction(argparse.Action):
    def __call__(self, parser, namespace, values, option_string=None):
        if len(values) != 2:
            parser.error("--target requires exactly 2 arguments: ORG PROJECT")
        targets = getattr(namespace, self.dest, None) or []
        targets.append({"org": values[0], "project": values[1]})
        setattr(namespace, self.dest, targets)


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch Azure DevOps status")
    parser.add_argument("--mock",   action="store_true")
    parser.add_argument("--top",    type=int, default=50,
                        help=f"Max items per query (hard-capped at {MAX_TOP})")
    parser.add_argument("--target", nargs=2, metavar=("ORG", "PROJECT"),
                        action=TargetAction, dest="targets")
    args = parser.parse_args()

    if args.mock:
        try:
            emit(json.loads(MOCK_FILE.read_text()))
        except Exception as exc:
            emit_error(f"Failed to load mock file: {exc}")
        return 0

    for check in (check_az, check_az_devops, check_auth):
        err = check()
        if err:
            emit_error(err)
            return 1

    targets = args.targets or []
    if not targets:
        emit_error("No targets configured.")
        return 1

    valid_targets = []
    for t in targets:
        org     = t["org"]
        project = t["project"]
        if not _validate_org(org):
            emit_error(f"Invalid organization URL (must be HTTPS Azure DevOps, max {MAX_ARG_LEN} chars)")
            return 1
        if not _validate_project(project):
            emit_error(f"Invalid project name (alphanumeric/dash/dot/space, max 64 chars)")
            return 1
        valid_targets.append(t)

    top = min(args.top, MAX_TOP)
    results = [fetch_target(t["org"], t["project"], top) for t in valid_targets]
    emit(aggregate(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
