#!/usr/bin/env python3
"""
scripts/kubernetes.py
Fetch Kubernetes cluster health across one or more contexts.

Outputs a single normalized JSON object to stdout.
Exits 0 on success, 1 on unrecoverable failure.

Usage:
    kubernetes.py [--mock] [--context CTX [--context CTX2 ...]] [--all-contexts]
                  [--namespace=NS ...] [--exclude-namespace=NS ...]

Authentication:
    Uses the existing kubectl configuration (~/.kube/config).
    No credentials are stored or printed.

Dependencies:
    - kubectl
    - k9s  (optional — only used when launching a cluster viewer)

Security:
    All kubectl invocations run through _run_simple(), which drains
    stdout/stderr concurrently (select.poll()) under a single wall-clock
    deadline, enforces a producer-side byte cap on each stream (16 MB for
    get nodes/pods/deployments, far less for everything else), and kills
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

MAX_STDOUT_BYTES = 512 * 1024   # 512 KB — producer-side cap for small queries
MAX_LIST_BYTES   = 16 * 1024 * 1024   # 16 MB — cap for get nodes/pods/deployments (a few
                                      # thousand pods is already several MB of JSON)
MAX_NS_QUERIES   = 10           # with at most this many included namespaces, query each one
                                # directly (-n NS) instead of listing the whole cluster
MAX_WARNINGS     = 3
MAX_WARNING_LEN  = 160
MAX_STDERR_BYTES = 16  * 1024   # 16 KB
MAX_CHECK_BYTES  = 16  * 1024   # 16 KB — version/current-context/get-contexts
MAX_OUTPUT_BYTES = 256 * 1024   # 256 KB — cap on final JSON emitted to QML
MAX_CONTEXTS     = 20           # hard cap on number of contexts processed per run
MAX_NS_FILTERS   = 50           # hard cap on --namespace / --exclude-namespace entries each
MAX_ISSUES       = 20           # per cluster: nodes / pods / deployments needing attention
MAX_NAMESPACES   = 50           # per cluster: namespaces sent to the panel (worst first)
MAX_NAME_LEN     = 253
MAX_REASON_LEN   = 60
PRESSURE_CONDITIONS = ("MemoryPressure", "DiskPressure", "PIDPressure")
# Reasons that mean "broken", not just "not ready yet" (shown as failed, not warning).
FAILED_REASONS = {
    "CrashLoopBackOff", "OOMKilled", "Error", "Failed", "Evicted", "ContainerCannotRun",
    "CreateContainerError", "CreateContainerConfigError", "RunContainerError",
    "StartError", "DeadlineExceeded",
}
# A Kubernetes namespace is a DNS-1123 label.
NS_RE = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")

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
                    chunk = os.read(fd, 65536)
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
    rc, out, err = _run_simple(cmd, MAX_LIST_BYTES, MAX_STDERR_BYTES, QUERY_TIMEOUT)

    if rc != 0:
        msg = _scrub(err.decode("utf-8", errors="replace").strip()) or f"kubectl exited {rc}"
        if "exceeded byte cap" not in msg and not msg.startswith("kubectl timed out"):
            msg = _summarize_error(msg)
        if "exceeded byte cap" in msg:
            what = args[1] if len(args) > 1 else "objects"
            msg = (f"kubectl get {what} returned more than {MAX_LIST_BYTES // (1024 * 1024)} MB — "
                   f"list the namespaces to watch in kubernetes.namespaces")
        return {}, msg

    try:
        return json.loads(out), None
    except json.JSONDecodeError as exc:
        return {}, f"JSON parse error: {exc}"


# ── Turning kubectl's error text into one readable line ───────────────────────

_KLOG_PREFIX = re.compile(r"^[EWIF]\d{4}\s+\d{2}:\d{2}:\d{2}\.\d+\s+\d+\s+\S+:\d+\]\s*")
_API_URL     = re.compile(r"https?://([A-Za-z0-9.\-\[\]:]{1,100})")
_UNREACHABLE = re.compile(
    r"connection refused|was refused|no route to host|network is unreachable|i/o timeout|"
    r"dial tcp|unable to connect to the server|context deadline exceeded|no such host|"
    r"client\.timeout exceeded|tls handshake timeout|connection reset", re.I)
_UNAUTHORIZED = re.compile(
    r"unauthorized|you must be logged in|token (has )?expired|provide credentials|"
    r"credentials? (have )?expired|exec plugin|getting credentials", re.I)


def _summarize_error(raw: str) -> str:
    """
    kubectl prints several klog lines (with timestamps and pids) for one
    problem. Reduce that to a single stable sentence: the known causes get a
    plain-language message, anything else its first meaningful line, cleaned
    and cut at a word boundary. Never raises.
    """
    text = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", " ", raw or "")
    if _UNREACHABLE.search(text):
        host = _API_URL.search(text)
        where = f" ({host.group(1)})" if host else ""
        return f"Cannot reach the cluster API server{where} — is the cluster running?"
    if _UNAUTHORIZED.search(text):
        return "The cluster rejected the credentials — log in again (kubectl or your cloud CLI)"
    for line in text.splitlines():
        line = _KLOG_PREFIX.sub("", line.strip()).strip()
        if line:
            break
    else:
        return "kubectl failed without a message"
    if len(line) > MAX_WARNING_LEN:
        line = line[:MAX_WARNING_LEN].rsplit(" ", 1)[0].rstrip(",;:") + "…"
    return line


# ── Dependency / auth checks ──────────────────────────────────────────────────

def check_kubectl() -> tuple[str | None, str | None, str | None]:
    """Return (error, error_code, dependency)."""
    kubectl = _find_kubectl()
    if not kubectl:
        return "kubectl not found — install kubectl", "missing_dependency", "kubectl"
    rc, _, _ = _run_simple([kubectl, "version", "--client"], MAX_CHECK_BYTES, MAX_STDERR_BYTES, CHECK_TIMEOUT)
    if rc == -1:
        return "kubectl timed out or exceeded output limit", None, None
    return (None, None, None) if rc == 0 else ("kubectl returned non-zero", None, None)


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


# ── Untrusted-text helpers ────────────────────────────────────────────────────
# Names and reasons come from the cluster API. They are only ever shown as
# plain text, but they are still normalised here so nothing odd (control
# characters, huge strings) reaches the panel.

_NAME_BAD   = re.compile(r"[^A-Za-z0-9._:/-]")
_REASON_BAD = re.compile(r"[^A-Za-z0-9._: /+-]")


def _safe_name(value: Any, maxlen: int = MAX_NAME_LEN) -> str:
    return _NAME_BAD.sub("?", str(value if value is not None else ""))[:maxlen]


def _safe_reason(value: Any) -> str:
    return _REASON_BAD.sub("?", str(value if value is not None else "")).strip()[:MAX_REASON_LEN]


def _safe_namespace(value: Any) -> str:
    text = str(value if value is not None else "")
    return text if len(text) <= 63 and NS_RE.match(text) else "?"


def _as_int(value: Any) -> int:
    try:
        return max(0, int(value))
    except (TypeError, ValueError):
        return 0


# ── Issue detection (nodes / pods / deployments that need attention) ──────────

def _node_issue(node: dict) -> tuple[str, str] | None:
    """(severity, reason) for a node that is not Ready or is under pressure."""
    conditions = node.get("status", {}).get("conditions", []) or []
    pressure = [c.get("type") for c in conditions
                if c.get("type") in PRESSURE_CONDITIONS and c.get("status") == "True"]
    if not _node_ready(node):
        reasons = ["NotReady"] + pressure
        return "failed", " · ".join(reasons)
    if pressure:
        return "warning", " · ".join(pressure)
    return None


def _pod_issue(pod: dict) -> tuple[str, str, int] | None:
    """
    (severity, reason, restarts) for a pod that is not ready; None for a
    ready pod. Exactly the pods _pod_ready() rejects, so the issue list and
    the pods ready/total counters always agree.
    """
    if _pod_ready(pod):
        return None
    status   = pod.get("status", {}) or {}
    phase    = status.get("phase", "")
    statuses = list(status.get("initContainerStatuses", []) or []) + \
               list(status.get("containerStatuses", []) or [])
    restarts = sum(_as_int(cs.get("restartCount")) for cs in statuses)

    reason = ""
    if phase == "Failed":
        reason = status.get("reason") or "Failed"
    else:
        for cs in statuses:
            state = cs.get("state", {}) or {}
            waiting = state.get("waiting")
            if waiting and waiting.get("reason"):
                reason = waiting["reason"]
                break
            term = state.get("terminated")
            if term and _as_int(term.get("exitCode")) != 0:
                reason = term.get("reason") or "Error"
                break
        if not reason and phase == "Pending":
            for cond in status.get("conditions", []) or []:
                if cond.get("type") == "PodScheduled" and cond.get("status") == "False":
                    reason = cond.get("reason") or "Unschedulable"
                    break
            reason = reason or "Pending"
        reason = reason or "NotReady"
    reason = _safe_reason(reason) or "NotReady"
    return ("failed" if reason in FAILED_REASONS else "warning"), reason, restarts


def _deployment_issue(dep: dict) -> tuple[str, str] | None:
    if _deployment_ready(dep):
        return None
    spec   = _as_int(dep.get("spec", {}).get("replicas", 1))
    status = dep.get("status", {}) or {}
    ready  = _as_int(status.get("readyReplicas"))
    return ("failed" if ready == 0 else "warning"), f"{ready}/{spec} ready"


_SEVERITY_RANK = {"failed": 0, "warning": 1, "healthy": 2}
_KIND_RANK     = {"node": 0, "pod": 1, "deployment": 2}


def _ns_allowed(namespace: str, include: set[str], exclude: set[str]) -> bool:
    if namespace in exclude:
        return False          # an explicit exclusion always wins
    return not include or namespace in include


def _list_objects(resource: str, context: str, include: set[str]) -> tuple[dict, str | None]:
    """
    Pods or deployments of a context. With a short list of included
    namespaces each one is queried directly (-n NS), so the response only
    holds what is going to be shown; otherwise the whole cluster is listed
    and filtered afterwards. Returns ({"items": [...]}, first_error).
    """
    if not include or len(include) > MAX_NS_QUERIES:
        data, err = _kubectl(["get", resource, "--all-namespaces"], context)
        return (data if isinstance(data, dict) else {}), err
    items: list = []
    first_error: str | None = None
    for namespace in sorted(include):
        data, err = _kubectl(["get", resource, "--namespace", namespace], context)
        if err:
            first_error = first_error or err
            continue
        if isinstance(data, dict):
            items.extend(data.get("items", []) or [])
    return {"items": items}, first_error


# ── Per-context fetch ─────────────────────────────────────────────────────────

def fetch_context(context: str, include: set[str] | None = None,
                  exclude: set[str] | None = None) -> dict[str, Any]:
    """
    Fetch node, pod, and deployment data for a single kubectl context.
    Returns a normalized cluster dict.
    """
    errors: list[str] = []
    include = include or set()
    exclude = exclude or set()

    nodes_data, nodes_err = _kubectl(["get", "nodes"], context)
    pods_data, pods_err = _list_objects("pods", context, include)
    deps_data, deps_err = _list_objects("deployments", context, include)

    for err in (nodes_err, pods_err, deps_err):
        if err and err not in errors:
            errors.append(err)

    nodes       = nodes_data.get("items", []) if isinstance(nodes_data, dict) else []
    pods        = pods_data.get("items",  []) if isinstance(pods_data,  dict) else []
    deployments = deps_data.get("items",  []) if isinstance(deps_data,  dict) else []
    # The namespace filter applies to pods and deployments (nodes are cluster-wide).
    pods        = [p for p in pods if _ns_allowed(_safe_namespace(p.get("metadata", {}).get("namespace")), include, exclude)]
    deployments = [d for d in deployments if _ns_allowed(_safe_namespace(d.get("metadata", {}).get("namespace")), include, exclude)]

    nodes_ready = sum(1 for n in nodes if _node_ready(n))
    pods_ready  = sum(1 for p in pods  if _pod_ready(p))
    deps_ready  = sum(1 for d in deployments if _deployment_ready(d))

    # ── Things that need attention + per-namespace breakdown ─────────────────
    issues: list[dict[str, Any]] = []
    namespaces: dict[str, dict[str, Any]] = {}

    def _ns(name: str) -> dict[str, Any]:
        return namespaces.setdefault(name, {
            "name": name, "severity": "healthy",
            "pods": {"ready": 0, "total": 0},
            "deployments": {"ready": 0, "total": 0},
        })

    def _raise(entry: dict[str, Any], severity: str) -> None:
        if _SEVERITY_RANK[severity] < _SEVERITY_RANK[entry["severity"]]:
            entry["severity"] = severity

    for node in nodes:
        found = _node_issue(node)
        if found:
            issues.append({"kind": "node", "severity": found[0], "reason": found[1], "restarts": 0,
                           "name": _safe_name(node.get("metadata", {}).get("name")), "namespace": ""})

    for pod in pods:
        ns_name = _safe_namespace(pod.get("metadata", {}).get("namespace"))
        entry = _ns(ns_name)
        entry["pods"]["total"] += 1
        found = _pod_issue(pod)
        if found is None:
            entry["pods"]["ready"] += 1
            continue
        _raise(entry, found[0])
        issues.append({"kind": "pod", "severity": found[0], "reason": found[1], "restarts": found[2],
                       "name": _safe_name(pod.get("metadata", {}).get("name")), "namespace": ns_name})

    for dep in deployments:
        ns_name = _safe_namespace(dep.get("metadata", {}).get("namespace"))
        entry = _ns(ns_name)
        entry["deployments"]["total"] += 1
        found = _deployment_issue(dep)
        if found is None:
            entry["deployments"]["ready"] += 1
            continue
        _raise(entry, found[0])
        issues.append({"kind": "deployment", "severity": found[0], "reason": found[1], "restarts": 0,
                       "name": _safe_name(dep.get("metadata", {}).get("name")), "namespace": ns_name})

    issues.sort(key=lambda i: (_SEVERITY_RANK[i["severity"]], _KIND_RANK[i["kind"]], i["namespace"], i["name"]))
    ns_list = sorted(namespaces.values(),
                     key=lambda n: (_SEVERITY_RANK[n["severity"]], -n["pods"]["total"], n["name"]))

    # Derive per-cluster status. A query that failed (too large, no permission,
    # timeout) must never look like an empty, healthy list: it is at least a warning.
    if nodes_err and pods_err and deps_err:
        # Nothing could be read at all (unreachable cluster, expired login, ...).
        cluster_status = "offline"
    elif (
        errors or
        nodes_ready  < len(nodes)       or
        pods_ready   < len(pods)        or
        deps_ready   < len(deployments) or
        issues
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

    result["issues"] = issues[:MAX_ISSUES]
    if len(issues) > MAX_ISSUES:
        result["issuesTotal"] = len(issues)
    result["namespaces"] = ns_list[:MAX_NAMESPACES]
    if len(ns_list) > MAX_NAMESPACES:
        result["namespacesTotal"] = len(ns_list)

    # Node breakdown (useful for multi-role clusters)
    if nodes:
        result["nodeDetail"] = {
            "controlPlane": sum(1 for n in nodes if _node_role(n) in ("control-plane", "master")),
            "workers":      sum(1 for n in nodes if _node_role(n) == "worker"),
        }

    if errors:
        # Error text comes from kubectl: drop control characters, bound the length.
        result["warnings"] = [re.sub(r"[\x00-\x1f\x7f]", " ", e).strip()[:MAX_WARNING_LEN + 1]
                              for e in errors[:MAX_WARNINGS]]
    if cluster_status == "offline":
        # Nothing could be read: show "—" instead of a misleading 0/0.
        result["nodes"] = {}
        result["pods"] = {}
        result["deployments"] = {}

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

def _fit(payload: dict) -> str | None:
    """
    JSON for the panel, within MAX_OUTPUT_BYTES. If the detail makes it too
    big, drop the optional detail first (namespace breakdown, then trim the
    issue lists) before giving up, so the panel still gets the counters.
    """
    output = json.dumps(payload)
    if len(output.encode()) <= MAX_OUTPUT_BYTES:
        return output
    clusters = payload.get("clusters")
    if isinstance(clusters, list):
        for c in clusters:
            if isinstance(c, dict) and "namespaces" in c:
                c["namespacesTotal"] = c.get("namespacesTotal", len(c["namespaces"]))
                c["namespaces"] = []
        output = json.dumps(payload)
        if len(output.encode()) <= MAX_OUTPUT_BYTES:
            return output
        for c in clusters:
            if isinstance(c, dict) and isinstance(c.get("issues"), list):
                c["issuesTotal"] = c.get("issuesTotal", len(c["issues"]))
                c["issues"] = c["issues"][:5]
        output = json.dumps(payload)
        if len(output.encode()) <= MAX_OUTPUT_BYTES:
            return output
    return None


def emit(payload: dict) -> None:
    output = _fit(payload)
    if output is None:
        emit_error("Output exceeded size limit — reduce number of contexts or namespaces")
        return
    print(output)


def emit_error(error: str, status: str = "offline",
                error_code: str | None = None, dependency: str | None = None) -> None:
    payload = {"provider": PROVIDER, "status": status, "error": error}
    if error_code:
        payload["errorCode"] = error_code
    if dependency:
        payload["dependency"] = dependency
    emit(payload)


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch Kubernetes cluster status")
    parser.add_argument("--mock",    action="store_true",  help="Use mock data")
    parser.add_argument("--mock-error", choices=["missing-dependency", "generic"], default=None,
                        help="Dev aid, only with --mock: emit a synthetic error instead of "
                             "the mock fixture, to test the panel's error UI without touching "
                             "the real kubectl binary")
    parser.add_argument("--context", action="append",      help="Context(s) to query", default=[])
    parser.add_argument("--all-contexts", action="store_true", help="Query all kubeconfig contexts")
    parser.add_argument("--namespace", action="append", default=[],
                        help="Only count these namespaces (repeatable; use --namespace=NAME)")
    parser.add_argument("--exclude-namespace", action="append", default=[],
                        help="Ignore these namespaces (repeatable; wins over --namespace)")
    args = parser.parse_args()

    # ── Mock mode ──────────────────────────────────────────────────────────────
    if args.mock:
        if args.mock_error == "missing-dependency":
            emit_error("kubectl not found — install kubectl",
                       error_code="missing_dependency", dependency="kubectl")
            return 0
        if args.mock_error == "generic":
            emit_error("No active kubectl context — run: kubectl config use-context <name>")
            return 0
        try:
            emit(json.loads(MOCK_FILE.read_text()))
        except Exception as exc:
            emit_error(f"Failed to load mock file: {exc}")
        return 0

    # ── Namespace filter validation ────────────────────────────────────────────
    for label, values in (("namespace", args.namespace), ("exclude-namespace", args.exclude_namespace)):
        if len(values) > MAX_NS_FILTERS:
            emit_error(f"Too many {label} entries ({len(values)}) — max is {MAX_NS_FILTERS}")
            return 1
        for value in values:
            if not isinstance(value, str) or len(value) > 63 or not NS_RE.match(value):
                emit_error(f"Invalid {label} name — must be a Kubernetes namespace (lowercase letters, digits, '-')")
                return 1
    include = set(args.namespace)
    exclude = set(args.exclude_namespace)

    # ── Dependency check ───────────────────────────────────────────────────────
    err, error_code, dependency = check_kubectl()
    if err:
        emit_error(err, error_code=error_code, dependency=dependency)
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
    clusters = [fetch_context(ctx, include, exclude) for ctx in contexts]

    # ── Normalize and emit ─────────────────────────────────────────────────────
    emit(normalize(clusters))
    return 0


if __name__ == "__main__":
    sys.exit(main())
