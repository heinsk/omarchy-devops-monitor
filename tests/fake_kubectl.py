#!/usr/bin/env python3
"""
Stand-in for kubectl used by the tests. It never touches a real cluster.

Behaviour is driven by files that sit next to this script:
    nodes.json pods.json deployments.json   {"items": [...]} served by `get --raw`
    contexts                                one context name per line (default: production)
    current_context                         name printed by `config current-context`
    fail_nodes / fail_pods / fail_deployments   file content is printed to stderr, exit 1
    hog                                     MiB to allocate (to exercise the memory limit)
    slow                                    seconds to sleep before answering a request
    mode_big                                answer with ~20 MB of non-JSON
Every call is appended to calls.log as a JSON list of its arguments.
"""
import json
import os
import sys
import time
import urllib.parse

# The provider scripts run kubectl with a scrubbed environment, so the fixtures
# directory is the one this file was copied into, not an environment variable.
D = os.path.dirname(os.path.realpath(__file__))
args = sys.argv[1:]
with open(os.path.join(D, "calls.log"), "a") as log:
    log.write(json.dumps(args) + "\n")


def read(name, default=None):
    p = os.path.join(D, name)
    return open(p).read() if os.path.exists(p) else default


if args[:2] == ["version", "--client"]:
    print("Client Version: fake")
    sys.exit(0)

if args[:2] == ["config", "current-context"]:
    cur = read("current_context", "production").strip()
    if not cur:
        sys.stderr.write("error: current-context is not set\n")
        sys.exit(1)
    print(cur)
    sys.exit(0)

if args[:2] == ["config", "get-contexts"]:
    print(read("contexts", "production\n"), end="")
    sys.exit(0)

if args[:2] == ["get", "--raw"]:
    url = urllib.parse.urlparse(args[2])
    query = urllib.parse.parse_qs(url.query)
    parts = url.path.strip("/").split("/")
    res = parts[-1]
    ns = parts[parts.index("namespaces") + 1] if "namespaces" in parts else None
    if res not in ("nodes", "pods", "deployments"):
        sys.stderr.write("fake kubectl: unsupported path %s\n" % url.path)
        sys.exit(1)
    slow = read("slow")
    if slow:
        time.sleep(float(slow))
    hog = read("hog")
    if hog:
        _ballast = bytearray(int(hog) * 1024 * 1024)  # MemoryError under `ulimit -d`
    fail = read("fail_" + res)
    if fail is not None:
        sys.stderr.write(fail)
        sys.exit(1)
    if os.path.exists(os.path.join(D, "mode_big")):
        sys.stdout.write('{"items":[' + "x" * (20 * 1024 * 1024))
        sys.exit(0)
    items = json.load(open(os.path.join(D, res + ".json")))["items"]
    if ns is not None:
        items = [i for i in items if i.get("metadata", {}).get("namespace") == ns]
    start = int(query["continue"][0][1:]) if "continue" in query else 0
    limit = int(query["limit"][0]) if "limit" in query else len(items)
    page = items[start:start + limit]
    meta = {"continue": "t%d" % (start + limit)} if start + limit < len(items) else {}
    sys.stdout.write(json.dumps({"metadata": meta, "items": page}))
    sys.exit(0)

sys.stderr.write("fake kubectl: unsupported command %r\n" % (args,))
sys.exit(1)
