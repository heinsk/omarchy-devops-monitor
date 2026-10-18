"""Kubernetes script: kubectl failures become one readable message, never raw klog dumps."""
import json, os, sys
from support import *
fake = Fake(); D = fake.dir
def run(*a):
    return run_script("kubernetes", a, fake=fake, tools=("kubectl",))[1]["clusters"][0]
KLOG="".join('E1010 16:15:46.%06d  1536%02d memcache.go:265] "Unhandled Error" err="couldn\'t get current server API group list: Get \\"https://0.0.0.0:41131/api?timeout=32s\\": dial tcp 0.0.0.0:41131: connect: connection refused"\n'%(704532+i*76000,89+i) for i in range(4))+"The connection to the server 0.0.0.0:41131 was refused - did you specify the right host or port?\n"
def fail(res,text):
    open(D+"/fail_"+res,"w").write(text)
def clear():
    for r in ("nodes","pods","deployments"):
        fake.remove("fail_"+r)
try:
    for r in ("nodes","pods","deployments"): fail(r,KLOG)
    c=run()
    check("unreachable cluster: offline", c["status"]=="offline", c["status"])
    check("unreachable cluster: ONE readable warning, not 3 klog dumps", c["warnings"]==["Cannot reach the cluster API server (0.0.0.0:41131) — is the cluster running?"], str(c.get("warnings")))
    check("offline cluster shows no fake 0/0 counters", c["nodes"]=={} and c["pods"]=={} and c["deployments"]=={}, str((c["nodes"],c["pods"])))
    clear()
    for r in ("nodes","pods","deployments"): fail(r,'error: You must be logged in to the server (Unauthorized)\n')
    c=run(); check("unauthorized => credentials message (single)", c["warnings"]==["The cluster rejected the credentials — log in again (kubectl or your cloud CLI)"], str(c.get("warnings")))
    clear()
    fail("pods",KLOG); c=run()
    check("only pods unreachable: warning (not offline), one message", c["status"]=="warning" and len(c["warnings"])==1 and c["nodes"]["total"]==3, str(c))
    clear()
    long='E1010 16:15:46.704532  153689 cache.go:12] something odd happened with a very long explanation '+"word "*80
    for r in ("nodes","pods","deployments"): fail(r,long)
    c=run(); w=c["warnings"][0]
    check("unknown error: klog prefix removed, cut at a word boundary with an ellipsis, bounded", w.startswith("something odd") and w.endswith("…") and len(w)<=161 and not w[:-1].endswith("wor"), w)
    clear()
    fail("pods",'Error from server (Forbidden): pods is forbidden: User "x" cannot list resource "pods" in API group "" at the cluster scope\n'); c=run()
    check("forbidden keeps its meaning", "forbidden" in c["warnings"][0] and c["status"]=="warning", str(c.get("warnings")))
    clear()
    fail("nodes","\x1b[31m\n\n"); c=run(); check("blank/control-only stderr => generic message", c["warnings"]==["kubectl failed without a message"] or c["warnings"], str(c.get("warnings")))
    clear()
    c=run(); check("no errors => no warnings key, real counters", "warnings" not in c and c["pods"]["total"]==15)
finally:
    clear()
fake.cleanup()
finish()
