"""Where config.json lives (the person's config folder), the one-time migration, and the safety rules."""
import concurrent.futures, json, os, shutil, stat, subprocess, sys, tempfile
from pathlib import Path
from support import *

ID = "io.github.heinsk.devops-monitor"


class Sandbox:
    """A private copy of the scripts (so the 'old' config.json sits in a fake plugin folder) + a fake HOME."""

    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix="devops-monitor-store-"))
        shutil.copytree(SCRIPTS, self.root / "plugin" / "scripts", ignore=shutil.ignore_patterns("__pycache__"))
        self.plugin = self.root / "plugin"
        self.legacy = self.plugin / "config.json"
        self.home = self.root / "home"
        self.home.mkdir()
        self.xdg = self.root / "xdg"
        self.dir = self.xdg / ID
        self.file = self.dir / "config.json"

    def run(self, script, *args, xdg=True, env=None):
        e = {"HOME": str(self.home), "PATH": "/usr/bin:/bin"}
        if xdg:
            e["XDG_CONFIG_HOME"] = str(self.xdg)
        e.update(env or {})
        p = subprocess.run([sys.executable, str(self.plugin / "scripts" / script), *args], capture_output=True, text=True, env=e)
        return p.returncode, p.stdout, p.stderr

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)


def mode(p):
    return stat.S_IMODE(os.lstat(p).st_mode)


# ── migration ────────────────────────────────────────────────────────────────
sb = Sandbox()
LEGACY = '{\n  "providers": {"azureDevOps": true},\n\n  "myOwnKey": [1, 2]\n}\n'
sb.legacy.write_text(LEGACY)
os.utime(sb.legacy, (1_000_000_000, 1_000_000_000))
rc, out, err = sb.run("read_config.py")
check("first run copies the old config.json byte for byte", rc == 0 and out == LEGACY and sb.file.read_text() == LEGACY, err)
check("the new file is 0600 and its folder is 0700", mode(sb.file) == 0o600 and mode(sb.dir) == 0o700, (oct(mode(sb.file)), oct(mode(sb.dir))))
check("the old file is left exactly as it was (content and time)", sb.legacy.read_text() == LEGACY and int(sb.legacy.stat().st_mtime) == 1_000_000_000)
check("no temporary files are left behind", [p.name for p in sb.dir.iterdir()] == ["config.json"], [p.name for p in sb.dir.iterdir()])
sb.file.write_text('{"providers": {"github": true}}')
sb.legacy.write_text('{"providers": {"kubernetes": true}}')
rc, out, err = sb.run("read_config.py")
check("afterwards the old file is ignored", rc == 0 and json.loads(out) == {"providers": {"github": True}}, out)
rc, out, err = sb.run("write_config.py", "azureDevOps", "true")
check("toggles write the new file and not the old one", rc == 0 and json.loads(sb.file.read_text())["providers"]["azureDevOps"] is True
      and sb.legacy.read_text() == '{"providers": {"kubernetes": true}}', err)
sb.cleanup()

sb = Sandbox()
rc, out, err = sb.run("read_config.py")
check("with no old file, a minimal default with every provider off is created",
      rc == 0 and json.loads(out) == {"providers": {"azureDevOps": False, "kubernetes": False, "github": False}}, err + out)
sb.cleanup()

sb = Sandbox()
sb.legacy.write_text("{ not json")
rc, out, err = sb.run("read_config.py")
check("a damaged old file is not copied: clear reason, nothing created",
      rc != 0 and out == "" and "not valid JSON" in err and not sb.file.exists(), err)
sb.legacy.write_text(json.dumps({"x": "y" * (300 * 1024)}))
rc, out, err = sb.run("read_config.py")
check("an oversized old file is not copied", rc != 0 and not sb.file.exists() and "too large" in err, err[:120])
sb.legacy.unlink()
real = sb.root / "dotfiles.json"; real.write_text('{"providers": {"github": true}}')
sb.legacy.symlink_to(real)
rc, out, err = sb.run("read_config.py")
check("an old config.json that is a symlink to a regular file is copied as a regular file",
      rc == 0 and json.loads(out) == {"providers": {"github": True}} and not sb.file.is_symlink(), err)
sb.cleanup()

sb = Sandbox()
sb.legacy.write_text('{"a": 1}')
sb.dir.mkdir(parents=True, mode=0o700)
sb.file.write_text('{"b": 2}')
rc, out, err = sb.run("read_config.py")
check("an existing new file is never overwritten by the migration", rc == 0 and json.loads(out) == {"b": 2}, out)
sb.cleanup()

# ── location rules ───────────────────────────────────────────────────────────
sb = Sandbox()
rc, out, err = sb.run("read_config.py", "--path")
check("--path prints the file in $XDG_CONFIG_HOME and creates nothing", rc == 0 and out == str(sb.file) and not sb.xdg.exists(), out)
rc, out, err = sb.run("read_config.py", "--path", env={"XDG_CONFIG_HOME": "relative/dir"})
check("a relative $XDG_CONFIG_HOME is ignored (falls back to ~/.config)", out == str(sb.home / ".config" / ID / "config.json"), out)
rc, out, err = sb.run("read_config.py", "--path", xdg=False)
check("without $XDG_CONFIG_HOME the file is in ~/.config", out == str(sb.home / ".config" / ID / "config.json"), out)
sb.cleanup()

# ── safety ───────────────────────────────────────────────────────────────────
sb = Sandbox()
sb.legacy.write_text('{"providers": {}}')
sb.xdg.mkdir(); target = sb.root / "elsewhere"; target.mkdir(); (target / "config.json").write_text('{"x": 1}')
sb.dir.symlink_to(target)
rc, out, err = sb.run("read_config.py")
check("a config FOLDER that is a symlink is refused", rc != 0 and out == "" and "folder" in err, err)
rc, out, err = sb.run("write_config.py", "github", "true")
check("...also for writing, and the target is untouched", rc != 0 and (target / "config.json").read_text() == '{"x": 1}', err)
sb.cleanup()

sb = Sandbox()
sb.dir.mkdir(parents=True); os.chmod(sb.dir, 0o755)
sb.file.write_text('{"providers": {}}')
sb.run("read_config.py")
check("a folder that is too open is tightened to 0700", mode(sb.dir) == 0o700, oct(mode(sb.dir)))
real = sb.root / "real.json"; real.write_text('{"providers": {"github": false}}')
sb.file.unlink(); sb.file.symlink_to(real)
rc, out, err = sb.run("read_config.py")
check("a config.json that is a symlink to a regular file can still be READ", rc == 0 and json.loads(out) == {"providers": {"github": False}}, err)
rc, out, err = sb.run("write_config.py", "github", "true")
check("...but is never WRITTEN through", rc != 0 and "symlink" in err and real.read_text() == '{"providers": {"github": false}}', err)
rc, out, err = sb.run("config_edit.py", "apply", '{"github": {"repos": ["a/b"]}}')
check("...also by the settings editor", rc != 0 and real.read_text() == '{"providers": {"github": false}}', out + err)
sb.file.unlink(); os.mkfifo(sb.file)
rc, out, err = sb.run("read_config.py")
check("a FIFO in place of the file is refused without hanging", rc != 0 and "regular" in err, err)
sb.cleanup()

# ── two first runs at the same time ──────────────────────────────────────────
sb = Sandbox()
sb.legacy.write_text('{"providers": {"github": true}}\n')
with concurrent.futures.ThreadPoolExecutor(8) as ex:
    results = list(ex.map(lambda _: sb.run("read_config.py"), range(8)))
check("8 simultaneous first runs all succeed with the same content", all(r[0] == 0 and r[1] == '{"providers": {"github": true}}\n' for r in results), [r[2] for r in results if r[0]])
check("...and leave one file, no leftovers", sorted(p.name for p in sb.dir.iterdir()) == ["config.json"], [p.name for p in sb.dir.iterdir()])
sb.cleanup()
finish()
