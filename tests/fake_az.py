#!/usr/bin/env python3
"""Stand-in for the Azure CLI. Files next to this script: `no_extension` (extension missing), `no_login` (no session)."""
import json
import os
import sys

HERE = os.path.dirname(os.path.realpath(__file__))

a = sys.argv[1:]
if a[:1] == ["--version"]:
    print("azure-cli fake")
    sys.exit(0)
if a[:2] == ["extension", "show"]:
    sys.exit(1 if os.path.exists(os.path.join(HERE, "no_extension")) else 0)
if a[:2] == ["account", "show"]:
    sys.exit(1 if os.path.exists(os.path.join(HERE, "no_login")) else 0)
if a[:2] == ["devops", "invoke"]:
    # Build timeline: the content of timeline.json next to this script (none = the call fails).
    with open(os.path.join(HERE, "calls.log"), "a") as log:
        log.write(json.dumps(a) + "\n")
    path = os.path.join(HERE, "timeline.json")
    if not os.path.exists(path):
        sys.stderr.write("ERROR: TF401019: The build does not exist\n")
        sys.exit(1)
    sys.stdout.write(open(path).read())
    sys.exit(0)
sys.stderr.write("fake az: unsupported %r\n" % (a,))
sys.exit(1)
