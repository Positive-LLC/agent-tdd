#!/usr/bin/env bash
# sub-unlink.sh — remove the native sub-issue link between a SubIssue and its
# parent RootIssue. This detaches the parent-child edge only; it does NOT close
# or delete the issue, nor remove its `atdd:sub` label. Use it to re-parent a
# SubIssue (unlink here, then sub-adopt under the new parent) or to drop a
# mistaken adoption.
#
# Idempotent: if the issue is not currently a sub-issue of the parent, it's a
# no-op.
#
# Usage:  sub-unlink.sh <sub-ref> <root-ref>
#   <sub-ref>   = <owner>/<repo>#<N>  (the SubIssue to detach)
#   <root-ref>  = <owner>/<repo>#<N>  (its current parent RootIssue)
# Output: nothing on success; non-zero exit + stderr on failure.

set -euo pipefail

log() { printf '[sub-unlink] %s\n' "$*" >&2; }
die() { printf '[sub-unlink] ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

[[ $# -eq 2 ]] || die "usage: sub-unlink.sh <sub-ref> <root-ref>"
SUB_REF="$1"
ROOT_REF="$2"
[[ "$SUB_REF" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$ ]] \
  || die "sub-ref must look like <owner>/<repo>#<N> (got: $SUB_REF)"
SUB_REPO="${BASH_REMATCH[1]}"
SUB_NUMBER="${BASH_REMATCH[2]}"
[[ "$ROOT_REF" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$ ]] \
  || die "root-ref must look like <owner>/<repo>#<N> (got: $ROOT_REF)"
PARENT_REPO="${BASH_REMATCH[1]}"
PARENT_NUMBER="${BASH_REMATCH[2]}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.agent-tdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found (run manifest-ensure.sh first)"
HOME_REPO="$(jq -er '.home_repo' "$MANIFEST")"
ROOT_LABEL="$(jq -er '.labels.root' "$MANIFEST")"

# Parent must be a RootIssue in the home repo (mirrors sub-create/sub-adopt).
[[ "$PARENT_REPO" == "$HOME_REPO" ]] \
  || die "parent RootIssue must live in home repo ${HOME_REPO} (got: ${PARENT_REPO})"
PARENT_LABELS="$(gh api "repos/${PARENT_REPO}/issues/${PARENT_NUMBER}" -q '.labels[].name' 2>&1)" \
  || die "failed to fetch parent issue ${ROOT_REF}: $PARENT_LABELS"
grep -qxF "$ROOT_LABEL" <<<"$PARENT_LABELS" \
  || die "parent ${ROOT_REF} does not carry label '${ROOT_LABEL}' — not a RootIssue"

# Resolve the SubIssue's database id (the link is keyed by db id, not number).
CHILD_DB_ID="$(gh api "repos/${SUB_REPO}/issues/${SUB_NUMBER}" -q '.id' 2>&1)" \
  || die "failed to fetch ${SUB_REF}: $CHILD_DB_ID"

# Idempotency: only DELETE if the child is actually linked under this parent.
LINKED_IDS="$(gh api "repos/${PARENT_REPO}/issues/${PARENT_NUMBER}/sub_issues" -q '.[].id' 2>/dev/null || true)"
if ! grep -qxF "$CHILD_DB_ID" <<<"$LINKED_IDS"; then
  log "${SUB_REF} is not a sub-issue of ${ROOT_REF} — noop"
  exit 0
fi

# Remove link. NB: the remove endpoint path is singular `sub_issue` (vs the
# plural `sub_issues` used for list/add); body carries the typed integer id.
log "unlinking ${SUB_REF} from ${ROOT_REF} (db_id=${CHILD_DB_ID})"
gh api -X DELETE "repos/${PARENT_REPO}/issues/${PARENT_NUMBER}/sub_issue" \
  -F sub_issue_id="$CHILD_DB_ID" >/dev/null \
  || die "failed to unlink sub-issue (parent=${ROOT_REF}, child_db_id=${CHILD_DB_ID})"

log "ok"
