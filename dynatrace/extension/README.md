# custom:dt-k8s-otel-topology 1.2.0 (signed)

Built from `extension/src/` with `dt extensions assemble` + `dt extensions sign`, using a
self-signed developer CA. `ca.pem` is that CA's public certificate; upload it once per tenant
(Credential Vault -> Public certificate, scope "Extension validation") before installing.

Why an extension and not plain OpenPipeline settings: tenant-authored pipelines are rejected
when a smartscapeNode processor creates a built-in type ("Must start with one of
['CUSTOM_, EXT_']", verified on bkw63642, 2026-10-07). Extension-bundled pipelines may.
