#!/usr/bin/env bash
# ready-unmark.sh — remove the `atdd:ready` label from a SubIssue (the inverse
# of ready-mark.sh). Use it to pull a SubIssue back from "ready for /atdd" when
# its spec needs more work before handoff.
#
# Idempotent: if the SubIssue is not currently marked ready, it's a no-op.
#
# Usage:  ready-unmark.sh <sub-ref>
#   <sub-ref> = <owner>/<repo>#<N>

set -euo pipefail

log() { printf '[ready-unmark] %s\n' "$*" >&2; }
die() { printf '[ready-unmark] ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

[[ $# -eq 1 ]] || die "usage: ready-unmark.sh <owner>/<repo>#<N>"
SUB_REF="$1"
[[ "$SUB_REF" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$ ]] \
  || die "sub-ref must look like <owner>/<repo>#<N> (got: $SUB_REF)"
REPO="${BASH_REMATCH[1]}"
NUMBER="${BASH_REMATCH[2]}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.agent-tdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found (run manifest-ensure.sh first)"
SUB_LABEL="$(jq -er '.labels.sub' "$MANIFEST")"
READY_LABEL="$(jq -er '.labels.ready' "$MANIFEST")"

# Defensive: only SubIssues carry the ready label (mirror ready-mark.sh).
LBL_LIST="$(gh api "repos/${REPO}/issues/${NUMBER}" -q '.labels[].name' 2>&1)" \
  || die "failed to fetch ${SUB_REF}: $LBL_LIST"
grep -qxF "$SUB_LABEL" <<<"$LBL_LIST" \
  || die "${SUB_REF} does not carry '${SUB_LABEL}' — only SubIssues can be (un)marked ready"

# Idempotent: skip if not currently marked ready.
if ! grep -qxF "$READY_LABEL" <<<"$LBL_LIST"; then
  log "${SUB_REF} is not marked '${READY_LABEL}' — noop"
  exit 0
fi

log "removing label '${READY_LABEL}' from ${SUB_REF}"
gh issue edit "$NUMBER" -R "$REPO" --remove-label "$READY_LABEL" >/dev/null \
  || die "failed to remove label"

log "ok"
