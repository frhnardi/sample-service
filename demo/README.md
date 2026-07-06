# Phase 5 demo — the rogue deploy

One script, one thesis: **the registry will take anything; the cluster only
runs what the paved road built.** A human with push rights can shove an
unsigned image into ACR in thirty seconds — and it is still undeployable,
because trust is anchored at cluster admission, not at the registry ACL.

```bash
./rogue-deploy.sh
```

Acceptance behavior: the run produces **exactly one rejection** (the unsigned
image) and **exactly one successful admission** (the signed digest), then
cleans up after itself. It is safe to re-run; it pre-cleans leftovers from a
previous, possibly crashed, run.

## What each step proves

| Step | What happens | What it proves | ADR / policy exercised |
|---|---|---|---|
| 1 | Build this repo locally, `az acr login` **as a human**, push `:rogue` | Push access ≠ run access. The registry is not the trust boundary — a hijacked laptop or a well-meaning shortcut can always reach it | Threat model behind [ADR-0005](../../platform-infra/docs/adr/0005-cosign-keyless-signing.md); the deliberate limit of [ADR-0003](../../platform-infra/docs/adr/0003-zero-static-credentials-oidc.md) (OIDC covers the pipeline; humans retain AcrPush) |
| 2 | `kubectl apply` a fully baseline-compliant Deployment referencing the unsigned image in `apps` | An image with no provenance does not run, even when the manifest is otherwise perfect | `verify-image-signature` (and `verify-sbom-attestation`) in platform-gitops, Enforced via the `paved-road.platform/tier=app` namespace label — the [ADR-0005](../../platform-infra/docs/adr/0005-cosign-keyless-signing.md) keystone, enforced by Kyverno per [ADR-0004](../../platform-infra/docs/adr/0004-kyverno-over-gatekeeper.md) |
| 3 | Capture and pretty-print the admission denial | The guardrail points at the road: the denial names what was blocked, why it matters, and how to ship correctly | The denial-message contract in platform-gitops [`docs/denial-messages.md`](../../platform-gitops/docs/denial-messages.md) |
| 4 | Apply the golden-path-signed **digest** of the same service; watch the rollout | The gate discriminates on *provenance*, not code: same source, same registry — only the builder identity differs. Also shows digest-pinning end to end (`mutateDigest: false`, so manifests must carry the digest themselves) | Keyless identity contract of [ADR-0005](../../platform-infra/docs/adr/0005-cosign-keyless-signing.md): Fulcio subject = the reusable workflow `golden-path.yml@refs/heads/main` |
| 5 | Cleanup | The demo leaves no unsigned artifact behind | — |

## Why the demo manifests look "overdressed"

The `apps` namespace also Enforces five baseline policies
(`disallow-privileged`, `disallow-latest-tag`, `require-resource-limits`,
`require-run-as-nonroot`, `drop-all-capabilities`, `require-readonly-rootfs`).
Both demo Deployments deliberately satisfy all of them — non-root UID 65532,
dropped capabilities, read-only rootfs, CPU/memory limits, explicit
tag/digest — so the **only** policy that can reject the rogue Deployment is
the supply-chain signature check. That is what makes "exactly one rejection"
a meaningful claim instead of an accident.

One denial may quote *both* supply-chain policies (`verify-image-signature`
and `verify-sbom-attestation`): a rogue image lacks the signature **and** the
SBOM attestation, and both Enforce rules read the same shared verification
annotation. It is still one API request and one rejection.

## Prerequisites

- `docker`, `az` (logged in — `az login` — with AcrPush on the registry),
  `kubectl` pointed at the dev AKS cluster.
- platform-gitops synced to the cluster (the `apps` namespace exists with the
  `paved-road.platform/tier=app` label, and the `verify-image-signature`
  ClusterPolicy is installed). The preflight verifies all of this and refuses
  to run a demo that would prove nothing.
- **The golden path must have run green at least once** — step 4 needs a
  signed digest to exist. Resolution order:
  1. `SIGNED_DIGEST=sha256:…` environment variable (copy it from the
     golden-path run summary or the digest-bump PR), else
  2. the digest pinned in
     `platform-gitops/apps/sample-service/kustomization.yaml` (a local
     checkout, `GITOPS_DIR` to override the path) — the same file the
     pipeline's digest-bump PR updates.

Other knobs: `ACR_NAME` (defaults to the first registry `az acr list`
returns), `NAMESPACE` (defaults to `apps`), `ROLLOUT_TIMEOUT` (defaults to
`180s`).

## Cleanup semantics

- Both demo Deployments are deleted — on success, on failure, and on the next
  run's preflight (re-runnability).
- The `:rogue` tag is **untagged, never manifest-deleted**: `az acr repository
  untag` removes only the tag pointer. A manifest delete could, if a local
  build ever reproduced the pipeline's digest, take the signed artifact down
  with it.
- The local `:rogue` docker tag is removed.

## metrics.sh — numbers for the write-up

```bash
./metrics.sh > post.md   # stdout is pure markdown; progress goes to stderr
```

For the **latest successful** golden-path run on `main` (resolved via the API
— no hardcoded run IDs), it measures and prints a pasteable markdown summary:

1. **Lead time** — commit timestamp → pod Ready in AKS. The link between the
   two is the image digest: the script reads the digest pinned in
   `platform-gitops/apps/sample-service/kustomization.yaml` on `main` and
   finds the earliest Ready pod actually running it. If that pod predates the
   run (promotion PR not merged yet), it refuses to print a nonsense number.
2. **Pipeline stage durations** — one table row per job of the run.
3. **Security-control count** — parsed from the run's job names against a
   keyword map (SAST, SCA, image scan, SBOM attestation, keyless signing,
   digest-pinned promotion); the bullets are printed with the count so the
   number stays auditable.

Dependencies: `gh` (authenticated), `kubectl` (pointed at the cluster), `jq`
— nothing else; timestamp math happens in jq, not GNU date. Same knobs as
above plus `SERVICE_REPO`, `GITOPS_REPO`, `WORKFLOW`, `BRANCH`. The
run-end → pod-Ready leg legitimately includes the human review+merge of the
digest-bump PR — the summary footnotes it rather than hiding it.

## Denial-path note

Kyverno's policies match `Pod` resources; with rule auto-generation the block
usually lands directly on the `kubectl apply` of the Deployment. If a cluster
blocks at Pod level instead, the script detects the admitted-but-sterile
Deployment, scrapes the denial from the ReplicaSet's `FailedCreate` event, and
counts that as the one rejection — either way the message printed is the
policy's own product copy.
