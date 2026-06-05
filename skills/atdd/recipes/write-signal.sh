#!/usr/bin/env bash
# write-signal.sh — emit a Root's orchestration liveness/escalation signal.
#
# This is the Root-layer half of the Notes-Agent orchestration channel. It is a
# NO-OP unless the Root was spawned in orchestration mode (AGENT_TDD_ORCHESTRATED=1
# and AGENT_TDD_SIGNAL_PATH set). A human-driven Root (manual /atdd or
# /atdd-from-issue) never sets these, so this recipe does nothing and the Root
# behaves exactly as before — the entire orchestration channel is environment-gated.
#
# The signal file lives in the ORCHESTRATOR's state dir (AGENT_TDD_SIGNAL_PATH is
# an absolute path the orchestrator assigned at spawn time), NOT in the Root's own
# repo — so the orchestrator always reads it locally and never needs to know which
# root-id the Root claimed. GitHub stays the source of truth for "work done"; this
# file carries only liveness + escalation intent (see ORCHESTRATE.md §4).
#
# Usage:
#   write-signal.sh <state> [--detail <d>] [--question <q>] [--recommendation <r>] \
#                           [--pr-url <u>] [--head <sha>]
#
#   <state> ∈ running | paused-needs-proxy | awaiting-merge-confirm |
#             rebase-blocked | stuck | complete | failed
#   (the supervisor launch-root.sh writes `crashed` directly, not via this recipe)
#
# `seq` is monotonic and bumps ONLY when <state> differs from the prior write
# (so `running` heartbeats do not advance it); `heartbeat_ts` updates on EVERY
# write. The orchestrator's roots-watcher fires on seq strictly greater than the
# last seq it consumed, and uses heartbeat_ts for liveness — see ORCHESTRATE.md §4.
#
# Atomic write (.tmp then mv), matching every other status write in this repo.
# All progress to stderr; nothing on stdout.

set -uo pipefail   # not -e: a signal write must never abort the Root

# --- environment gate: silently no-op for non-orchestrated Roots ---
[[ "${AGENT_TDD_ORCHESTRATED:-}" == "1" ]] || exit 0
[[ -n "${AGENT_TDD_SIGNAL_PATH:-}" ]] || exit 0

log() { printf '[write-signal] %s\n' "$*" >&2; }

[[ $# -ge 1 ]] || { log "usage: $0 <state> [--detail d] [--question q] [--recommendation r] [--pr-url u] [--head sha]"; exit 1; }
STATE="$1"; shift

DETAIL=""; QUESTION=""; RECOMMENDATION=""; PR_URL=""; HEAD_SHA=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --detail)         DETAIL="${2:-}"; shift 2 ;;
    --question)       QUESTION="${2:-}"; shift 2 ;;
    --recommendation) RECOMMENDATION="${2:-}"; shift 2 ;;
    --pr-url)         PR_URL="${2:-}"; shift 2 ;;
    --head)           HEAD_SHA="${2:-}"; shift 2 ;;
    *) log "unknown arg: $1"; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { log "jq not found on PATH; cannot write signal"; exit 0; }

SIGNAL="${AGENT_TDD_SIGNAL_PATH}"
mkdir -p "$(dirname "${SIGNAL}")"

# --- monotonic seq: bump only on a state change ---
PREV_SEQ=0
PREV_STATE=""
if [[ -f "${SIGNAL}" ]]; then
  PREV_SEQ="$(jq -r '.seq // 0' "${SIGNAL}" 2>/dev/null || echo 0)"
  PREV_STATE="$(jq -r '.state // empty' "${SIGNAL}" 2>/dev/null || echo "")"
fi
[[ "${PREV_SEQ}" =~ ^[0-9]+$ ]] || PREV_SEQ=0
if [[ "${STATE}" == "${PREV_STATE}" ]]; then
  SEQ="${PREV_SEQ}"
else
  SEQ=$((PREV_SEQ + 1))
fi

# ISO-8601 UTC; date is available on both Linux and macOS for this form.
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"

TMP="${SIGNAL}.tmp.$$"
jq -n \
  --arg notes_id "${AGENT_TDD_NOTES_ID:-}" \
  --arg sub_ref  "${AGENT_TDD_SUB_REF:-}" \
  --arg state    "${STATE}" \
  --arg detail   "${DETAIL}" \
  --arg question "${QUESTION}" \
  --arg rec      "${RECOMMENDATION}" \
  --arg pr_url   "${PR_URL}" \
  --arg base     "${AGENT_TDD_BASE:-}" \
  --arg head     "${HEAD_SHA}" \
  --argjson seq  "${SEQ}" \
  --arg ts       "${TS}" '
  {
    notes_id:        $notes_id,
    sub_ref:         $sub_ref,
    state:           $state,
    detail:          (if $detail   == "" then null else $detail   end),
    question:        (if $question == "" then null else $question end),
    recommendation:  (if $rec      == "" then null else $rec      end),
    pr_url:          (if $pr_url   == "" then null else $pr_url   end),
    base:            (if $base     == "" then null else $base     end),
    head:            (if $head     == "" then null else $head     end),
    seq:             $seq,
    heartbeat_ts:    $ts
  }
' > "${TMP}" 2>/dev/null || { log "failed to render signal JSON"; rm -f "${TMP}"; exit 0; }
mv "${TMP}" "${SIGNAL}"
log "signal: state=${STATE} seq=${SEQ} -> ${SIGNAL}"
