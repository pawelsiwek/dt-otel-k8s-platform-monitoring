COLLECTOR_IMAGE      ?= dt-otelcol-k8s:latest
HOST_COLLECTOR_IMAGE ?= dt-otelcol-k8s-host:latest
KIND_CLUSTER         ?= dt-otelcol-smoke
KIND                 ?= $(HOME)/go/bin/kind
OCB                  ?= $(HOME)/go/bin/builder
EXT_VERSION          ?= 1.0.2
EXT_ZIP              ?= dist/extension/custom.dt-k8s-otel-topology-$(EXT_VERSION).zip
EXT_BUNDLE           ?= dist/extension/bundle-$(EXT_VERSION).zip
EXT_CERTS            ?= extension/certs
# Pin the Go toolchain used for the build. go.mod requires >= 1.25.0, but the
# 1.22.x–1.25.x linkers hit a generics "relocation target not defined" bug when
# linking pkg/ottl into filterprocessor. Fixed in 1.26.0. GOTOOLCHAIN=auto would
# otherwise select the buggy 1.25.0 from the go.mod `go` directive.
GO_TOOLCHAIN         ?= go1.26.0
DT_CONTEXT           ?=
IMAGE_PULL_POLICY    ?= IfNotPresent
K8S_CLUSTER_NAME     ?=
K8S_CLUSTER_UID      ?=
DT_ENDPOINT          ?=
DT_TENANT_URL        ?=
KUBECTL_FLAGS        ?=
METRICS_EXTRACT      ?= false

# Limit envsubst to only deploy-time variables; OTel runtime refs (${env:VAR}) are left intact.
ENVSUBST_VARS = $${COLLECTOR_IMAGE} $${HOST_COLLECTOR_IMAGE} $${IMAGE_PULL_POLICY} $${K8S_CLUSTER_NAME} $${K8S_CLUSTER_UID} $${DT_ENDPOINT}

export COLLECTOR_IMAGE HOST_COLLECTOR_IMAGE IMAGE_PULL_POLICY K8S_CLUSTER_NAME K8S_CLUSTER_UID DT_ENDPOINT

.PHONY: all build docker-build docker-build-host kind-cluster kind-load deploy deploy-kind create-secret undeploy undeploy-kind smoke-test clean apply-openpipeline extension-certs extension-pack extension-sign extension-trust-ca extension-upload

all: build

## Build the collector binary via OCB
build:
	GOTOOLCHAIN=$(GO_TOOLCHAIN) $(OCB) --config builder-config.yaml

## Build the Docker image (requires prior `make build`)
docker-build: build
	docker build -t $(COLLECTOR_IMAGE) .

## Build the host-monitoring Docker image variant (debian-slim + journalctl)
docker-build-host: build
	docker build -t $(HOST_COLLECTOR_IMAGE) -f Dockerfile.host .

## Create the kind cluster (idempotent: skip if already exists)
kind-cluster:
	$(KIND) get clusters | grep -q $(KIND_CLUSTER) || \
	    $(KIND) create cluster --name $(KIND_CLUSTER)

## Load the image into kind (runs build + docker-build first)
kind-load: docker-build docker-build-host kind-cluster
	$(KIND) load docker-image $(COLLECTOR_IMAGE) --name $(KIND_CLUSTER)
	$(KIND) load docker-image $(HOST_COLLECTOR_IMAGE) --name $(KIND_CLUSTER)

## Create or update the DT API token secret
create-secret:
	@test -n "$(DT_API_TOKEN)" || (echo "ERROR: Set DT_API_TOKEN env var first" && exit 1)
	kubectl $(KUBECTL_FLAGS) create secret generic dt-otelcol-secret \
	    --namespace dt-otelcol \
	    --from-literal=api-token=$(DT_API_TOKEN) \
	    --from-literal=platform-token=$(DT_PLATFORM_TOKEN) \
	    --dry-run=client -o yaml | \
	kubectl $(KUBECTL_FLAGS) apply -f -

## Deploy to the current kubectl context — set env vars first (see deploy/k8s/env.example)
deploy:
	@test -n "$(K8S_CLUSTER_NAME)" || (echo "ERROR: K8S_CLUSTER_NAME is not set (see deploy/k8s/env.example)" && exit 1)
	@test -n "$(K8S_CLUSTER_UID)"  || (echo "ERROR: K8S_CLUSTER_UID is not set  (see deploy/k8s/env.example)" && exit 1)
	@test -n "$(DT_ENDPOINT)"      || (echo "ERROR: DT_ENDPOINT is not set       (see deploy/k8s/env.example)" && exit 1)
	for f in deploy/k8s/*.yaml; do envsubst '$(ENVSUBST_VARS)' < $$f | kubectl $(KUBECTL_FLAGS) apply -f -; done
	$(MAKE) create-secret KUBECTL_FLAGS='$(KUBECTL_FLAGS)'

## Deploy to the local kind cluster (builds and loads the image first; auto-detects cluster UID)
deploy-kind: kind-load
	@test -n "$(DT_ENDPOINT)" || (echo "ERROR: Set DT_ENDPOINT env var first" && exit 1)
	cluster_uid=$$(kubectl --context kind-$(KIND_CLUSTER) get ns kube-system -o jsonpath='{.metadata.uid}'); \
	$(MAKE) deploy \
	    IMAGE_PULL_POLICY=Never \
	    K8S_CLUSTER_NAME=$(KIND_CLUSTER) \
	    K8S_CLUSTER_UID="$$cluster_uid" \
	    KUBECTL_FLAGS='--context kind-$(KIND_CLUSTER)'

## Remove the collector from the current kubectl context
undeploy:
	kubectl $(KUBECTL_FLAGS) delete namespace dt-otelcol --ignore-not-found
	kubectl $(KUBECTL_FLAGS) delete clusterrole dt-otelcol --ignore-not-found
	kubectl $(KUBECTL_FLAGS) delete clusterrolebinding dt-otelcol --ignore-not-found

## Remove from the local kind cluster
undeploy-kind:
	$(MAKE) undeploy KUBECTL_FLAGS='--context kind-$(KIND_CLUSTER)'

## Phase A smoke tests
smoke-test:
	@echo "=== Phase A Smoke Tests ==="
	@echo "Waiting 90s for first scrape + batch flush..."
	@sleep 90
	@echo ""
	@echo "--- Smoke test 1: OTLP metric (k8s.* prefix) ---"
	dtctl query \
	    'fetch metric.series, from:now()-10m | filter startsWith(metric.key, "k8s.") | summarize cnt=count(), by:{metric.key} | sort cnt desc | limit 5' \
	    --context $(DT_CONTEXT) --plain
	@echo ""
	@echo "--- Smoke test 2: topology event log (KUBERNETES_OTEL_TOPO_SMOKE) ---"
	dtctl query \
	    'fetch logs, from:now()-10m | filter event.provider == "KUBERNETES_OTEL_TOPO_SMOKE" | fields timestamp, k8s.namespace.name, event.provider | limit 5' \
	    --context $(DT_CONTEXT) --plain

## Tear down the kind cluster entirely
clean:
	$(KIND) delete cluster --name $(KIND_CLUSTER)

## Generate a self-signed root CA + developer certificate for dev signing (once per machine).
## Certs are written to extension/certs/ which is gitignored.
## After running this, upload extension/certs/ca.pem to Dynatrace:
##   Settings → Extensions → Extension Execution Controller → Developer certificate
extension-certs:
	@mkdir -p $(EXT_CERTS)
	dt extensions genca \
	    --ca-cert $(EXT_CERTS)/ca.pem \
	    --ca-key  $(EXT_CERTS)/ca.key \
	    --no-ca-passphrase
	dt extensions generate-developer-pem \
	    --ca-crt $(EXT_CERTS)/ca.pem \
	    --ca-key $(EXT_CERTS)/ca.key \
	    --name "dt-k8s-otel dev" \
	    -o $(EXT_CERTS)/developer.pem

## Assemble extension/extension.yaml into a ZIP (inner package, not yet signed).
extension-pack:
	@mkdir -p dist/extension
	dt extensions assemble \
	    --src extension/src \
	    -o $(EXT_ZIP) \
	    --force

## Assemble and sign the extension (requires certs in extension/certs/).
## Run `make extension-certs` once first, then upload extension/certs/ca.pem to DT.
extension-sign: extension-pack
	dt extensions sign \
	    --src $(EXT_ZIP) \
	    -o $(EXT_BUNDLE) \
	    --key $(EXT_CERTS)/developer.pem \
	    --force

## Upload the self-signed root CA cert to DT (once per CA). Requires DT_API_TOKEN and DT_TENANT_URL.
extension-trust-ca:
	@test -n "$(DT_API_TOKEN)"   || (echo "ERROR: Set DT_API_TOKEN (classic token, Write extension scope)" && exit 1)
	@test -n "$(DT_TENANT_URL)"  || (echo "ERROR: Set DT_TENANT_URL (e.g. https://<tenant>.live.dynatrace.com)" && exit 1)
	curl -sf -X POST \
	    "$(DT_TENANT_URL)/api/v2/extensions/developerCertificates" \
	    -H "Authorization: Api-Token $(DT_API_TOKEN)" \
	    -H "Content-Type: application/octet-stream" \
	    --data-binary @$(EXT_CERTS)/ca.pem

## Assemble, sign, and upload the extension to the configured DT tenant. Requires DT_API_TOKEN and DT_TENANT_URL.
extension-upload: extension-sign
	@test -n "$(DT_API_TOKEN)"   || (echo "ERROR: Set DT_API_TOKEN (classic token, Write extension scope)" && exit 1)
	@test -n "$(DT_TENANT_URL)"  || (echo "ERROR: Set DT_TENANT_URL (e.g. https://<tenant>.live.dynatrace.com)" && exit 1)
	dt extensions upload $(EXT_BUNDLE) \
	    --tenant-url $(DT_TENANT_URL) \
	    --api-token $(DT_API_TOKEN)

## Apply OpenPipeline settings to Dynatrace.
## Applies topology pipeline + both metrics pipeline definitions (always idempotent).
## Also applies the spans entity extraction pipeline and routing (always-on).
## Then applies the metrics routing:
##   METRICS_EXTRACT=false (default): enrichment-only routing (Mode A)
##   METRICS_EXTRACT=true:            extraction+enrichment routing (Mode B)
##
## Usage:
##   make apply-openpipeline                        # Mode A (default, enrichment-only)
##   make apply-openpipeline METRICS_EXTRACT=true   # Mode B (extraction + enrichment)
apply-openpipeline:
	@echo "=== Applying OpenPipeline settings (METRICS_EXTRACT=$(METRICS_EXTRACT)) ==="
	dtctl apply -f openpipeline/k8s-topology-combined-pipeline.yaml --plain
	dtctl apply -f openpipeline/k8s-topology-routing.yaml --plain
	dtctl apply -f openpipeline/k8s-metrics-entity-enrichment.yaml --plain
	dtctl apply -f openpipeline/k8s-metrics-entity-extraction.yaml --plain
ifeq ($(METRICS_EXTRACT),true)
	@echo "--- Applying extraction routing (Mode B) ---"
	dtctl apply -f openpipeline/k8s-metrics-routing-extraction.yaml --plain
else
	@echo "--- Applying enrichment-only routing (Mode A) ---"
	dtctl apply -f openpipeline/k8s-metrics-routing.yaml --plain
endif
	@echo "--- Applying spans entity extraction (always-on) ---"
	dtctl apply -f openpipeline/k8s-spans-entity-extraction.yaml --plain
	dtctl apply -f openpipeline/k8s-spans-routing.yaml --plain
	@echo "=== Done ==="
