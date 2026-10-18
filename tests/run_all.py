#!/usr/bin/env python3
"""Runs every tests/test_*.py in its own process and reports the result. Exit 0 = all passed."""
import subprocess
import sys
from pathlib import Path

here = Path(__file__).resolve().parent
failed = []
for test in sorted(here.glob("test_*.py")):
    print("\n=== %s ===" % test.name, flush=True)
    rc = subprocess.run([sys.executable, str(test)]).returncode
    if rc != 0:
        failed.append(test.name)
print("\n" + ("ALL TESTS PASSED" if not failed else "FAILED: " + ", ".join(failed)))
sys.exit(1 if failed else 0)
