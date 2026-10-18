"""state_store.py: the silence state is private, atomic, bounded, and never trusted on read."""
import json, os, shutil, stat, subprocess, sys, tempfile, time
from pathlib import Path
from support import *

tmp = Path(tempfile.mkdtemp(prefix="devops-monitor-state-"))
home = tmp / "home"; home.mkdir()
xdg = tmp / "xdg"
SD = xdg / "io.github.heinsk.devops-monitor"
ENV = {"HOME": str(home), "PATH": "/usr/bin:/bin", "XDG_STATE_HOME": str(xdg)}


def tool(*args, env=None):
    p = subprocess.run([sys.executable, str(SCRIPTS / "state_store.py"), *args], capture_output=True, text=True, env=env or ENV)
    return p.returncode, p.stdout, p.stderr


def mute():
    rc, out, err = tool("read")
    return json.loads(out)["mute"] if rc == 0 else None


now = int(time.time())
check("read with no state folder: nothing silenced, exit 0", tool("read")[0] == 0 and mute() == {})
check("read does not create anything", not SD.exists())
rc, _, err = tool("mute", "kubernetes", str(now + 3600)); check("mute an hour", rc == 0 and mute() == {"kubernetes": now + 3600}, err)
check("mute forever", tool("mute", "github", "forever")[0] == 0 and mute() == {"kubernetes": now + 3600, "github": -1})
check("clear one", tool("mute", "kubernetes", "clear")[0] == 0 and mute() == {"github": -1})
check("folder is 0700, file is 0600", stat.S_IMODE(SD.stat().st_mode) == 0o700 and stat.S_IMODE((SD / "state.json").stat().st_mode) == 0o600)
check("no temporary file is left behind", sorted(p.name for p in SD.iterdir()) == ["state.json", "state.lock"], str(list(SD.iterdir())))
check("file holds only the allow-listed data", json.loads((SD / "state.json").read_text()) == {"version": 1, "mute": {"github": -1}})
SD.chmod(0o755); tool("mute", "azureDevOps", "forever")
check("a folder that was too open is tightened", stat.S_IMODE(SD.stat().st_mode) == 0o700)

for label, args in (("unknown provider", ("mute", "bogus", "forever")), ("not a number", ("mute", "github", "soon")), ("zero", ("mute", "github", "0")),
                    ("negative", ("mute", "github", "-5")), ("absurd", ("mute", "github", str(2 ** 50))), ("missing args", ("mute", "github")), ("unknown command", ("wipe",))):
    rc, out, err = tool(*args); check("rejects " + label, rc != 0, "%s %s" % (rc, err))
check("rejected input changed nothing", mute() == {"github": -1, "azureDevOps": -1})

# expired entries disappear on read
(SD / "state.json").write_text(json.dumps({"version": 1, "mute": {"github": now - 10, "kubernetes": now + 600, "azureDevOps": True, "bogus": -1}}))
check("read drops expired, boolean and unknown entries", mute() == {"kubernetes": now + 600}, str(mute()))
# corrupt / hostile files are treated as empty, and the next write repairs them
for label, content in (("not json", "{nope"), ("a list", "[1,2]"), ("huge", json.dumps({"mute": {}, "pad": "x" * 40000})), ("binary", "\x00\x01\x02")):
    (SD / "state.json").write_text(content); check("read of a %s file => nothing silenced" % label, mute() == {})
(SD / "state.json").write_text("{nope"); tool("mute", "github", "forever")
check("a write repairs a corrupt file", mute() == {"github": -1})

# symlinks are never followed
real = tmp / "real.json"; real.write_text(json.dumps({"mute": {"github": -1}}))
(SD / "state.json").unlink(); (SD / "state.json").symlink_to(real)
check("a symlinked state file is ignored on read", mute() == {})
before = real.read_text(); rc, _, err = tool("mute", "kubernetes", "forever")
check("a symlinked state file is never written through", real.read_text() == before, err)
(SD / "state.json").unlink()
shutil.move(str(SD), str(tmp / "elsewhere")); SD.symlink_to(tmp / "elsewhere")
check("a symlinked state folder is ignored on read", mute() == {})
rc, _, err = tool("mute", "github", "forever")
check("a symlinked state folder is refused on write", rc != 0 and not (tmp / "elsewhere" / "state.json").exists(), err)
SD.unlink()

# XDG_STATE_HOME rules
env2 = dict(ENV, XDG_STATE_HOME="relative/path")
rc, _, err = tool("mute", "github", "forever", env=env2)
check("a relative XDG_STATE_HOME is ignored (falls back to ~/.local/state)", rc == 0 and (home / ".local/state/io.github.heinsk.devops-monitor/state.json").exists(), err)

# several writers at once never corrupt the file
shutil.rmtree(xdg, ignore_errors=True)
procs = [subprocess.Popen([sys.executable, str(SCRIPTS / "state_store.py"), "mute", p, "forever"], env=ENV) for p in ("azureDevOps", "kubernetes", "github") * 8]
check("24 concurrent writers all succeed", all(p.wait() == 0 for p in procs))
check("...and the result is complete and valid", mute() == {"azureDevOps": -1, "kubernetes": -1, "github": -1}, str(mute()))
shutil.rmtree(tmp, ignore_errors=True)
finish()
