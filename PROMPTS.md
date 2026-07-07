# Claude Code Prompts — sample-service (Phases 2 & 5)

This repo is instantiated from the template ("Use this template" on platform-golden-path/templates/service-go), so most code arrives pre-built. These prompts cover wiring, the demo, and metrics.

---

## Prompt 5.1 — Wire the paved road

```
Read CLAUDE.md first. This repo was instantiated from the service-go template. Verify:
1. ci.yml references frhnardi/platform-golden-path/.github/workflows/golden-path.yml pinned to the current main SHA — update the SHA if stale.
2. The caller workflow is under 15 lines. If anything beyond checkout+uses+inputs exists, list it as upstream leakage; do not fix it here.
3. go test passes, docker build succeeds locally.
Then rename the service identity to "sample-service" everywhere (module name, image name input).
Acceptance: a push to main triggers the golden path end-to-end. Report the run URL, the image digest, and confirm a digest-bump PR appeared on platform-gitops.
```

## Prompt 5.2 — The attack demo (Phase 5)

```
Create demo/rogue-deploy.sh, a narrated script for the Phase 5 demo:
1. Build the same code locally, tag as <acr>/sample-service:rogue, push directly to ACR (az acr login as me — the point is a human bypassing the pipeline).
2. kubectl apply a deployment in the apps namespace referencing that unsigned image.
3. Capture and pretty-print the Kyverno admission denial message.
4. Then apply the legitimate signed digest and show it admitted.
Add demo/README.md explaining what each step proves and which ADR/policy it exercises. The script must be re-runnable and clean up after itself.
Acceptance: shellcheck clean; running it produces exactly one rejection and one successful admission.
```

## Prompt 5.3 — Metrics for the write-up

```
Create demo/metrics.sh that measures, for the latest golden-path run:
1. Lead time: commit timestamp -> pod Ready in AKS (gh api + kubectl).
2. Pipeline stage durations (gh api run jobs), printed as a table.
3. Count of security controls applied automatically (parse job names).
Output a markdown summary I can paste into the LinkedIn post: "From git push to a scanned, SBOM-attested, signature-verified pod in X minutes, with zero security steps performed by the developer."
Acceptance: script runs with only gh + kubectl + jq; no hardcoded run IDs.
```
