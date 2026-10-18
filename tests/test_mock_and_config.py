"""Mock mode of the three providers, and the hardened config.json reader / writer."""
import json, os, shutil, subprocess, sys, tempfile
from pathlib import Path
from support import *

# ── mock mode: valid JSON, expected shape ────────────────────────────────────
for script, key in (("azure_devops", "targets"), ("kubernetes", "clusters"), ("github_actions", "repos")):
    rc, j, out, err = run_script(script, ["--mock"])
    check(script + " --mock: exit 0, valid JSON with a status", rc == 0 and j and j.get("status") in ("healthy", "warning", "critical"), out[:120])
    check(script + " --mock: has '%s'" % key, j and isinstance(j.get(key), list) and len(j[key]) > 0)
    check(script + " --mock: output below 256 KB", len(out.encode()) <= 256 * 1024)

# ── config.json reader / writer, on a private copy of the scripts ────────────
tmp = Path(tempfile.mkdtemp(prefix="devops-monitor-config-"))
shutil.copytree(SCRIPTS, tmp / "scripts", ignore=shutil.ignore_patterns("__pycache__"))
cfg = tmp / "config.json"
BASE = {"providers": {"azureDevOps": True, "kubernetes": False, "github": False}, "myOwnKey": {"keep": [1, 2, 3]}}


def put(obj=BASE):
    if cfg.is_symlink() or cfg.exists():
        cfg.unlink()
    cfg.write_text(json.dumps(obj, indent=2))


def tool(name, *args):
    p = subprocess.run([sys.executable, str(tmp / "scripts" / name), *args], capture_output=True, text=True,
                       env={"HOME": str(tmp), "PATH": "/usr/bin:/bin"})
    return p.returncode, p.stdout, p.stderr


put()
rc, out, err = tool("read_config.py")
check("read_config prints the file", rc == 0 and json.loads(out) == BASE, err)
rc, out, err = tool("write_config.py", "kubernetes", "true")
now = json.loads(cfg.read_text())
check("write_config toggles one provider", rc == 0 and now["providers"]["kubernetes"] is True and now["providers"]["azureDevOps"] is True, err)
check("write_config keeps keys it does not know", now["myOwnKey"] == {"keep": [1, 2, 3]})
# notifications.enabled (master switch of the desktop alerts)
cfg.write_text(json.dumps({**BASE, "notifications": {"enabled": False, "providers": ["github"], "maxPerHour": 7}}, indent=2) + "\n")
rc, out, err = tool("write_config.py", "notifications", "true")
now = json.loads(cfg.read_text())
check("write_config turns notifications.enabled on and keeps the rest of the block",
      rc == 0 and now["notifications"] == {"enabled": True, "providers": ["github"], "maxPerHour": 7} and now["providers"] == BASE["providers"], err + str(now.get("notifications")))
rc, out, err = tool("write_config.py", "notifications", "false")
check("...and off again", rc == 0 and json.loads(cfg.read_text())["notifications"]["enabled"] is False, err)
cfg.write_text(json.dumps(BASE, indent=2) + "\n")
rc, out, err = tool("write_config.py", "notifications", "true")
now = json.loads(cfg.read_text())
check("a config without a notifications block gets {enabled: true} and nothing else changes",
      rc == 0 and now["notifications"] == {"enabled": True} and {k: v for k, v in now.items() if k != "notifications"} == BASE, err + str(now))
cfg.write_text(json.dumps({**BASE, "notifications": "yes"}))
before_bad = cfg.read_text()
rc, out, err = tool("write_config.py", "notifications", "true")
check("a notifications value that is not an object is refused and left alone", rc != 0 and cfg.read_text() == before_bad, err)
put()
rc, out, err = tool("write_config.py", "bogus", "true")
check("write_config rejects an unknown provider", rc != 0)
rc, out, err = tool("write_config.py", "github", "maybe")
check("write_config rejects a value other than true/false", rc != 0)
before = cfg.read_text()
real = tmp / "real.json"; real.write_text(before); cfg.unlink(); cfg.symlink_to(real)
rc, out, err = tool("write_config.py", "github", "true")
check("write_config refuses a symlink and writes nothing", rc != 0 and real.read_text() == before and "symlink" in err, err)
cfg.unlink(); cfg.write_text("{ not json")
rc, out, err = tool("write_config.py", "github", "true")
check("write_config refuses invalid JSON and leaves the file", rc != 0 and cfg.read_text() == "{ not json", err)
cfg.write_text(json.dumps({"x": "y" * (300 * 1024)}))
rc, out, err = tool("read_config.py")
check("read_config refuses a file above 256 KB", rc != 0 and out == "", err[:100])
shutil.rmtree(tmp, ignore_errors=True)
finish()
