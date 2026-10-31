"""Jobs, tasks and error messages of one run: parsing, limits, cleaning, the command line and the fake CLIs."""
import contextlib
import io
import json
from support import *          # also puts scripts/ on sys.path

import azure_devops as az
import github_actions as gh
import job_detail as jd


def run_main(argv):
    """Run job_detail.main() in this process; return (exit code, parsed JSON or None)."""
    out = io.StringIO()
    old = sys.argv
    sys.argv = ["job_detail.py"] + argv
    try:
        with contextlib.redirect_stdout(out):
            try:
                rc = jd.main()
            except SystemExit as exc:      # argparse errors
                rc = exc.code if isinstance(exc.code, int) else 2
    finally:
        sys.argv = old
    try:
        return rc, json.loads(out.getvalue())
    except Exception:
        return rc, None


# ── Azure DevOps build timeline ───────────────────────────────────────────────
T = lambda **k: k
timeline = {"records": [
    T(id="s1", type="Stage", name="CI", order=1),
    T(id="p1", type="Phase", name="Phase", parentId="s1", order=1),
    T(id="j2", type="Job", name="Test", parentId="p1", order=2, state="completed", result="failed",
      startTime="2026-01-01T10:00:00Z", finishTime="2026-01-01T10:05:00.123Z"),
    T(id="j1", type="Job", name="Build", parentId="p1", order=1, state="completed", result="succeeded",
      startTime="2026-01-01T10:00:00Z", finishTime="2026-01-01T10:03:00Z"),
    T(id="t3", type="Task", name="Publish", parentId="j2", order=2, state="completed", result="succeeded"),
    T(id="t2", type="Task", name="Run ‮unit​ tests", parentId="j2", order=1, state="completed", result="failed",
      startTime="2026-01-01T10:00:10Z", finishTime="2026-01-01T10:04:10Z", errorCount=1,
      issues=[T(type="error", message="Process completed with exit code 1.\n\tThree tests failed\x1b[31m"),
              T(type="warning", message="a warning is not shown"),
              T(type="error", message="Process completed with exit code 1. Three tests failed"),
              "junk", None]),
    T(id="t1", type="Task", name="Checkout", parentId="j1", order=1, state="completed", result="succeeded"),
    T(id="j3", type="Job", name="Package", parentId="p1", order=3, state="completed", result="skipped"),
    T(id="j4", type="Job", name="Deploy", parentId="p1", order=4, state="inProgress"),
    "junk", None, 5,
]}
jobs = az.parse_timeline(timeline)
check("jobs come in timeline order", [j["name"] for j in jobs] == ["Build", "Test", "Package", "Deploy"], jobs)
check("the stage of a job is found through its phase", jobs[0]["stage"] == "CI")
check("job status and duration are read", jobs[0]["status"] == "success" and jobs[0]["durationSec"] == 180
      and jobs[1]["status"] == "failed" and jobs[1]["durationSec"] == 300)
check("skipped and running jobs", jobs[2]["status"] == "skipped" and jobs[3]["status"] == "running" and jobs[3]["durationSec"] == -1)
tasks = jobs[1]["tasks"]
check("tasks belong to their job, in order", [t["name"] for t in tasks][1:] == ["Publish"] and len(tasks) == 2, tasks)
check("task text has no control, zero-width or bidi characters", tasks[0]["name"] == "Run unit tests", repr(tasks[0]["name"]))
check("only error issues are kept, cleaned, de-duplicated and on one line",
      tasks[0]["messages"] == ["Process completed with exit code 1. Three tests failed [31m",
                               "Process completed with exit code 1. Three tests failed"], tasks[0]["messages"])
check("a task with no issues has no messages", tasks[1]["messages"] == [])
check("junk records and a missing timeline give an empty list",
      az.parse_timeline(None) == [] and az.parse_timeline({}) == [] and az.parse_timeline({"records": "x"}) == [])

big = {"records": [T(id="j%d" % i, type="Job", name="job %d" % i, order=i) for i in range(100)]
       + [T(id="t%d" % i, type="Task", name="t", parentId="j0", order=i,
            issues=[T(type="error", message="x" * 5000)] * 10) for i in range(200)]}
bj = az.parse_timeline(big)
check("jobs are limited", len(bj) == az.MAX_DETAIL_JOBS)
check("tasks per job are limited", len(bj[0]["tasks"]) == az.MAX_DETAIL_TASKS)
check("messages per task and their length are limited",
      all(len(t["messages"]) == 1 and len(t["messages"][0]) == az.MAX_DETAIL_MSG_LEN for t in bj[0]["tasks"]))

check("ids: only positive integers", [az._safe_id(v) for v in (5, "17", 0, -3, True, "x", "1;2", None, 10 ** 13, "9" * 13)]
      == [5, 17, 0, 0, 0, 0, 0, 0, 0, 0])

# ── Azure DevOps release stages (from the release that was already read) ──────
def release(status, attempts):
    return {"environments": [{"name": "Prod", "status": status, "deploySteps": attempts}]}
def attempt(*tasks, log=None):
    return {"releaseDeployPhases": [{"errorLog": log, "deploymentJobs": [{"tasks": list(tasks)}]}]}
RT = lambda n, s, **k: dict(name=n, status=s, **k)
rel = release("rejected", [
    attempt(RT("old failure", "failed")),
    attempt(RT("Download", "succeeded"), RT("Deploy to AKS", "failed", startTime="2026-01-01T10:00:00Z",
            finishTime="2026-01-01T10:08:00Z", issues=[{"issueType": "Error", "message": "rollout timed out"},
                                                      {"issueType": "Warning", "message": "slow"}]),
            RT("Cleanup", "skipped"), RT("Notify", "notStarted"), log="Phase failed"),
])
st = az.release_stages(rel)
check("release stage status is mapped", st[0]["name"] == "Prod" and st[0]["status"] == "failed", st)
check("only the latest attempt is read", all(t["name"] != "old failure" for t in st[0]["tasks"]))
check("only tasks needing attention are kept", [t["name"] for t in st[0]["tasks"]] == ["Deploy to AKS"], st[0]["tasks"])
check("release task error message and duration", st[0]["tasks"][0]["messages"] == ["rollout timed out"]
      and st[0]["tasks"][0]["durationSec"] == 480)
check("phase error log is kept as a stage message", st[0]["messages"] == ["Phase failed"])
ok = az.release_stages(release("succeeded", [attempt(RT("Deploy", "failed"))]))
check("a succeeded stage carries no tasks", ok[0]["status"] == "success" and ok[0]["tasks"] == [])
check("unexpected shapes are skipped, never raise", az.release_stages(None) == [] and az.release_stages({"environments": "x"}) == []
      and az.release_stages({"environments": [None, 3, {"name": "A", "deploySteps": "x"},
                                              {"name": "B", "status": "failed", "deploySteps": [{"releaseDeployPhases": [1, {"deploymentJobs": [2, {"tasks": [3]}]}]}]}]})[1]["tasks"] == [])
budget = [3]
many = release("failed", [attempt(*[RT("t%d" % i, "failed") for i in range(30)])])
az.release_stages(many, budget); az.release_stages(many, budget)
check("one budget is shared by every release of a target", budget[0] == 0)
items = az._build_release_list([many | {"releaseDefinition": {"name": "R%d" % i}, "name": "r", "id": i + 1} for i in range(10)], "https://dev.azure.com/o", "p")
check("task budget limits the release data sent with each refresh",
      sum(len(s["tasks"]) for it in items for s in it["stages"]) <= az.RELEASE_TASK_BUDGET)
check("release and run ids are numbers", items[0]["releaseId"] == 1)

# ── GitHub jobs and annotations ───────────────────────────────────────────────
gh_jobs = {"jobs": [
    {"id": 11, "name": "python-tests", "status": "completed", "conclusion": "failure",
     "started_at": "2026-01-01T10:00:00Z", "completed_at": "2026-01-01T10:01:00Z",
     "steps": [{"name": "Set up", "status": "completed", "conclusion": "success"},
               {"name": "Run tests", "status": "completed", "conclusion": "failure",
                "started_at": "2026-01-01T10:00:05Z", "completed_at": "2026-01-01T10:00:57Z"}, "junk"]},
    {"id": 12, "name": "lint", "status": "in_progress", "conclusion": None, "steps": []},
    {"id": 13, "name": "docs", "status": "queued", "conclusion": None, "steps": None},
    {"id": 14, "name": "cancelled one", "status": "completed", "conclusion": "cancelled"},
    "junk"]}
pj = jd.parse_github_jobs(gh_jobs)
check("github job status mapping", [j["status"] for j in pj] == ["failed", "running", "pending", "cancelled"], pj)
check("github steps and durations", [t["status"] for t in pj[0]["tasks"]] == ["success", "failed"] and pj[0]["tasks"][1]["durationSec"] == 52)
check("github: junk payloads are empty", jd.parse_github_jobs(None) == [] and jd.parse_github_jobs({"jobs": 3}) == [])
check("annotations: only failures, cleaned", jd._annotation_messages([
    {"annotation_level": "failure", "message": "Process completed\nwith exit code 1.‮"},
    {"annotation_level": "warning", "message": "no"}, {"annotation_level": "failure", "message": ""}, "x"])
    == ["Process completed with exit code 1."])

# ── The command line, with the fake az and gh ────────────────────────────────
fake = Fake(fixtures=False)
fake.use_in_process()
az._AZ_PATH = fake.path("az")
gh._GH_PATH = fake.path("gh")
ORG = "https://dev.azure.com/o"

fake.write("timeline.json", json.dumps(timeline))
rc, out = run_main(["--azure-build", ORG, "proj", "42"])
check("azure build: jobs are returned", rc == 0 and out and out["ok"] and out["provider"] == "azure-devops"
      and [j["name"] for j in out["jobs"]] == ["Build", "Test", "Package", "Deploy"], (rc, out))
call = fake.calls()[-1]
check("azure build: the timeline is asked for that build only (read-only call)",
      call[:2] == ["devops", "invoke"] and "buildId=42" in call and "project=proj" in call and "timeline" in call, call)
fake.remove("timeline.json")
rc, out = run_main(["--azure-build", ORG, "proj", "42"])
check("azure build: a failing az gives a short error", rc == 1 and out and not out["ok"] and "TF401019" in out["error"], (rc, out))
fake.clear_calls()
for args, why in ((["--azure-build", "https://evil.example.com/o", "p", "1"], "organization"),
                  (["--azure-build", ORG, "p;rm -rf /", "1"], "project"),
                  (["--azure-build", ORG, "p", "1;ls"], "build id"),
                  (["--azure-build", ORG, "p", "0"], "zero build id"),
                  (["--azure-build", ORG, "p", "-1"], "negative build id")):
    rc, out = run_main(args)
    check("azure build: invalid %s is refused without running az" % why, rc != 0 and not (out or {}).get("ok"), (rc, out))
check("no az call was made for any refused request", fake.calls() == [])

fake.write("jobs.json", json.dumps(gh_jobs))
fake.write("annotations.json", json.dumps([{"annotation_level": "failure", "message": "AssertionError: expected 3, got 2"}]))
fake.clear_calls()
rc, out = run_main(["--github-run", "owner/repo", "99"])
check("github run: jobs and failure message", rc == 0 and out and out["ok"]
      and out["jobs"][0]["messages"] == ["AssertionError: expected 3, got 2"] and "_id" not in out["jobs"][0], (rc, out))
calls = fake.calls()
check("github run: jobs list, then annotations of the failed job only; both are GET requests",
      len(calls) == 2 and "repos/owner/repo/actions/runs/99/jobs?per_page=30" in calls[0][-1]
      and "repos/owner/repo/check-runs/11/annotations?per_page=10" in calls[1][-1]
      and not any(x in ("-X", "--method", "-f", "-F", "--field", "--input") for c in calls for x in c), calls)
fake.remove("annotations.json")
rc, out = run_main(["--github-run", "owner/repo", "99"])
check("github run: jobs are still shown when the annotations cannot be read", rc == 0 and out["ok"] and out["jobs"][0]["messages"] == [], (rc, out))
fake.remove("jobs.json")
rc, out = run_main(["--github-run", "owner/repo", "99"])
check("github run: a failing gh gives a short error", rc == 1 and not out["ok"] and "404" in out["error"], (rc, out))
fake.clear_calls()
for args in (["--github-run", "owner/repo/../../x", "1"], ["--github-run", "-flag/repo", "1"], ["--github-run", "o/r", "1/../../x"],
             ["--github-run", "o/r", "abc"], ["--github-run", "o/r", "0"]):
    rc, out = run_main(args)
    check("github run: %r is refused without running gh" % args[1:], rc != 0 and not (out or {}).get("ok"), (rc, out))
check("no gh call was made for any refused request", fake.calls() == [])

fake.write("jobs.json", json.dumps(gh_jobs))
fake.write("annotations.json", json.dumps([{"annotation_level": "failure", "message": "AssertionError: expected 3, got 2"}]))
fake.write("banner.txt", "A new release of gh is available: 2.1 -> 2.2\nhttps://github.com/cli/cli/releases\n")
rc, out = run_main(["--github-run", "owner/repo", "99"])
check("github run: a notice printed before the JSON does not break it", rc == 0 and out and out["ok"]
      and out["jobs"][0]["messages"] == ["AssertionError: expected 3, got 2"], (rc, out))
fake.write("banner.txt", "")
fake.write("jobs.json", "<html>not json</html>")
rc, out = run_main(["--github-run", "owner/repo", "99"])
check("github run: output that is not JSON gives a short description of it, not a bare message",
      rc == 1 and not out["ok"] and "starts with: <html>" in out["error"] and "bytes" in out["error"], (rc, out))
fake.write("jobs.json", "[1, 2]")
rc, out = run_main(["--github-run", "owner/repo", "99"])
check("github run: JSON of the wrong shape is refused", rc == 1 and not out["ok"], (rc, out))
fake.remove("banner.txt")
check("parser: stray text before the JSON", jd._parse_gh_json(b"note\n{\"jobs\": []}", dict) == {"jobs": []})
check("parser: empty output and wrong type", jd._parse_gh_json(b"", dict) is None and jd._parse_gh_json(b"[]", dict) is None)

big_jobs = {"jobs": [{"id": 100 + i, "name": "j%d" % i, "status": "completed", "conclusion": "failure", "steps": []} for i in range(30)]}
fake.write("jobs.json", json.dumps(big_jobs)); fake.write("annotations.json", "[]"); fake.clear_calls()
run_main(["--github-run", "owner/repo", "99"])
check("github run: at most %d failed jobs get an annotation lookup" % jd.MAX_FAILED_LOOKUPS, len(fake.calls()) == 1 + jd.MAX_FAILED_LOOKUPS, len(fake.calls()))

# ── Mock mode ─────────────────────────────────────────────────────────────────
rc, out = run_main(["--mock", "azure", "203"])
check("mock azure: failed run shows its error", rc == 0 and out["ok"] and any(m for j in out["jobs"] for t in j["tasks"] for m in t["messages"]), out)
rc, out = run_main(["--mock", "github", "1002"])
check("mock github: failed run shows its error", rc == 0 and out["ok"] and out["jobs"][0]["messages"], out)
rc, out = run_main(["--mock", "azure", "99999"])
check("mock: unknown id falls back to the default", rc == 0 and out["ok"] and out["jobs"], out)
rc, out = run_main(["--mock", "azure", "../x"])
check("mock: bad id is refused", rc != 0 and not out["ok"])
rc, out = run_main(["--mock", "other", "1"])
check("mock: bad kind is refused", rc != 0 and not out["ok"])

# the committed mock files carry the ids the panel needs
mock_az = json.loads((REPO / "mock" / "azure-devops.json").read_text())
mock_gh = json.loads((REPO / "mock" / "github-actions.json").read_text())
check("mock lists carry run ids", all(p["runId"] for t in mock_az["targets"] for p in t["pipelineList"])
      and all(p["runId"] for r in mock_gh["repos"] for p in r["pipelineList"]))

fake.cleanup()
finish()
