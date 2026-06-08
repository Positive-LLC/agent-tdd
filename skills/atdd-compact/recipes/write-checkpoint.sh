#!/usr/bin/env bash
# write-checkpoint.sh — persist the compact-handoff brief and post it to the
# wave's in-flight work-items in the local atdd store.
#
# Usage:  write-checkpoint.sh <root-id> <handoff-content-file>
#
# Effects:
#   1. Copies the brief to .agent-tdd/<root-id>/wave-<N>/handoff.md (durable;
#      the load-bearing artifact — survives the prior Root's death).
#   2. Posts the brief as a comment on every work-item with labels
#      agent-tdd:active-wave-<N> AND agent-tdd:root-<id>.
#
# (Phase 1: there are no PRs in the inner flow, so the old impl-PR comment step
# is gone. The deliverable is a branch + green flag on the work-item.)
#
# Progress messages → stderr. Stdout is empty on success.

set -euo pipefail

log() { printf '[write-checkpoint] %s\n' "$*" >&2; }
die() { printf '[write-checkpoint] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: $0 <root-id> <handoff-content-file>"
ROOT_ID="$1"
BRIEF="$2"

[[ "$ROOT_ID" =~ ^root-[a-z0-9-]+$ ]] || die "bad root-id: ${ROOT_ID}"
[[ -f "$BRIEF" ]] || die "brief file not found: ${BRIEF}"
[[ -s "$BRIEF" ]] || die "brief file is empty: ${BRIEF}"

command -v atdd >/dev/null 2>&1 || die "atdd CLI not found on PATH"
command -v jq   >/dev/null 2>&1 || die "jq not found on PATH"

# --- resolve repo root + state dir + wave ---
REPO_ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)" \
  || die "not inside a git repo"
STATE_DIR="${REPO_ROOT}/.agent-tdd/${ROOT_ID}"
META="${STATE_DIR}/meta.json"
[[ -f "$META" ]] || die "meta.json not found at ${META}"

WAVE="$(jq -r '.current_wave' "$META")"
[[ "$WAVE" =~ ^[0-9]+$ ]] && (( WAVE > 0 )) \
  || die "current_wave is not a positive integer (got: ${WAVE})"

WAVE_DIR="${STATE_DIR}/wave-${WAVE}"
[[ -d "$WAVE_DIR" ]] || die "wave directory missing: ${WAVE_DIR}"

# --- 1. write durable handoff.md ---
HANDOFF="${WAVE_DIR}/handoff.md"
log "writing ${HANDOFF}"
cp "$BRIEF" "$HANDOFF"

# --- 2. enumerate active wave work-items (by label) ---
log "listing active wave work-items (wave-${WAVE}, ${ROOT_ID})"
ISSUES_JSON="$(atdd issue list \
  --label "agent-tdd:active-wave-${WAVE}" \
  --label "agent-tdd:root-${ROOT_ID}")" || die "atdd issue list failed"

REFS=()
while IFS= read -r r; do
  [[ -n "$r" ]] && REFS+=("$r")
done < <(jq -r '.[].ref' <<<"$ISSUES_JSON")

if [[ ${#REFS[@]} -eq 0 ]]; then
  log "warning: no work-items with labels agent-tdd:active-wave-${WAVE} + agent-tdd:root-${ROOT_ID}"
  log "(handoff.md was still written; the new Root reads it from disk)"
  exit 0
fi
log "found ${#REFS[@]} active wave work-item(s): ${REFS[*]}"

# --- 3. comment the brief on every active wave work-item ---
FAILS=0
for r in "${REFS[@]}"; do
  if atdd comment add "$r" --body-file "$BRIEF" >/dev/null 2>&1; then
    log "  posted brief to ${r}"
  else
    log "  WARN: failed to post brief to ${r}"
    FAILS=$((FAILS + 1))
  fi
done

log "summary: ${#REFS[@]} comments (${FAILS} failed); durable copy: ${HANDOFF}"

if [[ "$FAILS" -eq "${#REFS[@]}" ]] && [[ ${#REFS[@]} -gt 0 ]]; then
  die "all comments failed — check the atdd daemon"
fi

exit 0
