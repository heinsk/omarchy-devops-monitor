#!/usr/bin/env python3
"""
scripts/azure_devops.py
Fetch Azure DevOps pipeline, release, and deployment status.

Supports multiple organizations and projects simultaneously.

Outputs a single normalized JSON object to stdout.
Exits 0 on success, 1 on unrecoverable failure.

Usage:
    azure_devops.py [--mock] [--top N]
                    [--target ORG PROJECT [--target ORG2 PROJECT2 ...]]

    Each --target takes exactly two arguments: organization URL and project name.
    Repeat --target once per project you want to monitor.

Examples:
    # Single org, single project
    azure_devops.py --target https://dev.azure.com/my-org my-project

    # Multiple projects in the same org
    azure_devops.py \
        --target https://dev.azure.com/my-org project-alpha \
        --target https://dev.azure.com/my-org project-beta

    # Multiple orgs
    azure_devops.py \
        --target https://dev.azure.com/org-one  project-alpha \
        --target https://dev.azure.com/org-two  project-gamma

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
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

# ── Constants ─────────────────────────────────────────────────────────────────

PROVIDER  = "azure-devops"
MOCK_FILE = Path(__file__).parent.parent / "mock" / "azure-devops.json"

PIPELINE_RUNNING_STATES = {"inprogress", "running", "cancelling"}
PIPELINE_SUCCESS_STATES = {"succeeded", "success", "partiallysucceeded"}
PIPELINE_FAILED_STATES  = {"failed", "failure", "canceled", "cancelled"}

RELEASE_RUNNING_STATES  = {"inprogress", "active", "queued", "scheduled"}
RELEASE_SUCCESS_STATES  = {"succeeded", "success", "partiallysucceeded"}
RELEASE_FAILED_STATES   = {"failed", "failure", "rejected", "abandoned", "canceled", "cancelled"}


# ── CLI helpers ───────────────────────────────────────────────────────────────

def _run(args: list[str]) -> tuple[list[Any], str | None]:
    """
    Run an az CLI command and return (parsed_json_list, error_string).
    Never raises; returns an empty list and an error string on failure.
    """
    cmd = args + ["--output", "json"]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except FileNotFoundError:
        return [], "az CLI not found — install azure-cli"
    except subprocess.TimeoutExpired:
        return [], f"Command timed out: {' '.join(cmd[:5])}"
    except Exception as exc:
        return [], str(exc)

    if result.returncode != 0:
        err = _scrub(result.stderr.strip()) or f"az exited {result.returncode}"
        return [], err

    try:
        data = json.loads(result.stdout)
        if isinstance(data, dict):
            data = [data]
        return data or [], None
    except json.JSONDecodeError as exc:
        return [], f"JSON parse error: {exc}"


def _scrub(text: str) -> str:
    """Redact anything resembling a bearer token or secret."""
    return re.sub(r"[A-Za-z0-9+/]{40,}={0,2}", "[REDACTED]", text)


# ── Dependency / auth checks ──────────────────────────────────────────────────

def check_az() -> str | None:
    try:
        r = subprocess.run(["az", "--version"], capture_output=True, timeout=10)
        return None if r.returncode == 0 else "az CLI returned non-zero on --version"
    except FileNotFoundError:
        return "az CLI not found — install azure-cli"
    except subprocess.TimeoutExpired:
        return "az CLI timed out"


def check_az_devops() -> str | None:
    """`az devops --version` is invalid — probe with `az extension show` instead."""
    try:
        r = subprocess.run(
            ["az", "extension", "show", "--name", "azure-devops"],
            capture_output=True,
            timeout=10,
        )
        return None if r.returncode == 0 else (
            "az devops extension not installed — run: "
            "az extension add --name azure-devops"
        )
    except FileNotFoundError:
        return "az CLI not found"
    except subprocess.TimeoutExpired:
        return "az extension show timed out"


def check_auth() -> str | None:
    try:
        r = subprocess.run(["az", "account", "show"], capture_output=True, timeout=10)
        return None if r.returncode == 0 else "Not logged in to Azure — run: az login"
    except Exception as exc:
        return str(exc)


# ── Per-target fetchers ───────────────────────────────────────────────────────

def fetch_target(org: str, project: str, top: int) -> dict[str, Any]:
    """
    Fetch pipeline runs and releases for a single org+project combination.
    Returns a normalized target dict — never raises.
    """
    base = ["--org", org, "--project", project]

    runs,     runs_err     = _run(["az", "pipelines", "runs", "list",
                                   "--top", str(top), "--status", "all"] + base)
    releases_list, releases_err = _run(["az", "pipelines", "release", "list",
                                        "--top", str(top)] + base)

    # Fetch full release details to get environment statuses
    # (top-level status stays "active" even when environments are rejected/failed)
    releases = []
    for rel in releases_list:
        rel_id = rel.get("id")
        if rel_id:
            detail, detail_err = _run(["az", "pipelines", "release", "show",
                                       "--id", str(rel_id)] + base)
            if detail:
                releases.extend(detail if isinstance(detail, list) else [detail])
            else:
                releases.append(rel)  # fall back to list data
        else:
            releases.append(rel)

    pipeline_counts = _count_states(runs,     PIPELINE_RUNNING_STATES,
                                              PIPELINE_SUCCESS_STATES,
                                              PIPELINE_FAILED_STATES)
    release_counts  = _count_states(releases, RELEASE_RUNNING_STATES,
                                              RELEASE_SUCCESS_STATES,
                                              RELEASE_FAILED_STATES)

    errors = [e for e in (runs_err, releases_err) if e]

    status = _derive_status(pipeline_counts, release_counts, bool(errors),
                            bool(runs or releases))

    # Build per-pipeline list — group by pipeline name, take latest run each
    pipeline_list = _build_pipeline_list(runs, org, project)
    release_list  = _build_release_list(releases, org, project)

    result: dict[str, Any] = {
        "organization":  org,
        "project":       project,
        "status":        status,
        "pipelines":     pipeline_counts,
        "deployments":   release_counts,
        "pipelineList":  pipeline_list,
        "releaseList":   release_list,
    }
    if errors:
        result["warnings"] = errors

    return result


def _run_state(run: dict) -> str:
    """
    Derive state from a run dict.

    Azure DevOps pipelines API separates status from result:
      - status: "inProgress" | "completed" | "cancelling" | "notStarted"
      - result: "succeeded" | "failed" | "canceled" | "partiallySucceeded"

    A run is "running" when status is inProgress/cancelling.
    When status is "completed" the outcome is in the result field.
    """
    status = (run.get("status") or "").lower()
    result = (run.get("result") or "").lower()

    if status in PIPELINE_RUNNING_STATES:
        return "running"
    # For completed runs, use result field
    if result in PIPELINE_SUCCESS_STATES:
        return "success"
    if result in PIPELINE_FAILED_STATES:
        return "failed"
    # Fallback: check status itself (older API versions)
    if status in PIPELINE_SUCCESS_STATES:
        return "success"
    if status in PIPELINE_FAILED_STATES:
        return "failed"
    return "unknown"


def _build_pipeline_list(runs: list[dict], org: str, project: str) -> list[dict]:
    """Return one entry per unique pipeline name with current and last status."""
    # Collect up to two runs per pipeline (runs are newest-first)
    seen: dict[str, list[dict]] = {}
    for run in runs:
        name = run.get("pipeline", {}).get("name") or run.get("definition", {}).get("name") or "Unknown"
        if name not in seen:
            seen[name] = []
        if len(seen[name]) < 2:
            seen[name].append(run)

    result = []
    for name, pair in seen.items():
        current = pair[0]
        previous = pair[1] if len(pair) > 1 else None

        current_state = _run_state(current)

        last_state = None
        if previous:
            last_state = _run_state(previous)

        # URL
        url = ""
        links = current.get("_links", {})
        if links.get("web", {}).get("href"):
            url = links["web"]["href"]
        else:
            pipeline_id = (current.get("pipeline") or current.get("definition") or {}).get("id")
            if org and project and pipeline_id:
                url = "{}/{}/{}".format(org.rstrip("/"), project, "_build?definitionId={}".format(pipeline_id))

        # Duration of current run
        start_time  = current.get("startTime")  or current.get("createdDate")  or ""
        finish_time = current.get("finishTime") or current.get("finishedDate") or ""
        is_running  = (current.get("status") or "").lower() in PIPELINE_RUNNING_STATES
        duration_min = _duration_minutes(start_time, finish_time, is_running)

        # For running pipelines, fetch current stage via timeline
        current_stage = ""
        if current_state == "running":
            run_id = current.get("id")
            if run_id:
                # _run() appends --output json, so don't include it here
                timeline_result, _ = _run([
                    "az", "devops", "invoke",
                    "--org", org,
                    "--area", "build",
                    "--resource", "timeline",
                    "--route-parameters", "project=" + project, "buildId=" + str(run_id),
                    "--api-version", "7.1"
                ])
                # _run wraps dicts in a list, so unwrap
                timeline = timeline_result[0] if timeline_result else {}
                if isinstance(timeline, dict):
                    records = timeline.get("records") or []
                    # Find inProgress stages first
                    running_stages = [
                        r for r in records
                        if (r.get("state") or "").lower() == "inprogress"
                        and (r.get("type") or "").lower() == "stage"
                    ]
                    if running_stages:
                        current_stage = running_stages[0].get("name") or ""
                    else:
                        # Fall back to any inProgress record
                        any_running = [
                            r for r in records
                            if (r.get("state") or "").lower() == "inprogress"
                        ]
                        if any_running:
                            current_stage = any_running[0].get("name") or ""

        entry: dict = {
            "name":         name,
            "status":       current_state,
            "lastStatus":   last_state,
            "url":          url,
            "durationMin":  duration_min,
            "currentStage": current_stage,
        }
        result.append(entry)
    return result


def _duration_minutes(start: str, finish: str, is_running: bool) -> int:
    """Return elapsed minutes between start and finish (or now if still running)."""
    if not start:
        return -1
    try:
        from datetime import datetime, timezone
        fmt = "%Y-%m-%dT%H:%M:%S"
        # Strip microseconds and Z suffix for parsing
        def _parse(s: str):
            s = s.split(".")[0].rstrip("Z")
            return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
        t_start = _parse(start)
        t_end = _parse(finish) if finish and not is_running else datetime.now(timezone.utc)
        return max(0, int((t_end - t_start).total_seconds() / 60))
    except Exception:
        return -1


def _release_state(rel: dict) -> str:
    """
    Derive state from a release dict.

    The top-level release status is unreliable — it stays "active" even when
    an environment (stage) is rejected or failed. We derive the real status
    from the environments array when available (requires full release detail).

    Environment status values:
      - "succeeded"   -> success
      - "rejected"    -> failed (approval rejected)
      - "failed"      -> failed
      - "canceled"    -> failed
      - "inProgress"  -> running
      - "queued"      -> running
      - "notStarted"  -> pending (skip for overall status)
    """
    environments = rel.get("environments") or []
    if environments:
        env_statuses = [(e.get("status") or "").lower() for e in environments]
        # Any rejected/failed env means the release failed
        if any(s in {"rejected", "failed", "canceled", "cancelling"} for s in env_statuses):
            return "failed"
        if any(s in {"inprogress", "queued", "scheduled"} for s in env_statuses):
            return "running"
        if all(s == "succeeded" for s in env_statuses if s != "notstarted"):
            return "success"

    # Fall back to top-level status field
    raw = (rel.get("status") or "").lower()
    if raw in RELEASE_RUNNING_STATES:  return "running"
    if raw in RELEASE_SUCCESS_STATES:  return "success"
    if raw in RELEASE_FAILED_STATES:   return "failed"
    return "unknown"


def _build_release_list(releases: list[dict], org: str, project: str) -> list[dict]:
    """Return one entry per unique release definition with current and last status."""
    # Collect up to two releases per definition (newest-first)
    seen: dict[str, list[dict]] = {}
    for rel in releases:
        # Use definition name, not release name (e.g. "DEMO RELEASE" not "Release-1")
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

        # Build URL from definition id and release id
        # _links is sometimes an empty list instead of a dict — handle both
        url = ""
        links = current.get("_links") or {}
        if isinstance(links, dict) and links.get("web", {}).get("href"):
            url = links["web"]["href"]
        else:
            # Construct URL from org, project, and release id
            release_id = current.get("id")
            if org and project and release_id:
                url = "{}/{}/_releaseProgress?_a=release-pipeline-progress&releaseId={}".format(
                    org.rstrip("/"), project, release_id
                )

        start_time   = current.get("createdOn")  or current.get("createdDate")  or ""
        finish_time  = current.get("modifiedOn") or current.get("finishedDate") or ""
        is_running   = current_state == "running"
        duration_min = _duration_minutes(start_time, finish_time, is_running)

        result.append({
            "name":         name,
            "releaseName":  current.get("name") or "",
            "status":       current_state,
            "lastStatus":   last_state,
            "url":          url,
            "durationMin":  duration_min,
        })
    return result


# ── State counting ────────────────────────────────────────────────────────────

def _count_states(
    items: list[dict],
    running_states: set[str],
    success_states: set[str],
    failed_states: set[str],
) -> dict[str, int]:
    running = success = failed = 0
    for item in items:
        status = (item.get("status") or "").lower()
        result = (item.get("result") or "").lower()
        # Use result field when available (completed pipeline runs)
        effective = result if result else status
        if status in running_states:
            running += 1
        elif effective in success_states:
            success += 1
        elif effective in failed_states:
            failed += 1
    return {"running": running, "success": success, "failed": failed}


def _derive_status(
    pipelines: dict,
    deployments: dict,
    has_errors: bool,
    has_data: bool,
) -> str:
    if pipelines["failed"] > 0 or deployments["failed"] > 0:
        return "warning"
    if has_errors and not has_data:
        return "offline"
    if has_data:
        return "healthy"
    return "unknown"


# ── Aggregation ───────────────────────────────────────────────────────────────

def aggregate(targets: list[dict[str, Any]]) -> dict[str, Any]:
    """
    Merge per-target results into a single provider payload.

    Aggregate counts are the sum across all targets so the bar widget
    shows totals at a glance. The targets array provides the per-project
    breakdown for the panel.
    """
    def _sum(key: str, subkey: str) -> int:
        return sum(t[key][subkey] for t in targets if key in t)

    total_pipelines = {
        "running": _sum("pipelines", "running"),
        "success": _sum("pipelines", "success"),
        "failed":  _sum("pipelines", "failed"),
    }
    total_deployments = {
        "running": _sum("deployments", "running"),
        "success": _sum("deployments", "success"),
        "failed":  _sum("deployments", "failed"),
    }

    statuses = [t["status"] for t in targets]
    if "warning" in statuses or "critical" in statuses:
        overall = "warning"
    elif "offline" in statuses:
        overall = "warning"
    elif all(s == "healthy" for s in statuses):
        overall = "healthy"
    elif all(s == "unknown" for s in statuses):
        overall = "unknown"
    else:
        overall = "healthy"

    return {
        "provider":    PROVIDER,
        "status":      overall,
        "pipelines":   total_pipelines,
        "deployments": total_deployments,
        "targets":     targets,
    }


# ── Output helpers ────────────────────────────────────────────────────────────

def emit(payload: dict) -> None:
    print(json.dumps(payload))


def emit_error(error: str, status: str = "offline") -> None:
    emit({"provider": PROVIDER, "status": status, "error": error})


# ── Argument parsing ──────────────────────────────────────────────────────────

class TargetAction(argparse.Action):
    """
    Consume exactly two values per --target flag: organization URL and project.

    Usage: --target https://dev.azure.com/my-org my-project
    """
    def __call__(self, parser, namespace, values, option_string=None):
        if len(values) != 2:
            parser.error(f"--target requires exactly 2 arguments: ORG PROJECT, got {len(values)}")
        targets = getattr(namespace, self.dest, None) or []
        targets.append({"org": values[0], "project": values[1]})
        setattr(namespace, self.dest, targets)


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Fetch Azure DevOps status across multiple organizations and projects",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Single project
  azure_devops.py --target https://dev.azure.com/my-org my-project

  # Multiple projects, same org
  azure_devops.py \\
      --target https://dev.azure.com/my-org project-alpha \\
      --target https://dev.azure.com/my-org project-beta

  # Multiple orgs
  azure_devops.py \\
      --target https://dev.azure.com/org-one project-alpha \\
      --target https://dev.azure.com/org-two project-gamma
        """,
    )
    parser.add_argument("--mock", action="store_true", help="Use mock data")
    parser.add_argument("--top",  type=int, default=50, help="Max items per query per target")
    parser.add_argument(
        "--target",
        nargs=2,
        metavar=("ORG", "PROJECT"),
        action=TargetAction,
        dest="targets",
        help="Organization URL and project name (repeat for multiple targets)",
    )
    args = parser.parse_args()

    # ── Mock mode ──────────────────────────────────────────────────────────────
    if args.mock:
        try:
            emit(json.loads(MOCK_FILE.read_text()))
        except Exception as exc:
            emit_error(f"Failed to load mock file: {exc}")
        return 0

    # ── Dependency / auth checks ───────────────────────────────────────────────
    for check in (check_az, check_az_devops, check_auth):
        err = check()
        if err:
            emit_error(err)
            return 1

    # ── Resolve targets ────────────────────────────────────────────────────────
    targets = args.targets or []
    if not targets:
        emit_error(
            "No targets configured. Add at least one target to config.json under "
            "azureDevOps.targets: [{\"organization\": \"...\", \"project\": \"...\"}]"
        )
        return 1

    # ── Fetch each target ──────────────────────────────────────────────────────
    results = [fetch_target(t["org"], t["project"], args.top) for t in targets]

    # ── Aggregate and emit ─────────────────────────────────────────────────────
    emit(aggregate(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
