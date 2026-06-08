#!/usr/bin/env bash
# issue-close.sh — close (or reopen) an atdd-managed issue. Works for RootIssues
# and SubIssues. Idempotent at the store level (closing a closed issue / reopening
# an open one settles to the requested state).
#
# Usage:  issue-close.sh <ref> [--reopen] [--reason <completed|not_planned>]
# Output: <owner>/<repo>#<N> on stdout (one line).

set -euo pipefail

log() { printf '[issue-close] %s\n' "$*" >&2; }
die() { printf '[issue-close] ERROR: %s\n' "$*" >&2; exit 1; }

command -v atdd >/dev/null 2>&1 || die "atdd CLI not found on PATH"
command -v jq   >/dev/null 2>&1 || die "jq not found on PATH"

[[ $# -ge 1 ]] || die "usage: issue-close.sh <ref> [--reopen] [--reason <completed|not_planned>]"
REF="$1"; shift
[[ "$REF" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$ ]] \
  || die "ref must look like <owner>/<repo>#<N> (got: $REF)"

REOPEN=0
REASON="completed"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reopen) REOPEN=1; shift;;
    --reason) [[ $# -ge 2 ]] || die "--reason needs a value"; REASON="$2"; shift 2;;
    *) die "unknown argument: $1";;
  esac
done
case "$REASON" in
  completed|not_planned) ;;
  *) die "--reason must be 'completed' or 'not_planned' (got: $REASON)";;
esac

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.agent-tdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found (run manifest-ensure.sh first)"
ROOT_LABEL="$(jq -er '.labels.root' "$MANIFEST")"
SUB_LABEL="$(jq -er '.labels.sub' "$MANIFEST")"

VIEW="$(atdd issue view "$REF")" || die "failed to fetch ${REF}"
jq -e --arg r "$ROOT_LABEL" --arg s "$SUB_LABEL" \
  '(.labels|index($r)) or (.labels|index($s))' >/dev/null <<<"$VIEW" \
  || die "${REF} carries neither '${ROOT_LABEL}' nor '${SUB_LABEL}' — not an atdd-managed issue"

if [[ "$REOPEN" -eq 1 ]]; then
  log "reopening ${REF}"
  atdd issue close "$REF" --reopen >/dev/null || die "failed to reopen ${REF}"
else
  log "closing ${REF} (reason: ${REASON})"
  atdd issue close "$REF" --reason "$REASON" >/dev/null || die "failed to close ${REF}"
fi

printf '%s\n' "$REF"
