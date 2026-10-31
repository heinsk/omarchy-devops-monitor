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
if a[:1] == ["api"]:
    # jobs.json answers .../jobs, annotations.json answers .../annotations (missing file = the call fails).
    import json
    endpoint = a[-1]
    with open(os.path.join(HERE, "calls.log"), "a") as log:
        log.write(json.dumps(a) + "\n")
    name = "jobs.json" if "/jobs" in endpoint else "annotations.json" if "/annotations" in endpoint else ""
    path = os.path.join(HERE, name) if name else ""
    if not path or not os.path.exists(path):
        sys.stderr.write("gh: Not Found (HTTP 404)\n")
        sys.exit(1)
    sys.stdout.write(open(path).read())
    sys.exit(0)
sys.stderr.write("fake gh: unsupported %r\n" % (a,))
sys.exit(1)
