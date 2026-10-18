#!/usr/bin/env python3
"""Stand-in for the Azure CLI. Files next to this script: `no_extension` (extension missing), `no_login` (no session)."""
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
sys.stderr.write("fake az: unsupported %r\n" % (a,))
sys.exit(1)
