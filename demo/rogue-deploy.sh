#!/usr/bin/env bash
#
# rogue-deploy.sh — Phase 5 demo: a human bypasses the paved road, and the
# cluster says no.
#
#   1. Build this very repo locally and push it to ACR as :rogue — as *you*,
#      a human with `az acr login`, not the pipeline. The registry accepts it.
#   2. Try to deploy that unsigned image into the `apps` namespace.
#   3. Kyverno denies admission; the denial is captured and pretty-printed.
#   4. Deploy the legitimate, golden-path-signed digest of the same service
#      and watch it admitted and rolled out.
#
# The point: pushing to the registry is easy; *running* in the cluster is
# reserved for images the golden-path pipeline built, scanned, and signed
# keyless (ADR-0005, enforced by Kyverno per ADR-0004). See demo/README.md.
#
# Re-runnable: pre-cleans leftovers from a previous run, cleans up after
# itself on exit (demo deployments deleted, :rogue tag removed from ACR).
#
# Configuration (environment variables, all optional):
#   ACR_NAME        ACR registry name (default: first registry `az acr list` returns)
#   SIGNED_DIGEST   sha256:… digest of a golden-path-signed image (default:
#                   read from platform-gitops/apps/sample-service/kustomization.yaml)
#   GITOPS_DIR      local checkout of platform-gitops (default: ../../platform-gitops)
#   NAMESPACE       target namespace (default: apps — must carry the
#                   paved-road.platform/tier=app label for policies to Enforce)
#   ROLLOUT_TIMEOUT how long to wait for the signed rollout (default: 180s)

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"

ACR_NAME="${ACR_NAME:-}"
SIGNED_DIGEST="${SIGNED_DIGEST:-}"
GITOPS_DIR="${GITOPS_DIR:-${REPO_ROOT}/../platform-gitops}"
NAMESPACE="${NAMESPACE:-apps}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"

SERVICE_NAME="sample-service"
ROGUE_TAG="rogue"
ROGUE_DEPLOY="sample-service-demo-rogue"
SIGNED_DEPLOY="sample-service-demo-signed"
ROGUE_IMAGE="" # set after ACR_NAME is resolved

REJECTIONS=0
ADMISSIONS=0
PUSHED_ROGUE=0
CLEANED=0

# ── Narration helpers ────────────────────────────────────────────────────────

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  BOLD="$(tput bold)" DIM="$(tput dim)" RED="$(tput setaf 1)"
  GREEN="$(tput setaf 2)" RESET="$(tput sgr0)"
else
  BOLD="" DIM="" RED="" GREEN="" RESET=""
fi

say()    { printf '%s\n' "$*"; }
note()   { printf '%s%s%s\n' "$DIM" "$*" "$RESET"; }
ok()     { printf '%s✓ %s%s\n' "$GREEN" "$*" "$RESET"; }
banner() { printf '\n%s━━━ %s ━━━%s\n\n' "$BOLD" "$*" "$RESET"; }
die()    { printf '%s✗ %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }

# Pretty-print a captured admission denial inside a red box, so the audience
# reads the policy's product copy instead of scrolling past a stack trace.
print_denial() {
  local file="$1" line
  printf '\n%s┌── Kyverno admission denial ────────────────────────────────────%s\n' "$RED" "$RESET"
  while IFS= read -r line; do
    printf '%s│%s  %s\n' "$RED" "$RESET" "$line"
  done <"$file"
  printf '%s└────────────────────────────────────────────────────────────────%s\n\n' "$RED" "$RESET"
}

# ── Manifests ────────────────────────────────────────────────────────────────

# Both demo deployments are deliberately compliant with every *baseline*
# policy enforced in the apps namespace (non-root, drop-ALL capabilities,
# read-only rootfs, resource limits, explicit tag/digest) so that the ONLY
# thing that can reject the rogue one is the supply-chain signature check —
# exactly one rejection, and it is the one this demo is about.
render_deployment() {
  local name="$1" image="$2" flavor="$3"
  cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${name}
    paved-road.platform/demo: rogue-deploy
    paved-road.platform/flavor: ${flavor}
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: ${name}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${name}
        paved-road.platform/demo: rogue-deploy
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          image: ${image}
          ports:
            - containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
EOF
}

# ── Cleanup (runs on every exit; also invoked as the explicit final step) ────

cleanup() {
  [[ "$CLEANED" -eq 1 ]] && return 0
  CLEANED=1
  kubectl -n "$NAMESPACE" delete deployment "$ROGUE_DEPLOY" "$SIGNED_DEPLOY" \
    --ignore-not-found >/dev/null 2>&1 || true
  if [[ "$PUSHED_ROGUE" -eq 1 ]]; then
    # untag, never delete: `az acr repository delete --image` removes the whole
    # manifest, and if the local build ever reproduced the pipeline's digest
    # that would take the signed artifact down with it. Untagging only removes
    # the :rogue pointer.
    az acr repository untag --name "$ACR_NAME" \
      --image "${SERVICE_NAME}:${ROGUE_TAG}" >/dev/null 2>&1 || true
    docker rmi "$ROGUE_IMAGE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ── Preflight ────────────────────────────────────────────────────────────────

preflight() {
  banner "Preflight — is everything this demo needs actually here?"

  local cmd
  for cmd in docker az kubectl awk grep; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not installed"
  done

  az account show >/dev/null 2>&1 \
    || die "not logged in to Azure — run 'az login' first (the demo pushes as YOU, a human)"

  if [[ -z "$ACR_NAME" ]]; then
    ACR_NAME="$(az acr list --query '[0].name' --output tsv 2>/dev/null || true)"
  fi
  [[ -n "$ACR_NAME" ]] \
    || die "could not resolve an ACR registry — set ACR_NAME=<registry name> and re-run"
  ROGUE_IMAGE="${ACR_NAME}.azurecr.io/${SERVICE_NAME}:${ROGUE_TAG}"

  kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
    || die "namespace '$NAMESPACE' not found — is kubectl pointed at the dev AKS cluster?"

  local tier
  tier="$(kubectl get namespace "$NAMESPACE" \
    -o jsonpath='{.metadata.labels.paved-road\.platform/tier}' 2>/dev/null || true)"
  [[ "$tier" == "app" ]] \
    || die "namespace '$NAMESPACE' lacks the paved-road.platform/tier=app label — policies would not Enforce there, and the demo would prove nothing"

  kubectl get clusterpolicy verify-image-signature >/dev/null 2>&1 \
    || die "ClusterPolicy verify-image-signature not installed — sync platform-gitops first"

  resolve_signed_digest

  ok "az logged in, registry: ${ACR_NAME}.azurecr.io"
  ok "cluster reachable, namespace '${NAMESPACE}' is policy-enforced (tier=app)"
  ok "signed digest to promote later: ${SIGNED_DIGEST}"

  # Re-runnable: remove leftovers a previous, possibly crashed, run left behind.
  kubectl -n "$NAMESPACE" delete deployment "$ROGUE_DEPLOY" "$SIGNED_DEPLOY" \
    --ignore-not-found >/dev/null 2>&1 || true
}

# The "legitimate" image is whatever digest the golden path last promoted.
# Resolution order: SIGNED_DIGEST env var, then the digest pinned in the
# platform-gitops kustomization (the same file the pipeline's digest-bump PR
# updates — the single source of deployed truth).
resolve_signed_digest() {
  if [[ -z "$SIGNED_DIGEST" ]]; then
    local kustomization="${GITOPS_DIR}/apps/${SERVICE_NAME}/kustomization.yaml"
    if [[ -f "$kustomization" ]]; then
      SIGNED_DIGEST="$(awk '$1 == "digest:" { print $2; exit }' "$kustomization")"
      note "signed digest read from ${kustomization}"
    fi
  fi
  [[ "$SIGNED_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || die "no signed digest available — either pass SIGNED_DIGEST=sha256:… (from a green golden-path run) or make sure ${GITOPS_DIR}/apps/${SERVICE_NAME}/kustomization.yaml exists and pins one"
}

# ── Step 1: build locally, push manually — the human bypass ─────────────────

build_and_push_rogue() {
  banner "Step 1 — Build the same code locally and push it straight to ACR"

  say "This is the exact source the golden path builds — but built on a laptop,"
  say "by a human, with none of the pipeline's scanning, SBOM, or signing."
  say ""

  docker build --tag "$ROGUE_IMAGE" "$REPO_ROOT"

  say ""
  say "Now the bypass itself: 'az acr login' authenticates ME, a human with"
  say "push rights — no OIDC federation, no pipeline identity. The registry"
  say "has no opinion about provenance; it will take anything (that is by"
  say "design — trust is anchored at admission, not at the registry ACL)."
  say ""

  az acr login --name "$ACR_NAME"
  docker push "$ROGUE_IMAGE"
  PUSHED_ROGUE=1

  local rogue_digest
  rogue_digest="$(docker inspect --format '{{index .RepoDigests 0}}' "$ROGUE_IMAGE" 2>/dev/null | cut -d'@' -f2 || true)"
  say ""
  ok "unsigned image accepted by the registry: ${ROGUE_IMAGE}"
  [[ -n "$rogue_digest" ]] && note "  digest: ${rogue_digest} — no cosign signature, no SBOM attestation"
}

# ── Step 2 + 3: attempt the rogue deploy, capture the denial ─────────────────

attempt_rogue_deploy() {
  banner "Step 2 — Deploy the unsigned image to the '${NAMESPACE}' namespace"

  say "kubectl apply of a perfectly well-formed Deployment: non-root, read-only"
  say "rootfs, dropped capabilities, resource limits — it passes every baseline"
  say "policy. The only thing wrong with it is that nobody can prove where the"
  say "image came from."
  say ""

  local manifest errfile
  manifest="$(mktemp)"
  errfile="$(mktemp)"
  render_deployment "$ROGUE_DEPLOY" "$ROGUE_IMAGE" rogue >"$manifest"

  if kubectl apply -f "$manifest" >/dev/null 2>"$errfile"; then
    # Kyverno blocked at Pod rather than Deployment level: the Deployment
    # object was admitted, so the denial surfaces as a FailedCreate event on
    # the ReplicaSet. Scrape it, then remove the husk of a Deployment.
    note "Deployment object admitted; the block lands at Pod creation — reading ReplicaSet events…"
    local msg="" attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
      [[ "$attempt" -gt 1 ]] && sleep 5
      msg="$(kubectl -n "$NAMESPACE" get events \
        --field-selector reason=FailedCreate \
        -o go-template='{{range .items}}{{.message}}{{"\n"}}{{end}}' 2>/dev/null \
        | grep -m1 "$ROGUE_DEPLOY" || true)"
      [[ -n "$msg" ]] && break
    done
    [[ -n "$msg" ]] || die "expected Kyverno to deny the unsigned pod, but no denial appeared within 60s — check 'kubectl -n ${NAMESPACE} get events'"
    printf '%s\n' "$msg" >"$errfile"
    kubectl -n "$NAMESPACE" delete deployment "$ROGUE_DEPLOY" --ignore-not-found >/dev/null
  fi

  banner "Step 3 — The cluster's answer"
  grep -q 'verify-image-signature' "$errfile" || {
    print_denial "$errfile"
    die "the request was denied, but not by verify-image-signature — the demo manifest has drifted from the baseline policies; fix render_deployment"
  }
  REJECTIONS=$((REJECTIONS + 1))
  print_denial "$errfile"

  say "One API request, one rejection. Note the copy: it names what was blocked,"
  say "why unsigned images are dangerous, and points at the paved road — the"
  say "guardrail points at the road (docs/denial-messages.md in platform-gitops)."
  ok "unsigned image REJECTED at admission"

  rm -f "$manifest" "$errfile"
}

# ── Step 4: the same service, through the paved road ─────────────────────────

deploy_signed() {
  banner "Step 4 — Deploy the golden-path-signed digest of the same service"

  local image="${ACR_NAME}.azurecr.io/${SERVICE_NAME}@${SIGNED_DIGEST}"
  say "Same source, same registry, same namespace, same manifest shape — the"
  say "only difference is provenance: this digest was built, scanned, and"
  say "keyless-signed by the golden-path workflow identity."
  say ""
  note "image: ${image}"
  say ""

  local manifest errfile
  manifest="$(mktemp)"
  errfile="$(mktemp)"
  render_deployment "$SIGNED_DEPLOY" "$image" signed >"$manifest"

  if ! kubectl apply -f "$manifest" 2>"$errfile"; then
    print_denial "$errfile"
    die "the signed image was rejected — is SIGNED_DIGEST really from a green golden-path run on main?"
  fi

  kubectl -n "$NAMESPACE" rollout status deployment "$SIGNED_DEPLOY" --timeout="$ROLLOUT_TIMEOUT" \
    || die "admitted but never became Ready — check 'kubectl -n ${NAMESPACE} describe deploy ${SIGNED_DEPLOY}'"
  ADMISSIONS=$((ADMISSIONS + 1))

  # Show Kyverno's own receipt: the verify-images annotation on the live pod.
  local pod verdict
  pod="$(kubectl -n "$NAMESPACE" get pods \
    -l "app.kubernetes.io/name=${SIGNED_DEPLOY}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$pod" ]]; then
    verdict="$(kubectl -n "$NAMESPACE" get pod "$pod" \
      -o jsonpath='{.metadata.annotations.kyverno\.io/verify-images}' 2>/dev/null || true)"
    [[ -n "$verdict" ]] && note "Kyverno's verification receipt on ${pod}: ${verdict}"
  fi

  ok "signed image ADMITTED and rolled out"
  rm -f "$manifest" "$errfile"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  banner "Rogue deploy — proving the paved road is the only road"

  preflight
  build_and_push_rogue
  attempt_rogue_deploy
  deploy_signed

  banner "Step 5 — Clean up (leave the cluster and registry as we found them)"
  cleanup
  ok "demo deployments deleted, :${ROGUE_TAG} tag removed from ACR"

  banner "Scoreboard"
  say "  rejections (unsigned image): ${REJECTIONS}"
  say "  admissions (signed digest):  ${ADMISSIONS}"
  say ""
  [[ "$REJECTIONS" -eq 1 && "$ADMISSIONS" -eq 1 ]] \
    || die "expected exactly one rejection and one admission — got ${REJECTIONS}/${ADMISSIONS}"
  ok "exactly one rejection, exactly one admission — the paved road holds"
}

main "$@"
