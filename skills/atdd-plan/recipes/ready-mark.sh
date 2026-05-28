#!/usr/bin/env bash
# ready-mark.sh — label a SubIssue `atdd:ready` so the human can hand it to
# `/atdd`. The label may need to be created in the target repo on first use.
#
# Usage:  ready-mark.sh <sub-ref>
#   <sub-ref> = <owner>/<repo>#<N>

set -euo pipefail

log() { printf '[ready-mark] %s\n' "$*" >&2; }
die() { printf '[ready-mark] ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

[[ $# -eq 1 ]] || die "usage: ready-mark.sh <owner>/<repo>#<N>"
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

# Defensive: refuse to mark something that isn't a SubIssue.
LBL_LIST="$(gh api "repos/${REPO}/issues/${NUMBER}" -q '.labels[].name')" \
  || die "failed to fetch ${SUB_REF}"
grep -qxF "$SUB_LABEL" <<<"$LBL_LIST" \
  || die "${SUB_REF} does not carry '${SUB_LABEL}' — only SubIssues can be marked ready"

# Ensure the ready label exists in this repo.
if ! gh api "repos/${REPO}/labels/${READY_LABEL}" >/dev/null 2>&1; then
  log "creating label '${READY_LABEL}' in ${REPO}"
  gh api -X POST "repos/${REPO}/labels" \
    -f name="$READY_LABEL" \
    -f description="SubIssue is ready for /atdd to consume" \
    -f color="fbca04" >/dev/null \
    || die "failed to create label ${READY_LABEL}"
fi

# Idempotent: skip if already marked.
if grep -qxF "$READY_LABEL" <<<"$LBL_LIST"; then
  log "${SUB_REF} already marked ready — noop"
  exit 0
fi

log "labelling ${SUB_REF} as ready"
gh issue edit "$NUMBER" -R "$REPO" --add-label "$READY_LABEL" >/dev/null \
  || die "failed to add label"
