# sample-service

A deliberately boring Go service proving the paved road works: push code → scanned, SBOM-attested, keyless-signed image running in AKS behind enforced policy. Also the platform's integration test.

See [`CLAUDE.md`](CLAUDE.md).

## Proof: an unsigned image cannot be deployed

<!-- Record it once with demo/record.sh (or demo/rogue-deploy.tape) and commit the GIF. -->
<!-- ![Kyverno rejects an unsigned image, then admits the golden-path-signed one](demo/rogue-deploy.gif) -->

`demo/rogue-deploy.sh` is the Phase-5 argument, live: build this repo and push it
to ACR **by hand** (as a human, not the pipeline), try to run it — Kyverno denies
admission with an actionable message — then deploy the golden-path-signed digest
and watch it admitted and rolled out. Pushing to the registry is easy; *running*
in the cluster is reserved for images the pipeline built, scanned, and signed.

```bash
cd demo
./rogue-deploy.sh          # run the proof against your cluster
./record.sh                # capture it as demo/rogue-deploy.gif for the README / LinkedIn
```

The recorded GIF is the single highest-signal artifact for a portfolio: the whole
"secure-by-default is not optional" thesis in one short loop.
