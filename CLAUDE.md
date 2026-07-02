# dt-otelcol-k8s — Claude Working Instructions

## 1. Always commit after changes

After every config, code, or pipeline change — commit immediately before reporting the task done. Do not leave uncommitted changes.

Use a descriptive commit message that explains WHY (not just what).

## 2. Always verify metrics in Dynatrace after changes

After any change that affects metric collection or enrichment, verify in DT that both layers are correct:

### 2a. Raw OTel dimensions
Verify the metric carries the expected OTel semantic-convention attributes:
```dql
fetch metric.series, from:now()-10m
| filter metric.key == "<metric.key>"
| fields metric.key,
         k8s.cluster.uid, k8s.namespace.name, k8s.pod.uid, k8s.pod.name,
         k8s.container.name, k8s.node.name,
         k8s.workload.name, k8s.workload.kind
| limit 5
```
Check that none of the expected fields are null, and that workload names match the actual pod names (wrong workload names indicate the k8sattributes namespace-batch bug is active).

### 2b. Derived Smartscape entity IDs
Verify the OpenPipeline enrichment is firing and producing entity IDs:
```dql
fetch metric.series, from:now()-10m
| filter metric.key == "<metric.key>"
| fields metric.key,
         dt.smartscape.custom_k8s_cluster,
         dt.smartscape.custom_k8s_namespace,
         dt.smartscape.custom_k8s_pod,
         dt.smartscape.custom_container,
         dt.smartscape.custom_k8s_deployment   -- whichever are relevant
| limit 5
```
Every `dt.smartscape.*` field relevant to the metric's entity scope must be non-null. A null value means the OpenPipeline enrichment step is not matching (check the matcher condition in the pipeline settings, and verify the idComponent fields are present on the metric).

### 2c. Entity properties
Verify the entity itself has correct properties (not just the metric):
```dql
smartscapeNodes CUSTOM_K8S_POD   -- or CUSTOM_CONTAINER etc.
| filter id == "<entity-id>"
| fields id, name, k8s.workload.name, k8s.workload.kind, k8s.namespace.name, k8s.container.name
```
If entity properties are wrong (e.g. workload.name shows a different service), it means the topology pipeline's k8sattributes enrichment is affected by the namespace-batch shared-resource bug — the entity properties will then pollute DQL queries that use entity-enriched dimensions.

## 3. ~~Known issue: k8sattributes namespace-batch bug~~ (RESOLVED)

**Status:** Fixed. `groupbyattrs/pod` processor inserted before `k8sattributes` in the topology pipeline.

**Was:** `k8sobjects` pull mode and `k8s_cluster` receiver group all pods from the same namespace into one shared `ResourceLogs`. `transform/topology` wrote per-pod attributes (like `k8s.pod.uid`) to the *shared* resource, overwriting previous values. `k8sattributes` then read only the last-written pod UID and applied that pod's workload metadata to all records in the batch — resulting in every pod entity having the same wrong `k8s.workload.name`.

**Fix:** `groupbyattrs/pod` (with `keys: [k8s.pod.uid]`) splits the shared `ResourceLogs` into one per distinct `k8s.pod.uid` record-level attribute value before `k8sattributes` runs. Each pod now resolves its own workload metadata correctly.

**Note:** `k8s_cluster` receiver (metrics pipeline) already emits per-pod `ResourceMetrics` — the bug never affected metric data points, only the topology log pipeline.

## 4. Deployment notes

- Build: `make build` (OCB, produces `./dist/dtotelcol`)
- Image: `<your-registry>/dt-otelcol-k8s:<git-sha>`
- Push: `docker push <your-registry>/dt-otelcol-k8s:<sha>`
- Deploy: `make deploy K8S_CLUSTER_NAME=... K8S_CLUSTER_UID=... DT_ENDPOINT=https://<tenant>.live.dynatrace.com/api/v2/otlp COLLECTOR_IMAGE=<your-registry>/dt-otelcol-k8s:<sha> KUBECTL_FLAGS=--context <your-context>`
- Kind deploy: `make deploy-kind DT_ENDPOINT=...`
- Rollout check: `kubectl rollout status deployment/dt-otelcol daemonset/dt-otelcol-agent -n dt-otelcol`
- Always deploy to **both** your real cluster context and the local `kind-dt-otelcol-smoke` cluster.

## 5. OpenPipeline

Changes to `openpipeline/*.yaml` must be applied to DT immediately after editing:
```bash
dtctl apply -f openpipeline/<file>.yaml --plain
```
Verify the applied state with `dtctl describe settings <objectId> -o json --plain`.

### Applying all pipelines at once

Use the `apply-openpipeline` Makefile target to apply everything in one shot:
```bash
make apply-openpipeline                        # Mode A: enrichment-only metrics (default)
make apply-openpipeline METRICS_EXTRACT=true   # Mode B: extraction + enrichment metrics
```

This applies: topology pipeline + routing, both metrics pipeline definitions, and the correct metrics routing for the selected mode.

### Metrics pipeline modes

* **Mode A (default)** — `k8s-metrics-entity-enrichment.yaml`: enriches metric data points with `dt.smartscape.*` entity IDs (`extractNode: false`). Does **not** create new Smartscape entities from metrics. Relies on the topology log pipeline for entity creation.

* **Mode B** — `k8s-metrics-entity-extraction.yaml`: enriches **and** creates Smartscape nodes/edges from metric data points (`extractNode: true` for all entity types). Useful when the topology pipeline is unavailable or as a faster-refresh supplement between 120s pull cycles. Writes a subset of entity properties compared to the topology pipeline (no `k8s.object`, `k8s.pod.phase`, `k8s.node.system_uuid`, or `k8s.container.image` — use topology pipeline for full entity detail).

### After updating the extraction pipeline's objectId

After the first `dtctl apply` of `k8s-metrics-entity-extraction.yaml`, DT assigns an `objectId`. Commit it back to the YAML and update the `pipelineId` placeholder in `k8s-metrics-routing-extraction.yaml` to match.
