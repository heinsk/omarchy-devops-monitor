"""
Shared helpers for the tests. Plain Python, no third-party packages:

    python3 tests/run_all.py            # every test
    python3 tests/test_notices.py       # one test file

Each test file prints PASS / FAIL lines and exits non-zero if anything failed.
"""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

TESTS = Path(__file__).resolve().parent
REPO = TESTS.parent
SCRIPTS = REPO / "scripts"
sys.path.insert(0, str(SCRIPTS))

FAILS: list[str] = []


def check(name, cond, info=""):
    print(("PASS " if cond else "FAIL ") + name, "" if cond else info)
    if not cond:
        FAILS.append(name)


def finish():
    print("FAILS:", FAILS)
    sys.exit(1 if FAILS else 0)


class Fake:
    """A temporary directory holding fake kubectl / az / gh and kubectl's fixtures."""

    def __init__(self, fixtures=True):
        self.dir = tempfile.mkdtemp(prefix="devops-monitor-test-")
        for name in ("kubectl", "az", "gh"):
            dest = Path(self.dir) / name
            # The provider scripts run the CLI with a minimal environment, so the
            # shebang must name the interpreter by absolute path (no `env python3`).
            body = (TESTS / ("fake_%s.py" % name)).read_text().split("\n", 1)[1]
            dest.write_text("#!" + sys.executable + "\n" + body)
            dest.chmod(dest.stat().st_mode | stat.S_IXUSR)
        (Path(self.dir) / "calls.log").write_text("")
        if fixtures:
            from k8s_fixtures import write_fixtures
            write_fixtures(self.dir)

    def path(self, name):
        return str(Path(self.dir) / name)

    def clear_calls(self):
        (Path(self.dir) / "calls.log").write_text("")

    def calls(self):
        return [json.loads(l) for l in (Path(self.dir) / "calls.log").read_text().splitlines() if l.strip()]

    def env(self, **extra):
        env = {"HOME": self.dir, "PATH": "/usr/bin:/bin:/usr/local/bin", "FAKEK_DIR": self.dir}
        env.update(extra)
        return env

    def write(self, name, text):
        (Path(self.dir) / name).write_text(text)

    def remove(self, name):
        p = Path(self.dir) / name
        if p.exists():
            p.unlink()

    def use_in_process(self):
        os.environ["FAKEK_DIR"] = self.dir
        os.environ["PATH"] = "/usr/bin:/bin:/usr/local/bin"

    def cleanup(self):
        shutil.rmtree(self.dir, ignore_errors=True)


def run_script(script, args=(), fake=None, tools=(), no_tools=False, env=None, timeout=180):
    """Run a provider script. tools: which fakes to wire in ("kubectl", "az", "gh").
    Returns (returncode, parsed_json_or_None, stdout, stderr)."""
    cmd = [sys.executable, str(TESTS / "run_script.py"), script]
    if no_tools:
        cmd.append("--no-tools")
    for t in tools:
        cmd += ["--" + t, fake.path(t)]
    cmd += ["--", *args]
    e = fake.env(**(env or {})) if fake else {"HOME": "/nonexistent", "PATH": "/usr/bin:/bin"}
    p = subprocess.run(cmd, capture_output=True, text=True, env=e, timeout=timeout)
    try:
        data = json.loads(p.stdout)
    except Exception:
        data = None
    return p.returncode, data, p.stdout, p.stderr
