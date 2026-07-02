# Custom Processors

Two custom OTel processors ship with this collector. Both are **optional additive
layers** on top of a fully functional stock-OTel path — removing them degrades
gracefully; it does not break the baseline.

---

## Processor summary

| Processor | Pipeline | Single responsibility | ~LOC |
|---|---|---|---|
| `dtk8stopology` | `logs/topology` | Pod → container fan-out with `k8s.container.image` | ~100 |
| `dtk8seventsprocessor` | `logs/events` | OOM-kill fan-out + per-entity/cluster throttle | ~150 |

---

## 1. `dtk8stopology` (`logs/topology` pipeline)

**Single responsibility:** fan out one K8S_POD topology record into N CONTAINER
records, one per `spec.containers[]` / `spec.initContainers[]` element, enriching
each with `k8s.container.image`.

**Input:** `KUBERNETES_OTEL_TOPO` pod records produced by `transform/topology` +
`k8sattributes` + `transform/workload_dims`. All pod identity attributes
(`k8s.pod.uid`, `k8s.pod.name`, `k8s.namespace.name`, `k8s.node.name`) are
already set on the record; the body still carries the raw K8s Pod object.

**Output:** all input records passed through + one `CONTAINER` topology record
per container with `k8s.container.name`, `k8s.container.image`, and pod/ns/node
identity. These records merge onto the minimal CONTAINER node that the metrics
pipeline materialises via `enrich-custom-container` (`extractNode: true`).

**Why not stock OTTL:** OTTL cannot fan out one input record into N output
records. The 1→N emit requires Go.

---

## 2. `dtk8seventsprocessor` (`logs/events` pipeline)

**Single responsibility:** (a) throttle `KUBERNETES_EVENT` records per entity and
per cluster; (b) fan out `KUBERNETES_INFERRED_EVENT` records for OOM-killed
containers.

**Input (after `transform/k8sevents` OTTL):**
- K8s Event watch records with `event.provider == "KUBERNETES_EVENT"` and all
  Davis fields already mapped by OTTL.
- K8s Pod MODIFIED watch records (`k8s.resource.name == "pods"`, `body["type"] == "MODIFIED"`).

**Output:**
- `KUBERNETES_EVENT` records that pass the per-entity (default: 1000/h) and
  per-cluster (default: 10000/h) throttle.
- `KUBERNETES_INFERRED_EVENT` records for each container whose
  `lastState.terminated.reason == "OOMKilled"`.

**Why not stock OTTL:**
- *Throttle*: stateful counters keyed by `(cluster, namespace, involvedObject,
  reason, hour)` across batches. No stock log rate-limiter matches this model
  (`probabilisticsampler` = blanket %, `tailsampling` = traces only).
- *OOM fan-out*: iterating `status.containerStatuses[]` and emitting a new
  record type requires a loop + 1→N emit — neither expressible in OTTL.

---

## Two deployment tiers

| Capability | Stock-only tier | + DT processors (full) |
|---|---|---|
| Cluster / namespace / node / workload / service entities + edges + `k8s.object` | ✅ OTTL + `k8sattributes` + OpenPipeline | ✅ same |
| Pod → top-level workload edges (RS→Deployment, Job→CronJob) | ✅ `k8sattributes` | ✅ same |
| Container entities (minimal node) | ✅ metrics pipeline (`extractNode: true`) | ✅ same |
| `k8s.container.image` on CONTAINER nodes | ❌ | ✅ `dtk8stopology` |
| K8s Events → `KUBERNETES_EVENT` Davis records | ✅ `transform/k8sevents` OTTL | ✅ + per-entity/cluster throttle |
| OOM-kill → `KUBERNETES_INFERRED_EVENT` | ❌ | ✅ `dtk8seventsprocessor` |

---

## What is now handled by stock OTel

All stateless field mapping that was previously in the custom processors has been
moved to stock OTTL `transform` processors and `k8sattributes`:

| Capability | Component |
|---|---|
| Per-kind topology attrs (`k8s.topo.node.type`, `event.provider`, identity fields) | `transform/topology` |
| `k8s.object` (full K8s object JSON) | `transform/topology` — `String(body)` |
| Pod → top-level workload resolution | `k8sattributes` (same config as metrics pipeline) |
| `k8s.workload.name/.kind` cascade | `transform/workload_dims` (log_statements) |
| K8s Event → Davis field mapping | `transform/k8sevents` |
| K8S_CLUSTER entity | OpenPipeline — fires on every record with `k8s.cluster.uid` |
| Namespace / node UID-based matchers | Replaced by name-based matchers in OpenPipeline |

### Stale rationale removed

Three justifications from the original `CUSTOM_PROCESSORS.md` no longer apply:

1. **Heartbeat/TTL refresh is inert.** Topology pods run `mode: pull` @120 s
   and `refresh_interval` was always 0; the goroutine never started. The receiver
   re-lists every object every cycle, so entities refresh naturally.

2. **The stateful UID cache is not needed.** Smartscape IDs key on
   `cluster_uid + <name>`, never on `k8s.namespace.uid` / `k8s.node.uid`. The
   UIDs appeared only as `isNotNull()` matcher gates, which are now name-based.

3. **Two-level owner resolution is a solved stock problem.** `k8sattributes`
   already resolves pod → RS → Deployment and pod → Job → CronJob via
   `k8s.pod.uid` association — exactly as it does for the metrics pipeline.
