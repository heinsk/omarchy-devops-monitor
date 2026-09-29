#!/usr/bin/env python3
"""
scripts/kubernetes.py
Fetch Kubernetes cluster health across one or more contexts.

Outputs a single normalized JSON object to stdout.
Exits 0 on success, 1 on unrecoverable failure.

Usage:
    kubernetes.py [--mock] [--context CTX [--context CTX2 ...]] [--k9s]

Authentication:
    Uses the existing kubectl configuration (~/.kube/config).
    No credentials are stored or printed.

Dependencies:
    - kubectl
    - k9s  (optional — only used when launching a cluster viewer)

Security:
    All kubectl invocations run through _run_simple(), which drains
    stdout/stderr concurrently (select.poll()) under a single wall-clock
    deadline, enforces a producer-side byte cap on each stream, and kills
    the full process group (kubectl can itself spawn credential-plugin
    children) on timeout or overflow — the same hardening already applied
    to scripts/azure_devops.py, so a large or hostile cluster response
    (e.g. a huge --all-namespaces pod list) can no longer buffer
    unboundedly in memory or hang the long-lived shell.
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
from pathlib import Path
from typing import Any

# ── Constants ─────────────────────────────────────────────────────────────────

PROVIDER  = "kubernetes"
MOCK_FILE = Path(__file__).parent.parent / "mock" / "kubernetes.json"

MAX_STDOUT_BYTES = 512 * 1024   # 512 KB — producer-side cap for get/list queries
MAX_STDERR_BYTES = 16  * 1024   # 16 KB
MAX_CHECK_BYTES  = 16  * 1024   # 16 KB — version/current-context/get-contexts
MAX_OUTPUT_BYTES = 256 * 1024   # 256 KB — cap on final JSON emitted to QML
MAX_CONTEXTS     = 20           # hard cap on number of contexts processed per run

QUERY_TIMEOUT = 20   # seconds — deadline for get nodes/pods/deployments
CHECK_TIMEOUT = 10   # seconds — deadline for version/current-context/get-contexts

# ── Module-level cached kubectl path ──────────────────────────────────────────

_KUBECTL_PATH: str | None = None


def _find_kubectl() -> str | None:
    global _KUBECTL_PATH
    if _KUBECTL_PATH is None:
        _KUBECTL_PATH = shutil.which("kubectl", path="/usr/local/bin:/usr/bin:/bin")
    return _KUBECTL_PATH


# ── Active-process registry for signal-based cleanup ──────────────────────────
#
# kubectl is started with start_new_session=True so it lives in its own
# session (it can spawn credential-plugin helpers, e.g. for cloud-provider
# auth). If this script itself is killed (e.g. QML calling terminate() on
# the Python process), those children would be orphaned unless we
# explicitly kill the whole group here first.

_active_procs: set[subprocess.Popen] = set()


def _register_proc(proc: subprocess.Popen) -> None:
    _active_procs.add(proc)


def _unregister_proc(proc: subprocess.Popen) -> None:
    _active_procs.discard(proc)


def _kill_pgroup(proc: subprocess.Popen) -> None:
    """Kill the entire process group — handles kubectl spawning child processes."""
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
    kubectl child process group before exiting, so nothing is orphaned.
    """
    for proc in list(_active_procs):
        _kill_pgroup(proc)
    sys.exit(1)


signal.signal(signal.SIGTERM, _cleanup_and_exit)
signal.signal(signal.SIGINT,  _cleanup_and_exit)


# ── Security helpers ──────────────────────────────────────────────────────────

def _trusted_env() -> dict[str, str]:
    home = os.environ.get("HOME", "")
    env = {
        "HOME": home,
        "PATH": "/usr/local/bin:/usr/bin:/bin",
    }
    # Preserve an explicit KUBECONFIG if the user has set one themselves —
    # this is the person's own environment value, not attacker-controlled
    # remote data, and dropping it would silently break existing setups
    # that don't use the default ~/.kube/config path.
    kubeconfig = os.environ.get("KUBECONFIG", "")
    if kubeconfig:
        env["KUBECONFIG"] = kubeconfig
    return env


def _scrub(text: str) -> str:
    return re.sub(r"[A-Za-z0-9+/]{40,}={0,2}", "[REDACTED]", text)


# ── Concurrent, deadline-bound stream draining ────────────────────────────────
# Identical approach to azure_devops.py's _drain_streams(): reads stdout and
# stderr concurrently via select.poll() under one wall-clock deadline, so a
# child that never closes stdout can't hang the caller past the deadline,
# and a child that fills stderr while we're reading stdout can't deadlock us.

def _drain_streams(
    proc: subprocess.Popen,
    cap_out: int,
    cap_err: int,
    deadline_s: float,
) -> tuple[bytes, bytes, bool, bool]:
    """
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


def _run_simple(
    cmd: list[str],
    cap_out: int = MAX_STDOUT_BYTES,
    cap_err: int = MAX_STDERR_BYTES,
    deadline: float = QUERY_TIMEOUT,
) -> tuple[int, bytes, bytes]:
    """
    Run a kubectl command with concurrently-drained, byte-capped,
    deadline-bound output. Kills the process group on overflow or timeout,
    including any grandchild processes kubectl itself spawns (e.g. cloud
    auth plugins). Returns (returncode, stdout, stderr). Never raises.
    """
    try:
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=_trusted_env(),
            start_new_session=True,   # own process group — killable as a tree
        )
    except FileNotFoundError:
        return -1, b"", b"kubectl not found"
    except Exception as exc:
        return -1, b"", str(exc).encode()

    _register_proc(proc)
    try:
        stdout_data, stderr_data, timed_out, overflowed = _drain_streams(
            proc, cap_out, cap_err, deadline
        )

        if timed_out:
            _kill_pgroup(proc)
            try:
                proc.wait(timeout=5)
            except Exception:
                pass
            return -1, b"", f"kubectl timed out after {deadline}s — process group killed".encode()

        if overflowed:
            _kill_pgroup(proc)
            try:
                proc.wait(timeout=5)
            except Exception:
                pass
            return -1, b"", b"kubectl response exceeded byte cap - process group killed"

        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            _kill_pgroup(proc)
            try:
                proc.wait(timeout=5)
            except Exception:
                pass
            return -1, b"", b"kubectl did not exit after streams closed - killed"

        return proc.returncode, stdout_data, stderr_data

    finally:
        _unregister_proc(proc)
        try:
            proc.stdout.close()
            proc.stderr.close()
        except Exception:
            pass


# ── CLI helper ────────────────────────────────────────────────────────────────

def _kubectl(args: list[str], context: str) -> tuple[dict | list, str | None]:
    """
    Run a kubectl command for a specific context.
    Returns (parsed_json, error_string).
    Never raises.
    """
    kubectl = _find_kubectl()
    if not kubectl:
        return {}, "kubectl not found — install kubectl"

    cmd = [kubectl] + args + ["--context", context, "--output", "json"]
    rc, out, err = _run_simple(cmd, MAX_STDOUT_BYTES, MAX_STDERR_BYTES, QUERY_TIMEOUT)

    if rc != 0:
        msg = _scrub(err.decode("utf-8", errors="replace").strip()) or f"kubectl exited {rc}"
        return {}, msg

    try:
        return json.loads(out), None
    except json.JSONDecodeError as exc:
        return {}, f"JSON parse error: {exc}"


# ── Dependency / auth checks ──────────────────────────────────────────────────

def check_kubectl() -> str | None:
    kubectl = _find_kubectl()
    if not kubectl:
        return "kubectl not found — install kubectl"
    rc, _, _ = _run_simple([kubectl, "version", "--client"], MAX_CHECK_BYTES, MAX_STDERR_BYTES, CHECK_TIMEOUT)
    if rc == -1:
        return "kubectl timed out or exceeded output limit"
    return None if rc == 0 else "kubectl returned non-zero"


def get_current_context() -> tuple[str, str | None]:
    """Return (current_context_name, error)."""
    kubectl = _find_kubectl()
    if not kubectl:
        return "", "kubectl not found"
    rc, out, _ = _run_simple([kubectl, "config", "current-context"], MAX_CHECK_BYTES, MAX_STDERR_BYTES, CHECK_TIMEOUT)
    if rc == -1:
        return "", "kubectl config current-context timed out or exceeded output limit"
    if rc != 0:
        return "", "No active kubectl context — run: kubectl config use-context <name>"
    return out.decode("utf-8", errors="replace").strip(), None


def list_contexts() -> list[str]:
    """Return all context names from kubeconfig."""
    kubectl = _find_kubectl()
    if not kubectl:
        return []
    rc, out, _ = _run_simple([kubectl, "config", "get-contexts", "--output", "name"], MAX_CHECK_BYTES, MAX_STDERR_BYTES, CHECK_TIMEOUT)
    if rc != 0:
        return []
    text = out.decode("utf-8", errors="replace")
    return [line.strip() for line in text.splitlines() if line.strip()]


# ── Node analysis ─────────────────────────────────────────────────────────────

def _node_ready(node: dict) -> bool:
    conditions = node.get("status", {}).get("conditions", [])
    for cond in conditions:
        if cond.get("type") == "Ready":
            return cond.get("status") == "True"
    return False


def _node_role(node: dict) -> str:
    labels = node.get("metadata", {}).get("labels", {})
    if "node-role.kubernetes.io/control-plane" in labels:
        return "control-plane"
    if "node-role.kubernetes.io/master" in labels:
        return "master"
    return "worker"


# ── Pod analysis ──────────────────────────────────────────────────────────────

def _pod_ready(pod: dict) -> bool:
    phase = pod.get("status", {}).get("phase", "")
    if phase == "Succeeded":
        return True
    if phase != "Running":
        return False
    # Check container statuses
    container_statuses = pod.get("status", {}).get("containerStatuses", [])
    if not container_statuses:
        return False
    return all(cs.get("ready", False) for cs in container_statuses)


# ── Deployment analysis ───────────────────────────────────────────────────────

def _deployment_ready(dep: dict) -> bool:
    spec_replicas = dep.get("spec", {}).get("replicas", 1)
    if spec_replicas == 0:
        return True  # scaled to zero intentionally
    status = dep.get("status", {})
    ready   = status.get("readyReplicas", 0)
    desired = status.get("replicas", 0)
    return ready == desired and desired > 0


# ── Per-context fetch ─────────────────────────────────────────────────────────

def fetch_context(context: str) -> dict[str, Any]:
    """
    Fetch node, pod, and deployment data for a single kubectl context.
    Returns a normalized cluster dict.
    """
    errors: list[str] = []

    nodes_data, nodes_err = _kubectl(["get", "nodes"], context)
    pods_data,  pods_err  = _kubectl(["get", "pods", "--all-namespaces"], context)
    deps_data,  deps_err  = _kubectl(["get", "deployments", "--all-namespaces"], context)

    for err in (nodes_err, pods_err, deps_err):
        if err:
            errors.append(err)

    nodes       = nodes_data.get("items", []) if isinstance(nodes_data, dict) else []
    pods        = pods_data.get("items",  []) if isinstance(pods_data,  dict) else []
    deployments = deps_data.get("items",  []) if isinstance(deps_data,  dict) else []

    nodes_ready = sum(1 for n in nodes if _node_ready(n))
    pods_ready  = sum(1 for p in pods  if _pod_ready(p))
    deps_ready  = sum(1 for d in deployments if _deployment_ready(d))

    # Derive per-cluster status
    if errors and not nodes:
        cluster_status = "offline"
    elif (
        nodes_ready  < len(nodes)       or
        pods_ready   < len(pods)        or
        deps_ready   < len(deployments)
    ):
        cluster_status = "warning"
    else:
        cluster_status = "healthy"

    result: dict[str, Any] = {
        "name":   context,
        "status": cluster_status,
        "nodes": {
            "ready": nodes_ready,
            "total": len(nodes),
        },
        "pods": {
            "ready": pods_ready,
            "total": len(pods),
        },
        "deployments": {
            "ready": deps_ready,
            "total": len(deployments),
        },
    }

    # Node breakdown (useful for multi-role clusters)
    if nodes:
        result["nodeDetail"] = {
            "controlPlane": sum(1 for n in nodes if _node_role(n) in ("control-plane", "master")),
            "workers":      sum(1 for n in nodes if _node_role(n) == "worker"),
        }

    if errors:
        result["warnings"] = errors

    return result


# ── Normalization ─────────────────────────────────────────────────────────────

def normalize(clusters: list[dict]) -> dict[str, Any]:
    if not clusters:
        return {"provider": PROVIDER, "status": "unknown", "clusters": []}

    statuses = [c["status"] for c in clusters]
    if all(s == "offline" for s in statuses):
        overall = "offline"
    elif "offline" in statuses or "warning" in statuses:
        overall = "warning"
    elif all(s == "healthy" for s in statuses):
        overall = "healthy"
    else:
        overall = "unknown"

    return {
        "provider": PROVIDER,
        "status":   overall,
        "clusters": clusters,
    }


# ── Output helpers — bounded to MAX_OUTPUT_BYTES ─────────────────────────────

def emit(payload: dict) -> None:
    output = json.dumps(payload)
    if len(output.encode()) > MAX_OUTPUT_BYTES:
        emit_error("Output exceeded size limit — reduce number of contexts or namespaces")
        return
    print(output)


def emit_error(error: str, status: str = "offline") -> None:
    emit({"provider": PROVIDER, "status": status, "error": error})


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch Kubernetes cluster status")
    parser.add_argument("--mock",    action="store_true",  help="Use mock data")
    parser.add_argument("--context", action="append",      help="Context(s) to query", default=[])
    parser.add_argument("--all-contexts", action="store_true", help="Query all kubeconfig contexts")
    args = parser.parse_args()

    # ── Mock mode ──────────────────────────────────────────────────────────────
    if args.mock:
        try:
            emit(json.loads(MOCK_FILE.read_text()))
        except Exception as exc:
            emit_error(f"Failed to load mock file: {exc}")
        return 0

    # ── Dependency check ───────────────────────────────────────────────────────
    err = check_kubectl()
    if err:
        emit_error(err)
        return 1

    # ── Resolve contexts ───────────────────────────────────────────────────────
    contexts = args.context

    if args.all_contexts:
        contexts = list_contexts()
        if not contexts:
            emit_error("No contexts found in kubeconfig")
            return 1
    elif not contexts:
        current, err = get_current_context()
        if err:
            emit_error(err)
            return 1
        contexts = [current]

    if len(contexts) > MAX_CONTEXTS:
        emit_error(f"Too many contexts configured ({len(contexts)}) — max is {MAX_CONTEXTS}")
        return 1

    # ── Fetch each context ─────────────────────────────────────────────────────
    clusters = [fetch_context(ctx) for ctx in contexts]

    # ── Normalize and emit ─────────────────────────────────────────────────────
    emit(normalize(clusters))
    return 0


if __name__ == "__main__":
    sys.exit(main())
