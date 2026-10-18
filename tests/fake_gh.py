#!/usr/bin/env python3
"""Stand-in for the GitHub CLI. A file called `no_login` next to this script = no session."""
import os
import sys

HERE = os.path.dirname(os.path.realpath(__file__))

a = sys.argv[1:]
logged = not os.path.exists(os.path.join(HERE, "no_login"))
if a[:2] == ["auth", "status"]:
    sys.exit(0 if logged else 1)
if a[:2] == ["run", "list"]:
    if not logged:
        sys.stderr.write("To get started with GitHub CLI, please run:  gh auth login\n")
        sys.exit(1)
    print("[]")
    sys.exit(0)
sys.stderr.write("fake gh: unsupported %r\n" % (a,))
sys.exit(1)
