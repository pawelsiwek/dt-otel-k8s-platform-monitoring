# dt-otelcol-k8s

A custom OpenTelemetry Collector distribution for Kubernetes observability on Dynatrace. It ships cluster-scoped metrics, topology (Smartscape entities + edges), Kubernetes events, **and host-level metrics + journald logs** to a Dynatrace environment using stock OTel components supplemented by two thin custom processors.

## Two deployment tiers

| Capability | Stock-only tier | + DT processors |
|---|---|---|
| Cluster / namespace / node / workload / pod / service entities + edges | ✅ | ✅ |
| Pod → top-level workload resolution (RS→Deployment, Job→CronJob) | ✅ | ✅ |
| Container entities (minimal node) | ✅ | ✅ + `k8s.container.image` |
| K8s Events → `KUBERNETES_EVENT` Davis records | ✅ | ✅ + per-entity/cluster throttle |
| OOM-kill → `KUBERNETES_INFERRED_EVENT` | ❌ | ✅ |
| K8s anomaly detection → Davis events | ✅ alertingengine connector | ✅ same |
| OTel Host Monitoring (`dt.entity.otel:host` + `:process` + journald logs) | ✅ | ✅ |

The stock-only path is a shippable product; the DT processors are optional additive layers — removing either degrades gracefully without breaking the baseline.

## Components

| Component | Type | Purpose |
|---|---|---|
| `dtk8stopology` | custom processor | Fan out one K8S_POD topology record into N CONTAINER records with `k8s.container.image` |
| `dtk8seventsprocessor` | custom processor | Per-entity/cluster hourly throttle + OOM-kill inferred event fan-out |
| `alertingengine` | custom connector | Metric anomaly detection → Davis events (`KUBERNETES_ANOMALY_DETECTION`) |

See [docs/CUSTOM_PROCESSORS.md](docs/CUSTOM_PROCESSORS.md) for full rationale.

## Build

Requires [OpenTelemetry Collector Builder](https://github.com/open-telemetry/opentelemetry-collector/tree/main/cmd/builder) and **Go 1.25+** (pinned in `builder-config.yaml` because `filterprocessor` v0.153.0 has a Go linker bug with deeply-nested generic instantiations on Go ≤1.24).

```sh
make build              # builds ./dist/dtotelcol via OCB
make docker-build       # main image (distroless) for Deployment + agent DaemonSet
make docker-build-host  # host-monitoring image variant (debian-slim + journalctl)
```

## Deploy

### Prerequisites

```sh
export DT_ENDPOINT=https://<your-tenant>.live.dynatrace.com
export DT_API_TOKEN=<metrics.ingest token>        # dt0c01.* API token
export DT_PLATFORM_TOKEN=<logs write token>       # dt0s16.* platform token
export K8S_CLUSTER_NAME=<cluster-name>
export K8S_CLUSTER_UID=<cluster-uid>
```

See [docs/TOKEN_WORKAROUND.md](docs/TOKEN_WORKAROUND.md) for why two tokens are currently required.

### Apply to cluster

```sh
make deploy         # deploys Deployment + DaemonSet to current kubectl context
make deploy-kind    # deploys to a local kind cluster
make undeploy       # removes all resources
```

### Local kind cluster

```sh
make kind-cluster   # create local cluster
make kind-load      # load Docker image into kind
make create-secret  # create DT_API_TOKEN secret
make deploy-kind
```

## Configuration

| File | Purpose |
|---|---|
| `config/deployment.yaml` | OTel collector config — cluster metrics, topology, events (single-replica Deployment) |
| `config/daemonset.yaml` | OTel collector config — per-node kubeletstats + cAdvisor CPU throttling (DaemonSet) |
| `config/host.yaml` | OTel collector config — hostmetrics (10s/5m/1h scrapers) + journald (DaemonSet, runs as root) |
| `builder-config.yaml` | OCB manifest listing all receiver/processor/exporter/connector components |

### Host monitoring

The `dt-otelcol-host` DaemonSet runs alongside `dt-otelcol-agent` and feeds the
[OTel Host Monitoring extension](https://docs.dynatrace.com/docs/ingest-from/opentelemetry/collector/use-cases/host-monitoring),
producing `dt.entity.otel:host` and `dt.entity.otel:process` entities visible
in **Infrastructure & Operations**. Two image variants exist because the
`journald` receiver shells out to `journalctl`, which is absent from the
distroless base used by the other components:

| Image | Base | Used by |
|---|---|---|
| `dt-otelcol-k8s` | `distroless/static:nonroot` | `dt-otelcol` Deployment, `dt-otelcol-agent` DaemonSet |
| `dt-otelcol-k8s-host` | `debian:12-slim` + `systemd` (for `journalctl`) | `dt-otelcol-host` DaemonSet |

The host DaemonSet runs `privileged`, `hostNetwork`, `hostPID`, `runAsUser: 0`,
mounts the host root at `/hostfs` and the in-memory journal at
`/run/log/journal`.

**Metric overlap caveat**: `system.cpu.*`, `system.memory.*`,
`system.filesystem.*`, and `system.network.*` from `hostmetrics` cover the same
underlying measurements as `k8s.node.*` from `kubeletstats`. Both are ingested
in parallel under different keys — see the
[upstream docs](https://docs.dynatrace.com/docs/ingest-from/opentelemetry/collector/use-cases/host-monitoring#metric-overlap-with-kubernetes-monitoring).

## OpenPipeline

The `openpipeline/` directory contains Dynatrace OpenPipeline rules that must be applied to the Dynatrace environment:

| File | Purpose |
|---|---|
| `k8s-topology-routing.yaml` | Route topology events to the topology pipeline |
| `k8s-topology-combined-pipeline.yaml` | Smartscape entity + edge extraction for all K8s entity types |
| `k8s-metrics-routing.yaml` + `k8s-metrics-entity-enrichment.yaml` | Associate CUSTOM_K8S_* entities with metrics |
| `kubernetes-events-metric.yaml` | Extract `dt.kubernetes.events` counter metric |
| `kubernetes-anomaly-detection-routing.yaml` | Route anomaly detection events to Davis |

## Testing

```sh
# Unit tests for custom processors
go test ./processor/dtk8seventsprocessor/...
go test ./processor/dtk8stopology/...

# Compatibility checks (requires dtctl and a live cluster)
make smoke-test
```

## Known limitations

- **Two tokens required** — metrics use a classic API token; logs use a platform token. See [docs/TOKEN_WORKAROUND.md](docs/TOKEN_WORKAROUND.md).
- **Deferred entity types** — ConfigMaps, Secrets, CRDs, PersistentVolumes, and extended anomaly rules are not yet implemented.
- **Model differences** — Entity type names, metric key names, and units differ from the legacy Dynatrace Kubernetes monitoring module.

## Reference docs

| Doc | Purpose |
|---|---|
| [CUSTOM_PROCESSORS.md](docs/CUSTOM_PROCESSORS.md) | Architecture of the two custom processors |
| [TOKEN_WORKAROUND.md](docs/TOKEN_WORKAROUND.md) | Two-token workaround details |
