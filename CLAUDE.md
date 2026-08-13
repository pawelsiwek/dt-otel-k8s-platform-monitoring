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
         dt.smartscape.k8s_cluster,
         dt.smartscape.k8s_namespace,
         dt.smartscape.k8s_pod,
         dt.smartscape.container,
         dt.smartscape.k8s_deployment   -- whichever are relevant
| limit 5
```
Every `dt.smartscape.*` field relevant to the metric's entity scope must be non-null. A null value means the OpenPipeline enrichment step is not matching (check the matcher condition in the pipeline settings, and verify the idComponent fields are present on the metric).

### 2c. Entity properties
Verify the entity itself has correct properties (not just the metric):
```dql
smartscapeNodes K8S_POD   -- or CONTAINER etc.
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

All pipelines live in the extension under `extension/src/openpipeline/`. One
routing rule (`openpipeline/k8s-logs-routing.yaml`) is applied separately —
see "Why logs still need a routing rule" below.

Use the **`dt-extension-deploy` skill** to upload and activate. The dtctl
platform token is sufficient; no classic API token is needed except for the
one-time developer-CA upload.

Bump `EXT_VERSION` in the Makefile and `version:` in `extension/src/extension.yaml`
together — DT rejects a re-upload of an existing version.

### What ships

| File | `customId` | Scope |
|---|---|---|
| `logs.pipeline.json` | `k8s-otel-logs` | topology entity extraction (10 types) + `kubernetes.events` counter |
| `metrics-enrichment.pipeline.json` | `k8s-otel-metrics-enrichment` | `extractNode: false` lookups, plus container extraction |
| `metrics-extraction.pipeline.json` | `k8s-otel-metrics-extraction` | `extractNode: true` for all 10 types |
| `metrics.source.json` | — | metrics ingest source, static routing |

### Routing: metrics static, logs by rule

**Metrics** route statically. `transform/openpipeline_source_metrics` stamps
`dt.openpipeline.source = "custom:dt-k8s-otel-topology"`, the bundled ingest
source claims it, and `staticRouting.pipelineId` references the pipeline's
`customId` — so no objectId patching is needed.

**Logs** need `openpipeline/k8s-logs-routing.yaml`, applied with
`dtctl apply -f openpipeline/k8s-logs-routing.yaml --plain`. Its `pipelineId`
*is* an objectId and must be re-resolved if the extension is installed into a
different environment.

#### Why logs still need a routing rule

`dt.openpipeline.source` is assigned **server-side from the ingest path**. An
`extension`-type ingest source therefore only claims data delivered through the
extension execution path (EEC). This collector pushes straight to
`/api/v2/otlp/v1/logs`, so its logs arrive on the built-in OTLP source and must
be routed by rule.

Metrics behave differently in practice and do match the bundled source, which is
why there is no metrics routing rule.

This was verified the hard way — setting `dt.openpipeline.source` on logs to the
bare name, to the `extension:`-prefixed name, and adding
`dt.event.route_to_openpipeline: "true"` all left records in `logs:default`.
Do not re-add a logs ingest source expecting it to work; it installs cleanly and
silently never matches.

To diagnose routing, read `dt.openpipeline.pipelines` off an ingested record:
```dql
fetch logs, from:now()-5m | filter event.provider == "KUBERNETES_OTEL_TOPO"
| summarize cnt=count(), by:{dt.openpipeline.pipelines}
```
`logs:k8s-otel-logs` means the rule is working; `logs:default` means it is not.

DT normalizes a logs-scope ingest source to `extension:<name>` on store — that is
cosmetic and true of every extension, not a bug.

### Metrics modes (post-install, no rebuild)

The metrics ingest source targets `k8s-otel-metrics-enrichment` by default.
Both toggles are edits to that one settings object, in the DT OpenPipeline UI or
via `dtctl`:

* **Enrichment (default)** — attaches `dt.smartscape.*` entity IDs to metric data
  points without creating entities. Entity creation is the logs pipeline's job.
* **Extraction** — repoint `staticRouting.pipelineId` to
  `k8s-otel-metrics-extraction` to also create nodes/edges from metrics. Useful
  when the topology pull is unavailable, or to fill the 120s gap between pulls.
  Writes fewer entity properties than the logs pipeline (no `k8s.object`,
  `k8s.pod.phase`, `k8s.node.system_uuid`).
* **Off** — set `enabled: false` on the metrics ingest source.

Inspect the live state with:
```bash
dtctl get settings --schema builtin:openpipeline.metrics.ingest-sources --plain
```

### Spans

Span-based entity extraction is not currently shipped. The previous standalone
`k8s-spans-entity-extraction.yaml` was removed in the extension migration and is
recoverable from git history if it is reintroduced.
