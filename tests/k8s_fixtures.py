"""Fixture builders for the fake kubectl: a small cluster with every kind of problem."""
import json
import os


def pod(name, ns, phase="Running", ready=True, waiting=None, term=None, restarts=0, reason=None, conds=None, init=None):
    cs = {"name": "c", "ready": ready, "restartCount": restarts, "state": {}}
    if waiting:
        cs["state"] = {"waiting": {"reason": waiting}}
    elif term:
        cs["state"] = {"terminated": {"reason": term[0], "exitCode": term[1]}}
    elif ready:
        cs["state"] = {"running": {}}
    st = {"phase": phase, "containerStatuses": [cs]}
    if phase == "Pending" and not waiting:
        st["containerStatuses"] = []
    if reason:
        st["reason"] = reason
    if conds:
        st["conditions"] = conds
    if init:
        st["initContainerStatuses"] = init
    return {"metadata": {"name": name, "namespace": ns}, "status": st}


def node(name, ready=True, pressure=()):
    c = [{"type": "Ready", "status": "True" if ready else "False"}]
    c += [{"type": p, "status": "True"} for p in pressure]
    if "DiskPressure" not in pressure:
        c.append({"type": "DiskPressure", "status": "False"})
    return {"metadata": {"name": name, "labels": {}}, "status": {"conditions": c}}


def dep(name, ns, spec, ready, replicas=None):
    return {"metadata": {"name": name, "namespace": ns}, "spec": {"replicas": spec},
            "status": {"readyReplicas": ready, "replicas": spec if replicas is None else replicas}}


def write_fixtures(d):
    pods = [
        pod("ok-1", "web"), pod("ok-2", "web"),
        pod("done", "jobs", phase="Succeeded", ready=False),
        pod("crash-1", "payments", ready=False, waiting="CrashLoopBackOff", restarts=23),
        pod("pull-1", "jobs", ready=False, waiting="ImagePullBackOff"),
        pod("pend-1", "shop", phase="Pending", conds=[{"type": "PodScheduled", "status": "False", "reason": "Unschedulable"}]),
        pod("pend-2", "shop", phase="Pending"),
        pod("evict-1", "kube-system", phase="Failed", ready=False, reason="Evicted"),
        pod("oom-1", "payments", ready=False, term=("OOMKilled", 137), restarts=4),
        pod("notready-1", "web", ready=False),
        pod("init-1", "web", ready=False, init=[{"name": "i", "ready": False, "restartCount": 2, "state": {"waiting": {"reason": "PodInitializing"}}}]),
        pod("evil\nname;rm -rf", "jobs", ready=False, waiting="Bad\x1b[31mReason\nline2" + "x" * 200),
        pod("x" * 400, "jobs", ready=False, waiting="CrashLoopBackOff"),
        pod("badns", "Bad_NS!", ready=False, waiting="Error"),
        pod("ok-k", "kube-system"),
    ]
    nodes = [node("n1"), node("n2", ready=False, pressure=("MemoryPressure",)), node("n3", pressure=("DiskPressure",))]
    deps = [dep("d-ok", "web", 2, 2), dep("d-zero", "shop", 0, 0, 0), dep("d-part", "shop", 3, 2),
            dep("d-down", "payments", 2, 0), dep("d-ks", "kube-system", 1, 1)]
    for name, items in (("pods", pods), ("nodes", nodes), ("deployments", deps)):
        with open(os.path.join(d, name + ".json"), "w") as f:
            json.dump({"items": items}, f)
