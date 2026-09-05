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
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

# ── Constants ─────────────────────────────────────────────────────────────────

PROVIDER  = "kubernetes"
MOCK_FILE = Path(__file__).parent.parent / "mock" / "kubernetes.json"


# ── CLI helper ────────────────────────────────────────────────────────────────

def _kubectl(args: list[str], context: str) -> tuple[dict | list, str | None]:
    """
    Run a kubectl command for a specific context.
    Returns (parsed_json, error_string).
    Never raises.
    """
    cmd = ["kubectl"] + args + ["--context", context, "--output", "json"]
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=20,
        )
    except FileNotFoundError:
        return {}, "kubectl not found — install kubectl"
    except subprocess.TimeoutExpired:
        return {}, f"kubectl timed out for context '{context}'"
    except Exception as exc:
        return {}, str(exc)

    if result.returncode != 0:
        err = result.stderr.strip() or f"kubectl exited {result.returncode}"
        return {}, err

    try:
        return json.loads(result.stdout), None
    except json.JSONDecodeError as exc:
        return {}, f"JSON parse error: {exc}"


# ── Dependency / auth checks ──────────────────────────────────────────────────

def check_kubectl() -> str | None:
    try:
        r = subprocess.run(["kubectl", "version", "--client"], capture_output=True, timeout=10)
        return None if r.returncode == 0 else "kubectl returned non-zero"
    except FileNotFoundError:
        return "kubectl not found — install kubectl"
    except subprocess.TimeoutExpired:
        return "kubectl timed out"


def get_current_context() -> tuple[str, str | None]:
    """Return (current_context_name, error)."""
    try:
        r = subprocess.run(
            ["kubectl", "config", "current-context"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if r.returncode != 0:
            return "", "No active kubectl context — run: kubectl config use-context <name>"
        return r.stdout.strip(), None
    except FileNotFoundError:
        return "", "kubectl not found"
    except subprocess.TimeoutExpired:
        return "", "kubectl config timed out"


def list_contexts() -> list[str]:
    """Return all context names from kubeconfig."""
    try:
        r = subprocess.run(
            ["kubectl", "config", "get-contexts", "--output", "name"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if r.returncode != 0:
            return []
        return [line.strip() for line in r.stdout.splitlines() if line.strip()]
    except Exception:
        return []


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


# ── Output helpers ────────────────────────────────────────────────────────────

def emit(payload: dict) -> None:
    print(json.dumps(payload))


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

    # ── Fetch each context ─────────────────────────────────────────────────────
    clusters = [fetch_context(ctx) for ctx in contexts]

    # ── Normalize and emit ─────────────────────────────────────────────────────
    emit(normalize(clusters))
    return 0


if __name__ == "__main__":
    sys.exit(main())
