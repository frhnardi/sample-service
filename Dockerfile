# syntax=docker/dockerfile:1
#
# Multi-stage build for the golden-path Go service.
#   build stage   — full Go toolchain, compiles a static binary
#   runtime stage — distroless static + nonroot: no shell, no package manager,
#                   no libc beyond what a static binary needs, runs as UID 65532
#
# The image is scanned by Trivy (fail on CRITICAL) and signed by cosign in the
# reusable workflow; keeping the runtime tiny keeps that surface tiny.

# ── Build stage ──────────────────────────────────────────────────────────────
FROM golang:1.22-bookworm AS build

WORKDIR /src

# Download modules in their own layer so source-only changes reuse the cache.
COPY go.mod ./
RUN go mod download

COPY . .

# Static, reproducible, stripped binary:
#   CGO_ENABLED=0  — no libc dependency, runs on distroless/static
#   -trimpath      — strip local filesystem paths from the binary
#   -ldflags -s -w — drop the symbol table and DWARF debug info
ENV CGO_ENABLED=0 GOOS=linux
RUN go build -trimpath -ldflags="-s -w" -o /out/service .

# ── Runtime stage ────────────────────────────────────────────────────────────
# Pinning to :nonroot gives us a non-root default user (UID 65532) and no shell,
# so there is nothing for an attacker to exec into. Kubernetes liveness probes
# hit /healthz directly, so no in-image HEALTHCHECK (there is no shell to run one).
FROM gcr.io/distroless/static-debian12:nonroot AS runtime

# Informational: the service listens here (override with PORT).
EXPOSE 8080

# Belt-and-suspenders: the base already defaults to nonroot; state it anyway.
USER nonroot:nonroot

COPY --from=build /out/service /service

ENTRYPOINT ["/service"]
