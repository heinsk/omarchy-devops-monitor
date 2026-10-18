"""Text coming from the services is cleaned; the state file never leaves a half-written temporary file."""
import os
import tempfile
from pathlib import Path
from support import *          # also puts scripts/ on sys.path

import azure_devops as az
import state_store

HOSTILE = "a‮evil​.exe⁦x⁩\n\t\x85\x1b[31m"

runs = [{"pipeline": {"name": HOSTILE, "id": 1}, "status": "completed", "result": "failed",
         "sourceBranch": "refs/heads/main", "startTime": "2026-01-01T10:00:00Z", "finishTime": "2026-01-01T10:05:00Z"}]
items = az._build_pipeline_list(runs, "https://dev.azure.com/o", "p")
name = items[0]["name"]
check("pipeline name: no control, zero-width or bidi characters survive",
      name == "aevil.exex[31m" and all(ch.isprintable() for ch in name), repr(name))
check("pipeline name is bounded", len(az._build_pipeline_list(
    [{"pipeline": {"name": "n" * 5000, "id": 1}, "status": "completed", "result": "succeeded"}], "o", "p")[0]["name"]) == 200)
check("an empty or non-text name becomes 'Unknown'", az._build_pipeline_list(
    [{"pipeline": {"name": "‮", "id": 1}, "status": "completed", "result": "succeeded"}], "o", "p")[0]["name"] == "Unknown")

rels = [{"releaseDefinition": {"name": HOSTILE}, "name": "Release-‮1", "status": "active",
         "environments": [], "createdOn": "2026-01-01T10:00:00Z", "modifiedOn": "2026-01-01T10:05:00Z"}]
try:
    r = az._build_release_list(rels, "https://dev.azure.com/o", "p")
    check("release name and release label are cleaned too",
          bool(r) and all(ch.isprintable() for ch in r[0]["name"] + r[0]["releaseName"]) and r[0]["releaseName"] == "Release-1", repr(r))
except Exception as exc:
    check("release list builds with hostile text", False, repr(exc))

# Azure DevOps links: the real host must be an Azure DevOps host
GOOD = ["https://dev.azure.com/o/p/_build?definitionId=1", "https://vsrm.dev.azure.com/o/p", "https://contoso.visualstudio.com/p",
        "https://dev.azure.com:8443/o", "https://dev.azure.com#@evil.com"]
BAD = ["https://dev.azure.com:443@evil.com/x", "https://dev.azure.com@evil.com/", "https://user@dev.azure.com/o",
       "https://evil.com\\@dev.azure.com/", "https://dev.azure.com.evil.com/", "http://dev.azure.com/o",
       "https://dev.azure.com/o\n/x", "https://dev.azure.com/o /x", "https://evil.example1/x", "javascript:alert(1)", ""]
for u in GOOD:
    check("azure link accepted: %r" % u, az._validate_azure_url(u) == u)
for u in BAD:
    check("azure link refused: %r" % u, az._validate_azure_url(u) == "")

# state_store: a failing rename leaves no temporary file
tmp = Path(tempfile.mkdtemp(prefix="devops-monitor-hard-"))
os.environ["XDG_STATE_HOME"] = str(tmp)
real_rename = os.rename
def boom(*a, **k):
    raise OSError(28, "No space left on device")
os.rename = boom
try:
    try:
        state_store.write_mute("github", "forever")
        check("a failing write is reported", False)
    except OSError:
        check("a failing write is reported", True)
finally:
    os.rename = real_rename
left = sorted(p.name for p in (tmp / state_store.PLUGIN_ID).iterdir())
check("...and leaves no temporary file behind", left == ["state.lock"], str(left))
finish()
