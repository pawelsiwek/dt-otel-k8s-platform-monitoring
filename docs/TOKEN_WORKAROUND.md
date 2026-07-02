# Token Workaround — Phase A

## Current setup (workaround)

The collector uses two different tokens for the two OTLP signals:

| Signal | Token type | Token prefix | Auth header |
|--------|-----------|-------------|-------------|
| Metrics (`/api/v2/otlp/v1/metrics`) | Classic API token (`dt0c01`) | `dt0c01.XXXX…` | `Api-Token` |
| Logs (`/api/v2/otlp/v1/logs`) | *(currently broken with api token — was verified via platform token `dt0s16.XXXX…`)* | — | — |

In the live kind deployment only the metrics token is configured; the logs endpoint is 403ing since the rollout.
Smoke test 2 was verified before the token swap, when the platform token was in place.

## Root cause

The Dynatrace Platform OAuth token (`dt0s16.*`) does not yet support
`/api/v2/otlp/v1/metrics` — Dynatrace is still rolling out OTLP metrics
write permission for platform tokens. Required scope was not resolvable
during Phase A (403 "Missing required permission" with no scope hint from
the cluster).

The classic API token (`dt0c01.*`) has `metrics.ingest` and works for
OTLP metrics, but lacks `logs.ingest` so OTLP logs fail with it.

## Target state

Once Dynatrace enables OTLP metrics write for platform tokens, the single
platform token (`dt0s16.*`) with scopes `storage:metrics:write` (or
equivalent) and `storage:logs:write` / `openpipeline:logs:ingest` should
cover both signals. The collector config should then use:

```yaml
headers:
  Authorization: "Bearer ${DT_API_TOKEN}"
```

and the K8s secret holds the platform token.

## Required config change when platform token is ready

1. Update `deploy/k8s/secret.yaml` (or re-create the secret) with the
   platform token value.
2. Change `config/deployment.yaml` exporter header from
   `Api-Token ${DT_API_TOKEN}` → `Bearer ${DT_API_TOKEN}`.
3. Rebuild the ConfigMap and restart the Deployment.
