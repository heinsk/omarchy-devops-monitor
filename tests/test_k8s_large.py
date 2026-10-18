"""Kubernetes script with big clusters: paging, memory and time caps, hostile objects."""
import json, os, sys, time, shutil, importlib.util, tracemalloc
from support import *
fake = Fake(); D = fake.dir; fake.use_in_process()
def run(*a):
    open(D+"/calls.log","w").close()
    t=time.time()
    rc,j,out,err=run_script("kubernetes", a, fake=fake, tools=("kubectl",))
    dt=time.time()-t
    return rc,j,out,dt,fake.calls()
def raws(calls): return [c[2] for c in calls if c[:2]==["get","--raw"]]
def mod():
    spec=importlib.util.spec_from_file_location("k8s_under_test",str(SCRIPTS/"kubernetes.py")); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    m._KUBECTL_PATH=fake.path("kubectl")
    return m
def mk(n,nsn=60,bad_every=50,pad=0,extra=None):
    items=[]
    for i in range(n):
        ns="team-%02d"%(i%nsn); bad=(i%bad_every==0)
        st={"phase":"Running","containerStatuses":[{"name":"c","ready":not bad,"restartCount":3 if bad else 0,"state":{"waiting":{"reason":"CrashLoopBackOff"}} if bad else {"running":{}}}]}
        md={"name":"pod-%05d"%i,"namespace":ns}
        if pad: md["annotations"]={"big":"y"*pad}
        items.append({"metadata":md,"spec":{"pad":"y"*3000},"status":st})
    return items
def put(pods):
    json.dump({"items":pods},open(D+"/pods.json","w"))
def clean():
    for f in ("fail_pods","fail_nodes","fail_deployments","hog","slow"):
        if os.path.exists(D+"/"+f): os.remove(D+"/"+f)
try:
    deps={"items":[{"metadata":{"name":"d","namespace":"team-%02d"%i},"spec":{"replicas":1},"status":{"readyReplicas":1,"replicas":1}} for i in range(60)]}
    json.dump(deps,open(D+"/deployments.json","w")); json.dump({"items":[{"metadata":{"name":"n1","labels":{}},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]},open(D+"/nodes.json","w"))
    # 1. 3000 pods: read in pages, never one big list
    put(mk(3000)); rc,j,out,dt,calls=run(); c=j["clusters"][0]
    check("3000-pod cluster works without filter", rc==0 and c["pods"]["total"]==3000 and c["pods"]["ready"]==2940 and "warnings" not in c, str(c.get("warnings")))
    pr=[r for r in raws(calls) if r.startswith("/api/v1/pods")]
    check("pods read as 60 pages of 50 with continue tokens", len(pr)==60 and all("limit=50" in r for r in pr) and "continue" not in pr[0] and all("continue=" in r for r in pr[1:]), str(len(pr)))
    check("no `-o json` list is ever requested (only get --raw / small checks)", all(c[:2]==["get","--raw"] or c[0] in ("config","version") for c in calls), str([c for c in calls if c[:2]!=["get","--raw"]][:3]))
    check("every request names the context and goes through the sh data-limit wrapper only", all("--context" in c for c in calls if c[:2]==["get","--raw"]))
    check("output within 256 KB", len(out.encode())<=256*1024, len(out))
    # 2. 6000 pods (used to exceed the 16 MB single-list cap) now works unfiltered
    put(mk(6000)); rc,j,out,dt,calls=run(); c=j["clusters"][0]
    check("6000-pod cluster (was over the old 16 MB cap) works, no warning", rc==0 and c["pods"]["total"]==6000 and "warnings" not in c, str(c.get("warnings")))
    # 3. filtered => namespaced paths, never the cluster-wide pod list
    rc,j,out,dt,calls=run("--namespace=team-01","--namespace=team-02"); c=j["clusters"][0]
    check("filtered big cluster works", rc==0 and c["pods"]["total"]==200 and "warnings" not in c, str((c["pods"],c.get("warnings"))))
    r=raws(calls)
    check("filtered: only /namespaces/NS/ paths for pods and deployments", all("/namespaces/team-0" in x for x in r if "/pods" in x or "/deployments" in x) and not any(x.startswith("/api/v1/pods") or x.startswith("/apis/apps/v1/deployments") for x in r), str(r))
    check("filtered + exclude still applied", run("--namespace=team-01","--namespace=team-02","--exclude-namespace=team-02")[1]["clusters"][0]["pods"]["total"]==100)
    # 4. more than 10 included => cluster-wide paged list
    put(mk(300)); rc,j,out,dt,calls=run(*["--namespace=team-%02d"%i for i in range(11)]); c=j["clusters"][0]
    check(">10 included namespaces: cluster-wide paged list, correct result", any(x.startswith("/api/v1/pods?") for x in raws(calls)) and c["pods"]["total"]==55, str(c["pods"]))
    # 5. unknown namespace => empty, no warning
    rc,j,out,dt,calls=run("--namespace=does-not-exist"); c=j["clusters"][0]
    check("unknown included namespace => 0 pods, no warning", c["pods"]["total"]==0 and "warnings" not in c)
    # 6. failures
    open(D+"/fail_pods","w").write('Error from server (Forbidden): pods is forbidden: User "x" cannot list resource "pods"\n\x1b[31mred\x1b[0m')
    rc,j,out,dt,calls=run(); c=j["clusters"][0]
    check("failed pods query => warning with the message", rc==0 and c["status"]=="warning" and any("forbidden" in w for w in c["warnings"]), str(c))
    check("warning text has no control characters", all(all(ord(ch)>=32 and ch!="\x7f" for ch in w) for w in c["warnings"]))
    clean(); open(D+"/fail_nodes","w").write("nodes is forbidden")
    rc,j,out,dt,calls=run(); c=j["clusters"][0]
    check("nodes failing but pods fine => warning (not offline, not healthy)", c["status"]=="warning" and c["pods"]["total"]==300, c["status"])
    clean()
    for r_ in ("nodes","pods","deployments"): open(D+"/fail_"+r_,"w").write("boom")
    rc,j,out,dt,calls=run(); check("all queries failing => offline", j["clusters"][0]["status"]=="offline", j["clusters"][0]["status"])
    clean()

    # 7. the finding: inflated annotations
    put(mk(200,pad=250*1024))                 # ~50 MB of annotations, 250 KiB each (the API's limit)
    print("pods.json MB:",round(os.path.getsize(D+"/pods.json")/1048576,1))
    m=mod(); tracemalloc.start()
    c=m.fetch_context("fake-ctx")
    cur,peak=tracemalloc.get_traced_memory(); tracemalloc.stop()
    check("200 pods x 250 KiB annotations: counted correctly, no warning", c["pods"]["total"]==200 and "warnings" not in c, str(c.get("warnings")))
    check("script peak memory stays bounded (one page, not the whole list): %.0f MB"%(peak/1048576), peak < 80*1048576, peak)
    m2=mod(); items,err=m2._list_paged("/api/v1/pods","fake-ctx",m2._slim_pod,"pods")
    check("retained objects carry no annotations (slimmed)", err is None and len(items)==200 and len(json.dumps(items))<200*1500 and "big" not in json.dumps(items), len(json.dumps(items)))
    # a page above the byte cap is cut off while it is being read
    m3=mod(); m3.PAGE_LIMIT=500
    t=time.time(); items,err=m3._list_paged("/api/v1/pods","fake-ctx",m3._slim_pod,"pods")
    check("one page above 16 MB: stopped, clear message, nothing partial", items==[] and err and "larger than 16 MB" in err and "kubernetes.namespaces" in err, str(err))
    check("...and fast (process group killed)", time.time()-t<20, time.time()-t)

    # 8. object / page / time caps
    put(mk(600)); m4=mod(); m4.MAX_OBJECTS=500
    items,err=m4._list_paged("/api/v1/pods","fake-ctx",m4._slim_pod,"pods")
    check("more than MAX_OBJECTS: whole list reported as failed with a hint", items==[] and err and "More than 500 pods" in err and "kubernetes.namespaces" in err, str(err))
    m5=mod(); m5.MAX_PAGES=3
    items,err=m5._list_paged("/api/v1/pods","fake-ctx",m5._slim_pod,"pods")
    check("endless pagination is cut at MAX_PAGES", items==[] and err and "too many pages" in err, str(err))
    open(D+"/slow","w").write("0.8")
    m6=mod(); m6.LIST_BUDGET=2.5
    t=time.time(); items,err=m6._list_paged("/api/v1/pods","fake-ctx",m6._slim_pod,"pods")
    check("wall-clock budget for a whole list is enforced", items==[] and err and "took longer" in err and time.time()-t<8, "%s %.1f"%(err,time.time()-t))
    clean()

    # 9. memory limit on the kubectl process itself
    open(D+"/hog","w").write("2048")          # fake kubectl tries to allocate 2 GiB
    put(mk(10)); m7=mod()
    items,err=m7._list_paged("/api/v1/pods","fake-ctx",m7._slim_pod,"pods")
    check("kubectl process cannot allocate beyond the data limit: clear error, plugin survives", items==[] and err and "out of memory" in err and "kubernetes.namespaces" in err, str(err))
    clean()
    # the wrapper must hand the kubectl argv over untouched, whatever the context is called
    odd='we ird"ctx$(touch '+D+'/pwned);`x`\'y'
    open(D+"/calls.log","w").close(); m8=mod(); m8._list_paged("/api/v1/nodes",odd,m8._slim_node,"nodes")
    calls=[json.loads(l) for l in open(D+"/calls.log") if l.strip()]
    check("odd context name arrives as ONE literal argument, nothing is executed", calls and calls[0][calls[0].index("--context")+1]==odd and not os.path.exists(D+"/pwned"), str(calls[:1]))
finally:
    clean()
    fake.cleanup()
finish()
