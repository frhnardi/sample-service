#!/usr/bin/env bash
#
# record.sh — capture the Phase-5 proof (rogue-deploy.sh) as a GIF for the
# README and LinkedIn. The demo itself is the argument; a recording is how a
# recruiter sees it in 20 seconds without a cluster.
#
# Produces demo/rogue-deploy.gif from a REAL run (nothing staged): an unsigned
# image pushed by hand is rejected by Kyverno with the actionable message, then
# the golden-path-signed digest is admitted and rolls out.
#
# Prereqs (same cluster/az access as rogue-deploy.sh) plus:
#   - asciinema   https://asciinema.org
#   - agg         https://github.com/asciinema/agg   (cast -> gif)
#
# Usage:  ./record.sh          # record + convert
#         SPEED=3 ./record.sh  # faster playback
set -Eeuo pipefail
cd "$(dirname "$0")"

CAST="${CAST:-rogue-deploy.cast}"
GIF="${GIF:-rogue-deploy.gif}"
SPEED="${SPEED:-2}"

for tool in asciinema agg; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: '$tool' not found. Install it first:"
    echo "  asciinema: https://docs.asciinema.org/getting-started/"
    echo "  agg:       https://github.com/asciinema/agg#installation"
    exit 1
  }
done

echo "▶ Recording ./rogue-deploy.sh (a real run against your cluster) ..."
# --idle-time-limit collapses the long waits (image build, rollout) so the cast
# stays watchable; the actual denial/admission moments are preserved.
asciinema rec --overwrite --idle-time-limit 2 --command "./rogue-deploy.sh" "$CAST"

echo "▶ Converting $CAST -> $GIF (speed x${SPEED}) ..."
agg --speed "$SPEED" --idle-time-limit 2 --font-size 20 --theme dracula "$CAST" "$GIF"

echo "✔ Wrote $(pwd)/$GIF"
echo "  Embed it at the top of ../README.md:  ![proof](demo/${GIF})"
echo "  and drop the same GIF into your LinkedIn post — it is the whole thesis in one loop."
