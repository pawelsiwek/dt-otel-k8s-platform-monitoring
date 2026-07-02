FROM gcr.io/distroless/static:nonroot
COPY dist/dtotelcol /dtotelcol
USER nonroot:nonroot
ENTRYPOINT ["/dtotelcol"]
