"""Provider notices: what the panel shows when a CLI is missing, not signed in, or nothing is configured."""
import json, re, sys
from support import *
import provider_notice as pn

FORBIDDEN = re.compile(r"sudo|pacman|yay\b|apt(-get)?\b|brew\b|dnf\b|curl|wget|\|\s*sh", re.I)


def valid(n, who):
    """A notice must be plain, bounded, well-formed and must not suggest installing software with a command."""
    ok = isinstance(n, dict) and n.get("kind") in pn.KINDS and 0 < len(n.get("title", "")) <= pn.MAX_TITLE
    ok = ok and len(n.get("message", "")) <= pn.MAX_MESSAGE and len(n.get("footer", "")) <= pn.MAX_FOOTER
    steps = n.get("steps", []) if isinstance(n, dict) else []
    ok = ok and len(steps) <= pn.MAX_STEPS
    ok = ok and all(0 < len(s["command"]) <= pn.MAX_COMMAND and len(s["label"]) <= pn.MAX_LABEL for s in steps)
    text = json.dumps(n)
    ok = ok and not re.search(r"[\x00-\x1f\x7f]", json.dumps(n, ensure_ascii=False).replace("\\n", "")) and not FORBIDDEN.search(text)
    check(who + ": notice is well-formed, bounded, no install commands", ok, text[:300])


# ── the helper module ────────────────────────────────────────────────────────
n = pn.make_notice("setup", "T\x1b[31m" + "x" * 500, "m\n\nm", [("l" * 200, "cmd\nsecond")] * 9, "f" * 999)
check("make_notice: bounded and single-line", len(n["title"]) <= pn.MAX_TITLE and "\n" not in n["message"] and len(n["steps"]) == pn.MAX_STEPS
      and "\n" not in n["steps"][0]["command"] and len(n["steps"][0]["label"]) <= pn.MAX_LABEL and len(n["footer"]) <= pn.MAX_FOOTER, str(n)[:200])
check("make_notice: unknown kind becomes error", pn.make_notice("<b>", "t")["kind"] == "error")
check("make_notice: empty commands are dropped", "steps" not in pn.make_notice("setup", "t", steps=[("a", ""), ("b", "  ")]))
for bad in ("a;b", "-x", "$(x)", "a b", "a\nb", "'q", 'q"', "a`b`", "a|b", "a&b", "a>b", "", "x" * 129, None, 5):
    check("is_safe_name rejects %r" % (bad,), not pn.is_safe_name(bad))
for good in ("production", "k3d-demo-cluster", "arn:aws:eks:us-east-1:123:cluster/x", "user@cluster.example.com", "gke_proj_zone_name"):
    check("is_safe_name accepts %r" % good, pn.is_safe_name(good))

# ── dev aid: --mock-error ────────────────────────────────────────────────────
for script in ("azure_devops", "kubernetes", "github_actions"):
    for mode, kind_title in (("missing-dependency", None), ("generic", None)):
        rc, j, out, err = run_script(script, ["--mock", "--mock-error", mode])
        check("%s --mock-error %s: offline with a notice" % (script, mode), j and j["status"] == "offline" and "notice" in j, out[:200])
        if j and "notice" in j:
            valid(j["notice"], "%s %s" % (script, mode))
    rc, j, out, err = run_script(script, ["--mock", "--mock-error", "missing-dependency"])
    check(script + ": missing dependency keeps errorCode/dependency for the plain fallback", j.get("errorCode") == "missing_dependency" and j.get("dependency"), str(j)[:200])

# ── Azure DevOps, real flow with fake az ─────────────────────────────────────
f = Fake(fixtures=False)
rc, j, out, err = run_script("azure_devops", [], fake=f, tools=(), no_tools=True)
check("azure: az not installed", rc == 1 and j["notice"]["title"] == "Azure CLI is not installed" and j["notice"]["kind"] == "setup", out[:200]); valid(j["notice"], "azure no az")
f.write("no_extension", "1")
rc, j, out, err = run_script("azure_devops", [], fake=f, tools=("az",))
f.remove("no_extension")
check("azure: extension missing", j["notice"]["title"] == "Azure DevOps extension is not installed" and j["notice"]["steps"][0]["command"] == "az extension add --name azure-devops", out[:200]); valid(j["notice"], "azure no ext")
f.write("no_login", "1")
rc, j, out, err = run_script("azure_devops", [], fake=f, tools=("az",))
f.remove("no_login")
check("azure: not signed in (device-code variant offered)", j["notice"]["title"] == "Not signed in to Azure" and [s["command"] for s in j["notice"]["steps"]] == ["az login", "az login --use-device-code"], out[:200]); valid(j["notice"], "azure no login")
rc, j, out, err = run_script("azure_devops", [], fake=f, tools=("az",))
check("azure: nothing configured => empty notice", j["notice"]["kind"] == "empty" and j["errorCode"] == "not_configured" and j["notice"]["footer"] == "Open config.json in terminal", out[:200]); valid(j["notice"], "azure empty")

# ── GitHub Actions, real flow with fake gh ───────────────────────────────────
rc, j, out, err = run_script("github_actions", ["--repo=a/b"], fake=f, tools=(), no_tools=True)
check("github: gh not installed", j["notice"]["title"] == "GitHub CLI is not installed" and j["errorCode"] == "missing_dependency", out[:200]); valid(j["notice"], "github no gh")
f.write("no_login", "1")
rc, j, out, err = run_script("github_actions", ["--repo=a/b"], fake=f, tools=("gh",))
f.remove("no_login")
check("github: not signed in", j["notice"]["title"] == "Not signed in to GitHub" and j["notice"]["steps"][0]["command"] == "gh auth login", out[:200]); valid(j["notice"], "github no login")
rc, j, out, err = run_script("github_actions", [], fake=f, tools=("gh",))
check("github: no repositories => empty notice", j["notice"]["kind"] == "empty" and j["errorCode"] == "not_configured", out[:200]); valid(j["notice"], "github empty")

# ── Kubernetes, real flow with fake kubectl ──────────────────────────────────
rc, j, out, err = run_script("kubernetes", [], fake=f, tools=(), no_tools=True)
check("kubernetes: kubectl not installed", j["notice"]["title"] == "kubectl is not installed", out[:200]); valid(j["notice"], "k8s no kubectl")
f2 = Fake(); f2.write("current_context", "")
rc, j, out, err = run_script("kubernetes", [], fake=f2, tools=("kubectl",))
check("kubernetes: no active context", j["errorCode"] == "no_context" and j["notice"]["title"] == "No active Kubernetes context", out[:200]); valid(j["notice"], "k8s no context")

KLOG = ('E1010 16:15:46.704532  153689 memcache.go:265] "Unhandled Error" err="couldn\'t get current server API group list: Get '
        '\\"https://0.0.0.0:41131/api?timeout=32s\\": dial tcp 0.0.0.0:41131: connect: connection refused"\n')
for res in ("nodes", "pods", "deployments"):
    f2.write("fail_" + res, KLOG)
rc, j, out, err = run_script("kubernetes", ["--context=k3d-demo-cluster"], fake=f2, tools=("kubectl",))
c = j["clusters"][0]
check("kubernetes: unreachable cluster carries a notice", c["status"] == "offline" and c["notice"]["kind"] == "error" and c["notice"]["title"] == "Cannot reach k3d-demo-cluster", str(c)[:300])
cmds = [s["command"] for s in c["notice"]["steps"]]
check("kubernetes: unreachable => check + k3d start, with the real context name", cmds == ["kubectl get nodes --context k3d-demo-cluster", "k3d cluster start demo-cluster"], str(cmds))
check("kubernetes: the host from the error is in the message", "0.0.0.0:41131" in c["notice"]["message"], c["notice"]["message"]); valid(c["notice"], "k8s unreachable")
rc, j, out, err = run_script("kubernetes", ["--context=minikube"], fake=f2, tools=("kubectl",))
check("kubernetes: minikube context => minikube start", [s["command"] for s in j["clusters"][0]["notice"]["steps"]] == ["kubectl get nodes --context minikube", "minikube start"])
odd = "we$(touch x)ird;ctx"
rc, j, out, err = run_script("kubernetes", ["--context=" + odd], fake=f2, tools=("kubectl",))
c = j["clusters"][0]
check("kubernetes: an unsafe context name never appears in a command", c["notice"]["steps"] == [] if "steps" in c["notice"] else True and odd not in json.dumps(c["notice"]["steps"] if "steps" in c["notice"] else []), str(c["notice"]))
check("kubernetes: the plain warning is still there for older panels", c["warnings"] and c["warnings"][0].startswith("Cannot reach the cluster API server"))
for res in ("nodes", "pods", "deployments"):
    f2.remove("fail_" + res)
rc, j, out, err = run_script("kubernetes", ["--context=production"], fake=f2, tools=("kubectl",))
check("kubernetes: healthy fixture has no notice", "notice" not in j["clusters"][0] and "notice" not in j)
f.cleanup(); f2.cleanup()
finish()
