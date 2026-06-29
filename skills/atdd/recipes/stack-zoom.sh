#!/usr/bin/env bash
# stack-zoom.sh — the end-of-task Stack zoom-in gate (Phase C / C2).
#
# The DETERMINISTIC half of the self-maintaining Stack. After an agent has
# DECLARED the boxes it touched (layer/interface/process add|edit + layer link
# --issue — the judgment half, done by the agent per STACK_USAGE.md), this recipe
# VERIFIES the touched scope against today's code and, only on a clean verify,
# writes a completion marker. The marker is the proof the zoom-in ran; the Stop
# hook (hooks/stack-zoom-stop.sh) and the coordination gate key off it.
#
# It does NOT decide which boxes to declare — it cannot know what SHOULD exist.
# It guarantees "what you declared verifies clean", not "you declared enough";
# thoroughness is the markdown contract's job (STACK_USAGE.md).
#
# Usage:
#   stack-zoom.sh [--project <slug>] --marker <file> [--layer <layer-slug>]
#     --project  atdd project slug (defaults to $ATDD_PROJECT; required either way)
#     --marker   absolute path of the completion marker to write on a clean verify
#     --layer    restrict `stack verify` to this layer's subtree (default: all)
#
# stdout: the `atdd stack verify` JSON (kept for the caller/log).
# exit:   0 = verify clean, marker written · 3 = BLOCKED (drift/blocked; no marker)
#         · 2 = hard error (bad args / atdd missing).
set -uo pipefail

log() { printf '[stack-zoom] %s\n' "$*" >&2; }
die() { printf '[stack-zoom] ERROR: %s\n' "$*" >&2; exit 2; }

PROJECT=""; MARKER=""; LAYER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --marker)  MARKER="${2:-}";  shift 2 ;;
    --layer)   LAYER="${2:-}";   shift 2 ;;
    *) die "unknown arg: $1 (usage: stack-zoom.sh [--project <slug>] --marker <file> [--layer <slug>])" ;;
  esac
done
[[ -n "$PROJECT" ]] || PROJECT="${ATDD_PROJECT:-}"
[[ -n "$PROJECT" ]] || die "no project: pass --project <slug> or set \$ATDD_PROJECT"
[[ -n "$MARKER"  ]] || die "--marker <file> is required"
command -v atdd >/dev/null 2>&1 || die "atdd not found on PATH (ensure-atdd.sh runs at bootstrap)"

if [[ -n "$LAYER" ]]; then
  OUT="$(atdd --project "$PROJECT" stack verify --layer "$LAYER")"; rc=$?
else
  OUT="$(atdd --project "$PROJECT" stack verify)"; rc=$?
fi
printf '%s\n' "$OUT"

if [[ $rc -ne 0 ]]; then
  {
    echo "[stack-zoom] ───── STACK ZOOM-IN: BLOCKED ─────────────────────────────────"
    echo "[stack-zoom] \`stack verify\` is not clean (drift, or a #symbol anchor blocked"
    echo "[stack-zoom] for want of a registered LSP). Fix the anchor(s) you just declared"
    echo "[stack-zoom] (typo'd path / moved symbol) or register the LSP, then re-run. The"
    echo "[stack-zoom] completion marker is NOT written until verify is clean."
    echo "[stack-zoom] ────────────────────────────────────────────────────────────────"
  } >&2
  exit 3
fi

mkdir -p "$(dirname "$MARKER")"
printf '{"zoom":"ok","project":"%s","layer":"%s","at":"%s"}\n' \
  "$PROJECT" "${LAYER:-*}" "$(date -Iseconds 2>/dev/null || echo unknown)" > "$MARKER"
log "zoom-in clean — wrote marker ${MARKER}"
exit 0
