FROM gcr.io/distroless/static:nonroot
LABEL org.opencontainers.image.title="bluebox-otelcol-k8s" \
      org.opencontainers.image.description="Bluebox Kubernetes OTel Collector (POC, PRODUCT-18552) - based on trauter/dt-otel-k8s-platform-monitoring@e0fd52e" \
      org.opencontainers.image.source="https://github.com/trauter/dt-otel-k8s-platform-monitoring" \
      org.opencontainers.image.revision="e0fd52e" \
      org.opencontainers.image.licenses="Apache-2.0"
COPY LICENSE /licenses/LICENSE
COPY dist/bluebox-otelcol /bluebox-otelcol
USER nonroot:nonroot
ENTRYPOINT ["/bluebox-otelcol"]
