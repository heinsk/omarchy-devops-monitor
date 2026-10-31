#!/usr/bin/env python3
"""
job_detail.py — Jobs, tasks and error messages of ONE run, on demand.

The panel calls this only when a row is expanded, so the regular refresh
stays as light as before. It never changes anything: it only reads.

    job_detail.py --azure-build ORG PROJECT BUILD_ID
    job_detail.py --github-run OWNER/REPO RUN_ID [--gh-path=PATH]
    job_detail.py --mock azure|github ID            (reads mock/job-detail.json)

Output (one JSON object on stdout):

    { "ok": true,  "provider": "azure-devops" | "github-actions",
      "jobs": [ { "name", "stage", "status", "durationSec", "messages": [str],
                  "tasks": [ { "name", "status", "durationSec", "messages": [str] } ] } ] }
    { "ok": false, "error": "short plain-text reason" }

status is one of: success, failed, running, pending, cancelled, skipped, unknown.

Where the data comes from
  Azure DevOps  az devops invoke --area build --resource timeline  (same call the
                status refresh already uses for running pipelines); each record's
                `issues` holds the error messages.
  GitHub        gh api repos/OWNER/REPO/actions/runs/RUN_ID/jobs  for jobs and steps;
                for failed jobs, gh api repos/OWNER/REPO/check-runs/JOB_ID/annotations
                for the failure messages.

Security: arguments are validated again here (the same rules as the provider
scripts), commands run without a shell with absolute paths and a minimal
environment, output and time are capped, and every text is reduced to
printable characters and bounded before it is printed.
"""
from __future__ import annotations

import argparse
import json
import re
import signal
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import azure_devops as az  # noqa: E402
import github_actions as gh  # noqa: E402

MOCK_FILE        = Path(__file__).resolve().parent.parent / "mock" / "job-detail.json"
MAX_OUTPUT_BYTES = 128 * 1024
MAX_FAILED_LOOKUPS = 5      # failed GitHub jobs whose annotations are read
GH_API_TIMEOUT   = 20       # seconds per gh call
GH_TOTAL_BUDGET  = 40       # seconds after which no more annotation lookups are started


def _cleanup_and_exit(signum, frame) -> None:
    for proc in list(az._active_procs) + list(gh._active_procs):
        try:
            az._kill_pgroup(proc)
        except Exception:
            pass
    sys.exit(1)


signal.signal(signal.SIGTERM, _cleanup_and_exit)
signal.signal(signal.SIGINT,  _cleanup_and_exit)


def emit(payload: dict) -> int:
    output = json.dumps(payload)
    if len(output.encode()) > MAX_OUTPUT_BYTES:
        output = json.dumps({"ok": False, "error": "Detail is too large to show"})
    print(output)
    return 0 if payload.get("ok") else 1


def fail(message: str) -> int:
    return emit({"ok": False, "error": gh._clean(message, 200) or "Could not read the details"})


def _id(value: str) -> int:
    return az._safe_id(value) if isinstance(value, str) and value.isdigit() else 0


# ── Azure DevOps ──────────────────────────────────────────────────────────────

def azure_build(org: str, project: str, build_id: int) -> int:
    if not az._validate_org(org):
        return fail("Invalid organization URL")
    if not az._validate_project(project):
        return fail("Invalid project name")
    data, err = az._run([
        "az", "devops", "invoke",
        "--org", org,
        "--area", "build",
        "--resource", "timeline",
        "--route-parameters", "project=" + project, "buildId=" + str(build_id),
        "--api-version", "7.1",
    ])
    if err:
        return fail(err)
    timeline = data[0] if data else {}
    jobs = az.parse_timeline(timeline)
    return emit({"ok": True, "provider": "azure-devops", "jobs": jobs})


# ── GitHub Actions ────────────────────────────────────────────────────────────

def _gh_status(status: Any, conclusion: Any) -> str:
    st = str(status or "").lower()
    cc = str(conclusion or "").lower()
    if st == "in_progress":
        return "running"
    if st in ("queued", "pending", "waiting", "requested"):
        return "pending"
    if cc == "success":
        return "success"
    if cc in ("failure", "timed_out", "startup_failure"):
        return "failed"
    if cc == "cancelled":
        return "cancelled"
    if cc in ("skipped", "neutral", "stale"):
        return "skipped"
    return "unknown"


def _gh_api(endpoint: str) -> tuple[Any, str | None]:
    """GET one GitHub API endpoint with gh. Returns (parsed_json, error)."""
    try:
        cmd = [gh._find_gh(), "api", "-H", "Accept: application/vnd.github+json", endpoint]
    except (RuntimeError, ValueError) as exc:
        return None, str(exc)
    rc, out, err, problem = gh._exec(cmd, GH_API_TIMEOUT)
    if problem:
        return None, problem
    if rc != 0:
        return None, gh._clean(gh._scrub(err.decode("utf-8", errors="replace").strip()), 200) or f"gh exited {rc}"
    try:
        return json.loads(out), None
    except Exception:
        return None, "Unexpected gh output"


def _annotation_messages(items: Any) -> list[str]:
    out: list[str] = []
    if not isinstance(items, list):
        return out
    for a in items:
        if not isinstance(a, dict) or str(a.get("annotation_level") or "").lower() != "failure":
            continue
        msg = az._message(a.get("message"))
        if msg and msg not in out:
            out.append(msg)
        if len(out) >= az.MAX_DETAIL_MESSAGES:
            break
    return out


def parse_github_jobs(payload: Any) -> list[dict]:
    jobs_in = payload.get("jobs") if isinstance(payload, dict) else None
    if not isinstance(jobs_in, list):
        return []
    jobs: list[dict] = []
    for j in jobs_in:
        if not isinstance(j, dict) or len(jobs) >= az.MAX_DETAIL_JOBS:
            continue
        tasks = []
        steps = j.get("steps")
        for s in (steps if isinstance(steps, list) else []):
            if not isinstance(s, dict) or len(tasks) >= az.MAX_DETAIL_TASKS:
                continue
            tasks.append({
                "name":        gh._clean(s.get("name"), 80) or "step",
                "status":      _gh_status(s.get("status"), s.get("conclusion")),
                "durationSec": az._seconds(s.get("started_at"), s.get("completed_at")),
                "messages":    [],
            })
        jobs.append({
            "_id":         az._safe_id(j.get("id")),
            "name":        gh._clean(j.get("name"), 80) or "job",
            "stage":       "",
            "status":      _gh_status(j.get("status"), j.get("conclusion")),
            "durationSec": az._seconds(j.get("started_at"), j.get("completed_at")),
            "messages":    [],
            "tasks":       tasks,
        })
    return jobs


def github_run(repo: str, run_id: int) -> int:
    if not gh._validate_repo(repo):
        return fail("Invalid repository")
    started = time.monotonic()
    payload, err = _gh_api("repos/%s/actions/runs/%d/jobs?per_page=30" % (repo, run_id))
    if err:
        return fail(err)
    jobs = parse_github_jobs(payload)
    lookups = 0
    for job in jobs:
        if job["status"] != "failed" or not job["_id"] or lookups >= MAX_FAILED_LOOKUPS:
            continue
        if time.monotonic() - started > GH_TOTAL_BUDGET:
            break
        lookups += 1
        items, aerr = _gh_api("repos/%s/check-runs/%d/annotations?per_page=10" % (repo, job["_id"]))
        if not aerr:
            job["messages"] = _annotation_messages(items)
    for job in jobs:
        job.pop("_id", None)
    return emit({"ok": True, "provider": "github-actions", "jobs": jobs})


# ── Mock (development aid) ────────────────────────────────────────────────────

def mock(kind: str, ident: str) -> int:
    try:
        data = json.loads(MOCK_FILE.read_text())
        group = data[kind]
        jobs = group.get(ident) or group.get("default") or []
    except Exception as exc:
        return fail("Failed to load mock file: %s" % exc)
    provider = "azure-devops" if kind == "azure" else "github-actions"
    return emit({"ok": True, "provider": provider, "jobs": jobs})


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description="Jobs, tasks and errors of one run")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--azure-build", nargs=3, metavar=("ORG", "PROJECT", "BUILD_ID"))
    group.add_argument("--github-run", nargs=2, metavar=("OWNER/REPO", "RUN_ID"))
    group.add_argument("--mock", nargs=2, metavar=("azure|github", "ID"))
    parser.add_argument("--gh-path", dest="gh_path", default="", metavar="PATH")
    args = parser.parse_args()

    if args.mock:
        kind, ident = args.mock
        if kind not in ("azure", "github") or not re.match(r"^[0-9]{1,12}$", ident):
            return fail("Invalid mock request")
        return mock(kind, ident)

    if args.azure_build:
        org, project, raw_id = args.azure_build
        build_id = _id(raw_id)
        if not build_id:
            return fail("Invalid build id")
        return azure_build(org, project, build_id)

    repo, raw_id = args.github_run
    run_id = _id(raw_id)
    if not run_id:
        return fail("Invalid run id")
    gh._GH_CONFIGURED = args.gh_path or ""
    return github_run(repo, run_id)


if __name__ == "__main__":
    sys.exit(main())
