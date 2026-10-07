FROM gcr.io/distroless/static:nonroot
ARG REVISION=unknown
LABEL org.opencontainers.image.title="bluebox-otelcol-k8s" \
      org.opencontainers.image.description="Bluebox Kubernetes OTel Collector (POC, PRODUCT-18552), fork of trauter/dt-otel-k8s-platform-monitoring" \
      org.opencontainers.image.source="https://github.com/pawelsiwek/dt-otel-k8s-platform-monitoring" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.licenses="Apache-2.0"
COPY LICENSE /licenses/LICENSE
COPY dist/bluebox-otelcol /bluebox-otelcol
USER nonroot:nonroot
ENTRYPOINT ["/bluebox-otelcol"]
