#!/usr/bin/env python3
"""
Phase E compat harness — verifies the OTel collector output against the
Phase E sign-off criteria.

Usage:
    python3 compat_checks.py [--cluster-name NAME] [--context CTX] [--lookback 15m]
"""
import json
import os
import subprocess
import sys

# --- config ------------------------------------------------------------------
CLUSTER = os.environ.get("CLUSTER_NAME", "dt-otelcol-smoke")
CTX     = os.environ.get("DTCTL_CONTEXT", "")
LOOK    = os.environ.get("LOOKBACK", "15m")

PASS = FAIL = WARN = 0

# --- helpers -----------------------------------------------------------------
R = "\033[31m"; G = "\033[32m"; Y = "\033[33m"; B = "\033[1m"; E = "\033[0m"

def log_pass(msg):  global PASS; PASS += 1; print(f"{G}  PASS  {msg}{E}")
def log_fail(msg):  global FAIL; FAIL += 1; print(f"{R}  FAIL  {msg}{E}")
def log_warn(msg):  global WARN; WARN += 1; print(f"{Y}  WARN  {msg}{E}")
def section(msg):   print(f"\n{B}{msg}{E}")

def dql(query: str) -> dict:
    result = subprocess.run(
        ["dtctl", "query", query, "--context", CTX, "--plain", "-o", "json"],
        capture_output=True, text=True
    )
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return {}

def records(query: str) -> list:
    d = dql(query)
    # --plain -o json returns {"records": [...]} directly
    # --agent mode returns {"ok": true, "result": {"records": [...]}}
    if "records" in d:
        return d.get("records") or []
    return (d.get("result") or {}).get("records") or []

def count_result(query: str) -> int:
    recs = records(query)
    if not recs:
        return 0
    r = recs[0]
    for v in r.values():
        try: return int(float(str(v)))
        except: pass
    return 0

def field_values(field: str, query: str) -> set:
    return {str(r.get(field, "")) for r in records(query) if r.get(field)}

# --- A. Metric coverage -------------------------------------------------------
section("A. Metric coverage")

BASE  = f'fetch metric.series, from:now()-{LOOK}'
FILT  = f'filter k8s.cluster.name == "{CLUSTER}"'
MKEYS = field_values(
    "metric.key",
    f'{BASE} | {FILT} | summarize cnt=count(), by:{{metric.key}}'
)

REQUIRED_METRICS = {
    "k8s.node.allocatable_cpu":            "node allocatable CPU",
    "k8s.node.allocatable_memory":         "node allocatable memory",
    "k8s.node.allocatable_pods":           "node allocatable pods",
    "k8s.node.condition_ready":            "node ready condition",
    "k8s.pod.phase":                       "pod phase",
    "k8s.container.cpu_request":           "container CPU request",
    "k8s.container.memory_request":        "container memory request",
    "k8s.container.cpu_limit":             "container CPU limit",
    "k8s.container.memory_limit":          "container memory limit",
    "k8s.container.restarts":              "container restarts",
    "container.cpu.usage":                 "container CPU usage (kubelet)",
    "container.memory.working_set":        "container memory working_set (kubelet)",
    "container.cpu.cfs.throttled.time":    "container CPU throttled time (cadvisor)",
    "container.cpu.cfs.throttled.periods": "container CPU throttled periods (cadvisor)",
    "container.cpu.cfs.periods":           "container CPU CFS periods (cadvisor)",
    "k8s.deployment.desired":              "deployment desired",
    "k8s.deployment.available":            "deployment available",
    "k8s.daemonset.desired_scheduled_nodes": "daemonset desired nodes",
    "k8s.daemonset.ready_nodes":           "daemonset ready nodes",
    "k8s.replicaset.desired":              "replicaset desired",
    "k8s.replicaset.available":            "replicaset available",
}

for key, label in sorted(REQUIRED_METRICS.items()):
    if key in MKEYS:
        log_pass(f"{key}  ({label})")
    else:
        log_fail(f"{key}  ({label})  -- not flowing")

# --- B. Identity attribute completeness ---------------------------------------
section("B. Identity attribute completeness (pod-scope)")

q = (f'{BASE} | {FILT} and metric.key == "k8s.pod.phase" | '
     f'summarize total=count(), '
     f'with_cluster_uid=countIf(isNotNull(k8s.cluster.uid)), '
     f'with_namespace=countIf(isNotNull(k8s.namespace.name)), '
     f'with_node=countIf(isNotNull(k8s.node.name)), '
     f'with_smartscape=countIf(isNotNull(dt.smartscape.k8s_cluster))')
r = records(q)
if r:
    row = r[0]
    total = int(float(row.get("total", 0)))
    checks = {
        "k8s.cluster.uid":            int(float(row.get("with_cluster_uid", 0))),
        "k8s.namespace.name":         int(float(row.get("with_namespace", 0))),
        "k8s.node.name":              int(float(row.get("with_node", 0))),
        "dt.smartscape.k8s_cluster":  int(float(row.get("with_smartscape", 0))),
    }
    for field, cnt in checks.items():
        pct = int(cnt * 100 / total) if total else 0
        if cnt == total and total > 0:
            log_pass(f"{field}: {cnt}/{total} ({pct}%)")
        elif cnt > 0:
            log_warn(f"{field}: {cnt}/{total} ({pct}%) — partial")
        else:
            log_fail(f"{field}: {cnt}/{total} — missing")
else:
    log_fail("No pod-scope metric records found — cannot check identity attrs")

# --- C. Smartscape entity coverage -------------------------------------------
section("C. Smartscape entity coverage")

REQUIRED_ENTITIES = [
    "CUSTOM_K8S_CLUSTER",
    "CUSTOM_K8S_NAMESPACE",
    "CUSTOM_K8S_NODE",
    "CUSTOM_K8S_POD",
    "CUSTOM_K8S_DEPLOYMENT",
    "CUSTOM_K8S_DAEMONSET",
    "CUSTOM_K8S_REPLICASET",
    "CUSTOM_K8S_SERVICE",
    "CUSTOM_CONTAINER",
]

for etype in REQUIRED_ENTITIES:
    cnt = count_result(f'smartscapeNodes "*" | filter type == "{etype}" | summarize cnt=count()')
    if cnt > 0:
        log_pass(f"{etype}  ({cnt} nodes)")
    else:
        log_fail(f"{etype}  -- 0 nodes in Smartscape")

# --- D. Topology event type coverage -----------------------------------------
section("D. Topology event (KUBERNETES_OTEL_TOPO) type coverage")

TOPO_TYPES = field_values(
    "k8s.topo.node.type",
    f'fetch logs, from:now()-{LOOK} | filter event.provider == "KUBERNETES_OTEL_TOPO" '
    f'| summarize cnt=count(), by:{{k8s.topo.node.type}}'
)

REQUIRED_TOPO = [
    "K8S_CLUSTER", "K8S_NAMESPACE", "K8S_NODE", "K8S_POD",
    "K8S_DEPLOYMENT", "K8S_DAEMONSET", "K8S_REPLICASET", "K8S_SERVICE",
    "CONTAINER",
]

for ttype in REQUIRED_TOPO:
    if ttype in TOPO_TYPES:
        log_pass(f"event type  {ttype}")
    else:
        log_fail(f"event type  {ttype}  -- no events in last {LOOK}")

# --- E. k8s.object on pod events ---------------------------------------------
section("E. k8s.object payload on pod topology events")

obj_total = count_result(
    f'fetch logs, from:now()-{LOOK} | filter event.provider == "KUBERNETES_OTEL_TOPO" '
    f'and k8s.topo.node.type == "K8S_POD" | summarize cnt=count()'
)
obj_with = count_result(
    f'fetch logs, from:now()-{LOOK} | filter event.provider == "KUBERNETES_OTEL_TOPO" '
    f'and k8s.topo.node.type == "K8S_POD" | summarize cnt=countIf(isNotNull(k8s.object))'
)

if obj_with > 0 and obj_with == obj_total:
    log_pass(f"k8s.object present on all {obj_with}/{obj_total} pod events")
elif obj_with > 0:
    log_warn(f"k8s.object present on {obj_with}/{obj_total} pod events (partial)")
else:
    log_fail("k8s.object missing from pod topology events")

# --- F. Known gaps (informational) -------------------------------------------
section("F. Known gaps (deferred — informational)")

GAPS = [
    "dt.kubernetes.cluster.readyz -- no OTel equivalent (future: cAdvisor API probe)",
    "dt.kubernetes.workload.conditions -- no OTel equivalent (future: extend processor)",
    "dt.kubernetes.pod.containers_desired -- no OTel equivalent",
    "dt.kubernetes.events (count metric) -- KubernetesLogEvents port deferred post-E",
    "KUBERNETES_EVENT / KUBERNETES_INFERRED_EVENT / KUBERNETES_ANOMALY_DETECTION -- deferred post-E",
    "K8S_STATEFULSET / K8S_JOB / K8S_CRONJOB -- receiver supports them; no objects in test cluster",
    "Native K8S_* Smartscape types -- OTLP entity signal not yet in Dynatrace Platform; using CUSTOM_K8S_*",
    "CPU in cores (OTel) vs millicores (legacy); Sum[monotonic] counters require rate() in DQL",
]
for g in GAPS:
    log_warn(g)

# --- summary -----------------------------------------------------------------
total = PASS + FAIL + WARN
print(f"\n==========================================")
print(f"  PASS={PASS}  FAIL={FAIL}  WARN={WARN}  (total={total})")
if FAIL == 0:
    print(f"{G}  PHASE E SIGN-OFF: PASS{E}")
else:
    print(f"{R}  PHASE E SIGN-OFF: FAIL ({FAIL} failures){E}")
print(f"==========================================")
sys.exit(FAIL)
