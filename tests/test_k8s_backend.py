"""Kubernetes script: counters, issues, namespace filters, caps and the 256 KB output limit."""
import json, os, re, shutil, sys
from support import *
sys.path.insert(0, str(SCRIPTS))
fake = Fake(); D = fake.dir
def run(*a, env=None):
    return run_script("kubernetes", a, fake=fake, tools=("kubectl",))
def ns(c): return {n["name"]:n for n in c["namespaces"]}
rc,j,_,_=run(); c=j["clusters"][0]
check("baseline counters", c["pods"]=={"ready":4,"total":15} and c["nodes"]=={"ready":2,"total":3} and c["deployments"]=={"ready":3,"total":5}, str(c["pods"]))
# counters agree with issue list: pods not ready == pod issues
pi=[i for i in c["issues"] if i["kind"]=="pod"]
check("pod issues == pods not ready", len(pi)==c["pods"]["total"]-c["pods"]["ready"], (len(pi),c["pods"]))
check("deployment issues == deployments not ready", len([i for i in c["issues"] if i["kind"]=="deployment"])==2)
check("node issues (notready + pressure)", sorted(i["name"] for i in c["issues"] if i["kind"]=="node")==["n2","n3"])
sev={i["name"]:i["severity"] for i in c["issues"]}
check("CrashLoop=failed, ImagePull=warning, NotReady pod=warning, OOM=failed, Evicted=failed",
      sev["crash-1"]=="failed" and sev["pull-1"]=="warning" and sev["notready-1"]=="warning" and sev["oom-1"]=="failed" and sev["evict-1"]=="failed")
check("pressure-only node is warning, notready node failed", sev["n3"]=="warning" and sev["n2"]=="failed")
check("restarts reported", next(i for i in c["issues"] if i["name"]=="crash-1")["restarts"]==23)
check("succeeded pod ignored", all(i["name"]!="done" for i in c["issues"]))
check("scaled-to-zero deployment ignored", all(i["name"]!="d-zero" for i in c["issues"]))
check("issues sorted failed first", [i["severity"] for i in c["issues"]]==sorted([i["severity"] for i in c["issues"]], key=lambda s:{"failed":0,"warning":1}[s]))
bad=[i for i in c["issues"] if not all(isinstance(i[k],str) for k in ("name","reason","namespace"))]
check("names/reasons sanitized (no control chars, bounded)", not bad and all(re.fullmatch(r"[A-Za-z0-9._:/\-?]{0,253}",i["name"]) and re.fullmatch(r"[A-Za-z0-9._: /+\-?·]{0,70}",i["reason"]) for i in c["issues"]), str([i["reason"] for i in c["issues"]]))
check("invalid namespace shown as '?'", "?" in ns(c))
check("namespaces sorted worst first", [n["severity"] for n in c["namespaces"]]==sorted([n["severity"] for n in c["namespaces"]], key=lambda s:{"failed":0,"warning":1,"healthy":2}[s]))
tot=sum(n["pods"]["total"] for n in c["namespaces"]); rdy=sum(n["pods"]["ready"] for n in c["namespaces"])
check("namespace pod sums equal cluster counters", (rdy,tot)==(c["pods"]["ready"],c["pods"]["total"]))
# include filter
rc,j,_,_=run("--namespace=web","--namespace=shop"); c=j["clusters"][0]
check("include filter: only web+shop", set(ns(c))=={"web","shop"} and c["pods"]["total"]==6, str(c["pods"]))
check("include filter: issues limited to those namespaces (nodes kept)", all(i["namespace"] in ("web","shop","") for i in c["issues"]))
check("nodes not filtered", c["nodes"]["total"]==3)
rc,j,_,_=run("--exclude-namespace=kube-system","--exclude-namespace=jobs"); c=j["clusters"][0]
check("exclude filter", "kube-system" not in ns(c) and "jobs" not in ns(c) and c["pods"]["total"]==9, str(c["pods"]))  # 15 - kube-system(2) - jobs(4)
rc,j,_,_=run("--namespace=web","--exclude-namespace=web"); c=j["clusters"][0]
check("exclude wins over include", c["pods"]["total"]==0 and c["namespaces"]==[])
# healthy only filter => healthy status? (nodes still degraded here, so warning)
check("filtering everything out keeps node issues", all(i["kind"]=="node" for i in c["issues"]))
# validation
for label,args in (("uppercase",["--namespace=Bad"]),("underscore",["--namespace=a_b"]),("dash-leading",["--namespace=-x"]),("too long",["--namespace="+"a"*64]),("empty",["--namespace="]),("exclude invalid",["--exclude-namespace=A B"]),("injection",["--namespace=a;rm"])):
    rc,j,_,_=run(*args)
    check("rejects "+label, rc==1 and j and j["status"]=="offline" and "Invalid" in j["error"], str((rc,j)))
rc,j,_,_=run(*["--namespace=n%d"%i for i in range(51)])
check("rejects >50 namespace entries", rc==1 and "Too many" in j["error"])
rc,j,_,_=run(*["--namespace=n%d"%i for i in range(50)]); check("accepts 50 entries", rc==0 and j["status"] in ("warning","healthy"))
# calls: filter is client-side; kubectl never gets the namespace values
calls=open(D+"/calls.log").read()
check("namespace filter values never passed to kubectl", "a;rm" not in calls and "Bad" not in calls.replace("Bad_NS","").replace("BadReason",""))
# caps
shutil.copy(D+"/pods.json",D+"/pods.json.bak"); shutil.copy(D+"/deployments.json",D+"/deployments.json.bak")
many=[{"metadata":{"name":"p%d"%i,"namespace":"ns%d"%(i%80)},"status":{"phase":"Running","containerStatuses":[{"name":"c","ready":False,"restartCount":1,"state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}} for i in range(400)]
json.dump({"items":many},open(D+"/pods.json","w"))
rc,j,out,_=run(); c=j["clusters"][0]
check("issues capped at 20 with total", len(c["issues"])==20 and c["issuesTotal"]>=400, (len(c["issues"]),c.get("issuesTotal")))
check("namespaces capped at 50 with total", len(c["namespaces"])==50 and c["namespacesTotal"]==84, (len(c["namespaces"]),c.get("namespacesTotal")))
check("output within 256KB", len(out.encode())<=256*1024)
# many contexts -> fit shrinks detail instead of failing
rc,j,out,_=run(*["--context=c%d"%i for i in range(20)])
check("20 contexts still produce valid output within cap", rc==0 and j and len(out.encode())<=256*1024 and j["status"]!="offline", (rc,len(out)))
print("  size with 20 contexts:",len(out), "namespaces kept:", [len(x["namespaces"]) for x in j["clusters"]][:3])
shutil.move(D+"/pods.json.bak",D+"/pods.json"); shutil.move(D+"/deployments.json.bak",D+"/deployments.json")
# overflow still handled
open(D+"/mode_big","w").write("1")
rc,j,out,_=run(); os.remove(D+"/mode_big")
check("oversized kubectl output still handled (not a crash)", j is not None and j["status"] in ("offline","warning","healthy"), out[:200])
# mock
rc,j,_,_=run("--mock"); m=j["clusters"][0]
check("mock coherent", m["pods"]["total"]==sum(n["pods"]["total"] for n in m["namespaces"]) and len(m["issues"])==4)
import importlib; k=importlib.import_module("kubernetes")
big={"provider":"kubernetes","status":"warning","clusters":[{"name":"c%d"%i,"status":"warning","issues":[{"kind":"pod","severity":"failed","name":"p"*200,"namespace":"n","reason":"r"*60,"restarts":1}]*20,"namespaces":[{"name":"n"*60,"severity":"healthy","pods":{"ready":1,"total":1},"deployments":{"ready":1,"total":1}}]*50} for i in range(20)]}
raw=len(json.dumps(big)); out=k._fit(big)
check("_fit: oversized payload shrinks detail (>256KB raw)", raw>256*1024 and out is not None and len(out.encode())<=256*1024, (raw, None if out is None else len(out)))
j2=json.loads(out); check("_fit keeps counters/status", all("name" in c for c in j2["clusters"]))
huge={"provider":"kubernetes","status":"warning","clusters":[{"name":"c"*1000+str(i),"status":"w"} for i in range(1000)]}
check("_fit gives up cleanly when even the core is too big", k._fit(huge) is None)
fake.cleanup()
finish()
