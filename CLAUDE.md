# CLAUDE.md — sample-service

## What this repo is

A deliberately boring Go HTTP service, instantiated from `platform-golden-path/templates/service-go`. Its job is to **prove the paved road works**: a developer with zero security knowledge pushes code and ends up with a scanned, SBOM-attested, keyless-signed image running in AKS behind enforced policies.

This repo is also the **test harness** for the platform. When the golden path or policies change, this repo's CI run is the integration test.

## Constraints

- Keep the application trivial (one `/healthz`, one `/hello` endpoint). Every line of business logic added here dilutes the demo. Resist making it interesting.
- The CI file must stay ~5 lines of `uses: <org>/platform-golden-path/.github/workflows/golden-path.yml@<sha>` plus inputs. If more YAML creeps in here, that is a smell that the golden path is leaking complexity onto developers — fix it upstream instead.
- No Kubernetes manifests here. Deployment lives in `platform-gitops` (updated automatically by the pipeline via digest-bump PR).
- For the Phase 5 demo, this repo gets one intentional "attack" branch: build an image locally, push it to ACR manually (unsigned), attempt to deploy — record the Kyverno rejection. Keep that script in `demo/`.

## Workflow for Claude Code

- Changes here are usually reactions to platform changes. Before editing, check the referenced SHA of the reusable workflow is current.
- Never add security tooling directly to this repo's workflow — that defeats the entire thesis.
