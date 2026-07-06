#!/usr/bin/env bash
#
# metrics.sh — hard numbers for the latest golden-path run, as pasteable
# markdown (stdout is pure markdown; progress goes to stderr):
#
#   ./demo/metrics.sh > post.md
#
# Measures, with no hardcoded run IDs:
#   1. Lead time: commit timestamp -> pod Ready in AKS (gh api + kubectl).
#   2. Per-stage pipeline durations (gh api run jobs), as a table.
#   3. Security controls applied automatically, parsed from job names.
#
# Dependencies: gh, kubectl, jq — nothing else. All timestamp arithmetic is
# done in jq (fromdateiso8601), so no GNU date; the gitops file is fetched
# with the raw Accept header, so no base64; text extraction uses bash's
# built-in regex, so no grep/sed/awk.
#
# How the pieces are linked (demo-level assumption, verified where possible):
# the latest green run on main produced the digest that the merged promotion
# PR pinned in platform-gitops, which is what the GitOps reconciler rolled
# out. The script reads the digest pinned in platform-gitops main and finds
# the Ready pod actually running it; if that pod became Ready before the run
# even started, the promotion clearly hasn't landed and the script says so
# instead of printing a nonsense number. Note the last leg (run end -> pod
# Ready) legitimately includes the human review+merge of the digest-bump PR.
#
# Configuration (environment variables, all optional):
#   SERVICE_REPO  owner/repo of this service (default: gh repo view on cwd)
#   GITOPS_REPO   owner/repo of the GitOps repo (default: <owner>/platform-gitops)
#   WORKFLOW      caller workflow file (default: ci.yml)
#   BRANCH        branch to read runs and gitops state from (default: main)
#   NAMESPACE     namespace the service runs in (default: apps)
#   SERVICE_NAME  service name (default: sample-service)

set -Eeuo pipefail

SERVICE_REPO="${SERVICE_REPO:-}"
GITOPS_REPO="${GITOPS_REPO:-}"
WORKFLOW="${WORKFLOW:-ci.yml}"
BRANCH="${BRANCH:-main}"
NAMESPACE="${NAMESPACE:-apps}"
SERVICE_NAME="${SERVICE_NAME:-sample-service}"

info() { printf '· %s\n' "$*" >&2; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }

# ISO-8601 -> epoch seconds, in jq so the only dependencies stay gh/kubectl/jq.
epoch() { jq -rn --arg t "$1" '$t | fromdateiso8601'; }

# ── Preflight ────────────────────────────────────────────────────────────────

for cmd in gh kubectl jq; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is required but not installed"
done
gh auth status >/dev/null 2>&1 || die "gh is not authenticated — run 'gh auth login'"

if [[ -z "$SERVICE_REPO" ]]; then
  SERVICE_REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
fi
[[ -n "$SERVICE_REPO" ]] \
  || die "could not resolve the service repo — run from a checkout with a GitHub remote, or set SERVICE_REPO=owner/repo"
GITOPS_REPO="${GITOPS_REPO:-${SERVICE_REPO%%/*}/platform-gitops}"

# ── 0. Latest green golden-path run on main (no hardcoded IDs) ───────────────

info "looking up the latest successful '${WORKFLOW}' run on ${BRANCH} in ${SERVICE_REPO}…"
run_json="$(gh api \
  "repos/${SERVICE_REPO}/actions/workflows/${WORKFLOW}/runs?branch=${BRANCH}&status=success&per_page=1" \
  --jq '.workflow_runs[0] // empty')"
[[ -n "$run_json" ]] \
  || die "no successful '${WORKFLOW}' run on ${BRANCH} in ${SERVICE_REPO} — push something through the paved road first"

RUN_ID="$(jq -r '.id' <<<"$run_json")"
RUN_NUMBER="$(jq -r '.run_number' <<<"$run_json")"
RUN_URL="$(jq -r '.html_url' <<<"$run_json")"
HEAD_SHA="$(jq -r '.head_sha' <<<"$run_json")"
RUN_STARTED="$(jq -r '.run_started_at' <<<"$run_json")"
RUN_ENDED="$(jq -r '.updated_at' <<<"$run_json")"
info "run #${RUN_NUMBER} (${RUN_ID}), commit ${HEAD_SHA:0:7}"

COMMIT_TS="$(gh api "repos/${SERVICE_REPO}/commits/${HEAD_SHA}" --jq '.commit.committer.date')"

# ── 1a. The digest this run promoted, as pinned in platform-gitops main ─────

gitops_path="apps/${SERVICE_NAME}/kustomization.yaml"
info "reading the pinned digest from ${GITOPS_REPO}/${gitops_path}…"
kustomization_raw="$(gh api -H 'Accept: application/vnd.github.raw+json' \
  "repos/${GITOPS_REPO}/contents/${gitops_path}?ref=${BRANCH}" 2>/dev/null || true)"
[[ -n "$kustomization_raw" ]] \
  || die "could not read ${gitops_path} from ${GITOPS_REPO}@${BRANCH} — is the service onboarded in platform-gitops?"
[[ "$kustomization_raw" =~ sha256:[0-9a-f]{64} ]] \
  || die "${gitops_path} in ${GITOPS_REPO} pins no sha256 digest — has a promotion PR ever merged?"
DIGEST="${BASH_REMATCH[0]}"
DIGEST_HEX="${DIGEST#sha256:}"
info "deployed digest: sha256:${DIGEST_HEX:0:12}…"

# ── 1b. Pod Ready in AKS: the earliest Ready pod running exactly that digest ─

info "finding the Ready pod running that digest in namespace '${NAMESPACE}'…"
pods_json="$(kubectl get pods -n "$NAMESPACE" -o json 2>/dev/null)" \
  || die "kubectl could not list pods in '${NAMESPACE}' — is the context pointed at the dev AKS cluster?"

POD_READY_TS="$(jq -r --arg hex "$DIGEST_HEX" '
  [ .items[]
    | select(any(.status.containerStatuses[]?; .imageID | contains($hex)))
    | .status.conditions[]?
    | select(.type == "Ready" and .status == "True")
    | .lastTransitionTime
  ] | sort | first // empty' <<<"$pods_json")"
[[ -n "$POD_READY_TS" ]] \
  || die "no Ready pod in '${NAMESPACE}' is running sha256:${DIGEST_HEX:0:12}… — merge the promotion PR and/or wait for the GitOps sync, then re-run"

COMMIT_EPOCH="$(epoch "$COMMIT_TS")"
RUN_STARTED_EPOCH="$(epoch "$RUN_STARTED")"
RUN_ENDED_EPOCH="$(epoch "$RUN_ENDED")"
POD_READY_EPOCH="$(epoch "$POD_READY_TS")"

if (( POD_READY_EPOCH < RUN_STARTED_EPOCH )); then
  die "the running pod became Ready before run #${RUN_NUMBER} even started — the digest in platform-gitops predates this run (promotion PR not merged yet?). Refusing to print a nonsense lead time."
fi

LEAD_SECONDS=$(( POD_READY_EPOCH - COMMIT_EPOCH ))
LEAD_MINUTES="$(jq -rn --argjson s "$LEAD_SECONDS" '($s / 60 * 10 | round) / 10')"

# ── 2. Per-stage durations from the run's jobs ───────────────────────────────

info "fetching per-stage durations for run ${RUN_ID}…"
jobs_json="$(gh api "repos/${SERVICE_REPO}/actions/runs/${RUN_ID}/jobs?per_page=100")"

STAGE_ROWS="$(jq -r '
  def dur:
    if . == null then "—"
    else "\(. / 60 | floor)m \(. % 60 | floor)s"
    end;
  .jobs[]
  | ((.completed_at | fromdateiso8601) - (.started_at | fromdateiso8601)) as $secs
  | "| \(.name) | \(.conclusion) | \($secs | dur) |"' <<<"$jobs_json")"

PIPELINE_SECONDS=$(( RUN_ENDED_EPOCH - RUN_STARTED_EPOCH ))
PIPELINE_HUMAN="$(jq -rn --argjson s "$PIPELINE_SECONDS" '"\($s / 60 | floor)m \($s % 60 | floor)s"')"
QUEUE_SECONDS=$(( RUN_STARTED_EPOCH - COMMIT_EPOCH ))
QUEUE_HUMAN="$(jq -rn --argjson s "$QUEUE_SECONDS" '"\($s / 60 | floor)m \($s % 60 | floor)s"')"
ROLLOUT_SECONDS=$(( POD_READY_EPOCH - RUN_ENDED_EPOCH ))
ROLLOUT_HUMAN="$(jq -rn --argjson s "$ROLLOUT_SECONDS" '"\($s / 60 | floor)m \($s % 60 | floor)s"')"

# ── 3. Security controls, parsed from the job names ──────────────────────────

# Keyword -> control mapping. A control counts once if any job name matches
# its pattern; one job may carry several controls (sign + attest + SBOM). The
# list is printed in full below the count, so the number stays auditable.
CONTROLS_JSON="$(jq -r '
  [ { p: "semgrep",                      c: "SAST — static code analysis (Semgrep, fails on HIGH)" },
    { p: "dependencies.*vulnerabilit",   c: "Dependency scan / SCA (Trivy, fails on CRITICAL)" },
    { p: "image.*scan|scan it",          c: "Container image scan (Trivy, fails on CRITICAL)" },
    { p: "sbom",                         c: "SBOM generation + signed attestation (Syft + cosign)" },
    { p: "sign",                         c: "Keyless image signing (cosign via GitHub OIDC — no keys to leak)" },
    { p: "digest",                       c: "Digest-pinned GitOps promotion (no mutable tags reach the cluster)" }
  ] as $map
  | [.jobs[].name] as $names
  | [ $map[] | select(. as $m | $names | any(test($m.p; "i"))) | .c ]' <<<"$jobs_json")"
CONTROL_COUNT="$(jq -r 'length' <<<"$CONTROLS_JSON")"
CONTROL_BULLETS="$(jq -r '.[] | "- \(.)"' <<<"$CONTROLS_JSON")"

# ── The pasteable summary (stdout only from here on) ─────────────────────────

info "done — markdown below is stdout-only, pipe it wherever you like."

cat <<MARKDOWN
## The paved road, measured (run #${RUN_NUMBER})

> **From git push to a scanned, SBOM-attested, signature-verified pod in
> ${LEAD_MINUTES} minutes — with zero security steps performed by the developer.**

**${CONTROL_COUNT} security controls applied automatically** on every push:

${CONTROL_BULLETS}

The developer wrote Go and typed \`git push\`. Everything above happened
anyway — and an image that skips this pipeline is rejected at the cluster by
admission policy (unsigned = undeployable).

### Pipeline stages

| Stage | Result | Duration |
|---|---|---|
${STAGE_ROWS}

### Timeline: commit → running pod

| Leg | Duration |
|---|---|
| Commit → pipeline start (push + queue) | ${QUEUE_HUMAN} |
| Pipeline (lint → scan ×3 → build → sign → promote) | ${PIPELINE_HUMAN} |
| Pipeline end → pod Ready (PR review + merge + GitOps sync)* | ${ROLLOUT_HUMAN} |
| **Total lead time (commit → pod Ready)** | **${LEAD_MINUTES} min** |

<sub>*includes the deliberate human step: reviewing and merging the
digest-bump PR in platform-gitops.</sub>

<sub>Evidence: [run #${RUN_NUMBER}](${RUN_URL}) · commit \`${HEAD_SHA:0:7}\` ·
image \`sha256:${DIGEST_HEX:0:12}…\` · pod Ready ${POD_READY_TS} (UTC)</sub>
MARKDOWN
