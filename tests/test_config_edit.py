"""Editing the settings from the panel: validation, preview (writes nothing), apply (one write + .bak)."""
import json, os, shutil, stat, subprocess, sys, tempfile
from pathlib import Path
from support import *

ID = "io.github.heinsk.devops-monitor"
root = Path(tempfile.mkdtemp(prefix="devops-monitor-edit-"))
xdg = root / "xdg"; home = root / "home"; home.mkdir()
cdir = xdg / ID; cfg = cdir / "config.json"; bak = cdir / "config.json.bak"
ENV = {"HOME": str(home), "XDG_CONFIG_HOME": str(xdg), "PATH": "/usr/bin:/bin"}

BASE = {
    "providers": {"azureDevOps": True, "kubernetes": True, "github": True},
    "refresh": {"github": 45},
    "azureDevOps": {"top": 50, "targets": [{"organization": "https://dev.azure.com/old", "project": "old-project"}]},
    "kubernetes": {"contexts": [], "allContexts": False, "namespaces": [], "excludeNamespaces": []},
    "github": {"repos": ["my-org/old"]},
    "notifications": {"enabled": True, "branches": ["main"]},
    "myOwnKey": {"keep": [1, 2, 3]},
}


def put(obj=BASE, text=None):
    cdir.mkdir(parents=True, exist_ok=True, mode=0o700)
    for p in (cfg, bak):
        if p.is_symlink() or p.exists():
            p.unlink()
    cfg.write_text(text if text is not None else json.dumps(obj, indent=2) + "\n")
    os.chmod(cfg, 0o600)


def edit(cmd, changes):
    arg = changes if isinstance(changes, str) else json.dumps(changes)
    p = subprocess.run([sys.executable, str(SCRIPTS / "config_edit.py"), cmd, arg], capture_output=True, text=True, env=ENV)
    try:
        return p.returncode, json.loads(p.stdout)
    except ValueError:
        return p.returncode, {"raw": p.stdout, "err": p.stderr}


def errs(changes):
    rc, j = edit("preview", changes)
    return {e["field"]: e["message"] for e in j.get("errors", [])} if rc != 0 else {}


# ── validation (same rules as the provider scripts) ──────────────────────────
put()
e = errs({"azureDevOps": {"targets": [{"organization": "dev.azure.com/x", "project": "p"}]}})
check("an organization that is not an https Azure DevOps URL is refused", "azureDevOps.targets.0.organization" in e, e)
e = errs({"azureDevOps": {"targets": [{"organization": "https://dev.azure.com:443@evil.example/", "project": "p"}]}})
check("a link with user information (\"@evil\") is refused", "azureDevOps.targets.0.organization" in e, e)
e = errs({"azureDevOps": {"targets": [{"organization": "https://dev.azure.com/x", "project": ""}]}})
check("an empty project is refused (Required)", e.get("azureDevOps.targets.0.project") == "Required", e)
e = errs({"azureDevOps": {"targets": [{"organization": "https://dev.azure.com/x", "project": "a/b"}]}})
check("a project with a slash is refused", "azureDevOps.targets.0.project" in e, e)
t = {"organization": "https://dev.azure.com/x", "project": "P"}
e = errs({"azureDevOps": {"targets": [t, {"organization": "https://dev.azure.com/x/", "project": "p"}]}})
check("the same target twice (any case, trailing slash) is refused", "azureDevOps.targets.1" in e, e)
e = errs({"azureDevOps": {"targets": [dict(t, extra="x")]}})
check("a target with unknown keys is refused", "azureDevOps.targets.0" in e, e)
e = errs({"azureDevOps": {"targets": [dict(t, project="p%d" % i) for i in range(21)]}})
check("more than 20 targets are refused", "azureDevOps.targets" in e, e)
e = errs({"github": {"repos": ["my-org/web-app", "my-org", "-bad/x", "a/..", "a/b c"]}})
check("repositories must be owner/repo (and not '..')", set(e) == {"github.repos.1", "github.repos.2", "github.repos.3", "github.repos.4"}, e)
e = errs({"github": {"repos": ["My-Org/Api", "my-org/api"]}})
check("a repository twice (any case) is refused", "github.repos.1" in e, e)
e = errs({"github": {"repos": ["o/r%d" % i for i in range(21)]}})
check("more than 20 repositories are refused", "github.repos" in e, e)
e = errs({"kubernetes": {"contexts": ["ok-ctx", "has space", "$(rm)", "-flag"]}})
check("context names: spaces, shell characters and a leading dash are refused", set(e) == {"kubernetes.contexts.1", "kubernetes.contexts.2", "kubernetes.contexts.3"}, e)
e = errs({"kubernetes": {"contexts": ["arn:aws:eks:us-east-1:123456789012:cluster/prod", "admin@kubernetes", "gke_proj_zone_name"]}})
check("real-world context names (EKS arn, kubeadm user@cluster, GKE) are accepted", e == {}, e)
e = errs({"kubernetes": {"namespaces": ["payments", "Bad_Name", "-x"], "excludeNamespaces": ["a" * 64]}})
check("namespaces must be DNS-1123 labels (max 63)", set(e) == {"kubernetes.namespaces.1", "kubernetes.namespaces.2", "kubernetes.excludeNamespaces.0"}, e)
e = errs({"kubernetes": {"allContexts": "yes"}})
check("allContexts must be true or false", "kubernetes.allContexts" in e, e)
e = errs({"development": {"mockData": "yes"}})
check("development.mockData must be true or false", "development.mockData" in e, e)
e = errs({"development": {"mockError": {"github": "generic"}}})
check("other development keys (mockError) are not editable", "development.mockError" in e, e)
e = errs({"development": {"mockData": True}})
check("development.mockData true is accepted", e == {}, e)
e = errs({"refresh": {"github": 5}})
check("settings that are not editable here (refresh) are refused", "refresh" in e, e)
e = errs({"kubernetes": {"contexts": [], "namespace": ["x"]}})
check("unknown keys inside an editable section are refused", "kubernetes.namespace" in e, e)
e = errs({"providers": {"github": False}})
check("the provider switches cannot be changed through this command", "providers" in e, e)
rc, j = edit("preview", "[1, 2]")
check("changes that are not an object are refused", rc != 0 and not j["ok"], j)
rc, j = edit("preview", "{ nope")
check("changes that are not JSON are refused", rc != 0 and not j["ok"] and "not valid JSON" in j.get("error", ""), j)
rc, j = edit("preview", json.dumps({"github": {"repos": ["a/" + "b" * 17000]}}))
check("a changes argument above 16 KB is refused", rc != 0 and "too large" in j.get("error", ""), str(j)[:100])

# ── preview writes nothing ───────────────────────────────────────────────────
put()
before = cfg.read_bytes(); mt = cfg.stat().st_mtime_ns
rc, j = edit("preview", {"github": {"repos": ["my-org/web-app", "my-org/api"]}})
check("preview: ok, changed, with a diff that adds both repositories and removes the old one",
      rc == 0 and j["ok"] and j["changed"] and any(l["t"] == "-" and "my-org/old" in l["s"] for l in j["diff"])
      and sum(1 for l in j["diff"] if l["t"] == "+" and "my-org/" in l["s"]) == 2, j)
check("preview: the file and its time are untouched and no .bak exists", cfg.read_bytes() == before and cfg.stat().st_mtime_ns == mt and not bak.exists())
rc, j = edit("preview", {"github": {"repos": ["my-org/old"]}})
check("preview of the same values: changed is false and the diff is empty", rc == 0 and j["ok"] and not j["changed"] and j["diff"] == [], j)

# ── apply ────────────────────────────────────────────────────────────────────
put()
before = cfg.read_text()
CH = {"azureDevOps": {"targets": [{"organization": "https://dev.azure.com/new", "project": "mobile"}]},
      "github": {"repos": ["my-org/web-app", "my-org/api"]},
      "kubernetes": {"contexts": ["production", "staging"], "namespaces": ["payments"], "excludeNamespaces": ["kube-system"]}}
rc, j = edit("apply", CH)
now = json.loads(cfg.read_text())
check("apply: writes exactly what was asked", rc == 0 and j == {"ok": True, "changed": True}
      and now["azureDevOps"]["targets"] == CH["azureDevOps"]["targets"] and now["github"]["repos"] == CH["github"]["repos"]
      and now["kubernetes"]["contexts"] == ["production", "staging"] and now["kubernetes"]["namespaces"] == ["payments"], (j, now))
check("apply: keys it does not edit are kept as they were (top, refresh, notifications, your own keys, allContexts)",
      now["azureDevOps"]["top"] == 50 and now["refresh"] == {"github": 45} and now["notifications"] == BASE["notifications"]
      and now["myOwnKey"] == BASE["myOwnKey"] and now["providers"] == BASE["providers"] and now["kubernetes"]["allContexts"] is False, now)
check("apply: the key order of the file is kept", list(now) == list(BASE), list(now))
check("apply: config.json.bak holds the previous content", bak.read_text() == before)
check("apply: the file stays 0600 and no temporary file is left", stat.S_IMODE(cfg.stat().st_mode) == 0o600 and sorted(p.name for p in cdir.iterdir()) == ["config.json", "config.json.bak"], sorted(p.name for p in cdir.iterdir()))
bak_before = bak.read_text()
rc, j = edit("apply", CH)
check("applying the same values again writes nothing (no new .bak)", rc == 0 and j == {"ok": True, "changed": False} and bak.read_text() == bak_before, j)

put(text='{\n  "github": {\n      "repos": ["a/b"]\n  },\n\n  "x": 1\n}\n')
mt = cfg.stat().st_mtime_ns
rc, j = edit("apply", {"github": {"repos": ["a/b"]}})
check("a hand-formatted file with nothing to change is not rewritten", rc == 0 and not j["changed"] and cfg.stat().st_mtime_ns == mt and not bak.exists(), j)
rc, j = edit("preview", {"github": {"repos": ["a/b", "c/d"]}})
check("preview says the file will be reformatted when it is hand-formatted", j["ok"] and j["reformat"] is True, j)

put({"x": 1})
rc, j = edit("apply", {"kubernetes": {"contexts": [], "allContexts": False, "namespaces": [], "excludeNamespaces": []}})
check("empty defaults are not added to a config that never had those keys", rc == 0 and not j["changed"] and json.loads(cfg.read_text()) == {"x": 1}, j)
rc, j = edit("apply", {"github": {"repos": ["a/b"]}})
check("a section that did not exist is created", rc == 0 and json.loads(cfg.read_text()) == {"x": 1, "github": {"repos": ["a/b"]}}, j)

put({"x": 1, "development": {"mockData": False, "mockError": {"github": "generic"}}})
rc, j = edit("apply", {"development": {"mockData": True}})
now = json.loads(cfg.read_text())
check("apply turns mockData on and keeps development.mockError", rc == 0 and j["changed"] and now["development"] == {"mockData": True, "mockError": {"github": "generic"}}, now)
put({"x": 1})
rc, j = edit("apply", {"development": {"mockData": False}})
check("mockData false is not added to a config that never had it", rc == 0 and not j["changed"] and json.loads(cfg.read_text()) == {"x": 1}, j)
rc, j = edit("apply", {"development": {"mockData": True}})
check("mockData true creates the development section", rc == 0 and json.loads(cfg.read_text()) == {"x": 1, "development": {"mockData": True}}, j)

# ── refusals leave everything alone ──────────────────────────────────────────
for label, text in (("invalid JSON", "{ not json"), ("a root that is not an object", "[1, 2]"), ("a section that is not an object", '{"github": "x"}')):
    put(text=text)
    rc, j = edit("apply", {"github": {"repos": ["a/b"]}})
    check("apply refuses %s and leaves the file and creates no .bak" % label, rc != 0 and not j["ok"] and cfg.read_text() == text and not bak.exists(), j)
put(); real = root / "real.json"; real.write_text("{}"); cfg.unlink(); cfg.symlink_to(real)
rc, j = edit("apply", {"github": {"repos": ["a/b"]}})
check("apply refuses a symlinked config.json", rc != 0 and "symlink" in j.get("error", "") and real.read_text() == "{}" and not bak.exists(), j)
put()
rc, j = edit("apply", {"github": {"repos": ["not valid"]}})
check("apply validates again: nothing is written when a value is invalid", rc != 0 and cfg.read_text() == json.dumps(BASE, indent=2) + "\n" and not bak.exists(), j)

# ── kubectl contexts (read-only) ─────────────────────────────────────────────
fake = Fake()
fake.write("contexts", "production\nstaging\nhas space\nminikube\n")
fake.write("current_context", "staging")
code = ("import sys; sys.path.insert(0, %r); import config_edit; config_edit.k8s._KUBECTL_PATH = %r; "
        "sys.exit(config_edit.main(['config_edit.py', 'contexts']))") % (str(SCRIPTS), fake.path("kubectl"))
p = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, env=fake.env(**ENV))
j = json.loads(p.stdout)
check("contexts: lists the kubectl contexts and the current one, dropping unusable names",
      p.returncode == 0 and j["ok"] and j["contexts"] == ["production", "staging", "minikube"] and j["current"] == "staging", p.stdout + p.stderr)
code2 = code.replace("config_edit.k8s._KUBECTL_PATH = %r" % fake.path("kubectl"), "config_edit.k8s._find_kubectl = lambda: None")
p = subprocess.run([sys.executable, "-c", code2], capture_output=True, text=True, env=fake.env(**ENV))
j = json.loads(p.stdout)
check("contexts: without kubectl it says so", p.returncode != 0 and not j["ok"] and "kubectl" in j["error"], p.stdout + p.stderr)
fake.cleanup()
shutil.rmtree(root, ignore_errors=True)
finish()
