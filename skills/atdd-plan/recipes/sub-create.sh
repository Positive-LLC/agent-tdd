#!/usr/bin/env bash
# sub-create.sh — create a SubIssue in <target-repo>, label it `atdd:sub`,
# add it to the manifest-configured GitHubProject, and link it as a native
# sub-issue of the given RootIssue (parent in home repo, child in target repo
# — cross-repo sub-issues, verified working 2026-05-28).
#
# Usage:  sub-create.sh <target-repo> <root-ref> <title> <body-file|->
#   <target-repo>  = <owner>/<repo>  (where the work happens)
#   <root-ref>     = <owner>/<repo>#<N>  (the RootIssue this child belongs to)
# Output: <target-owner>/<target-repo>#<N> on stdout (one line).

set -euo pipefail

log() { printf '[sub-create] %s\n' "$*" >&2; }
die() { printf '[sub-create] ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

[[ $# -eq 4 ]] || die "usage: sub-create.sh <target-repo> <root-ref> <title> <body-file|->"
TARGET_REPO="$1"
ROOT_REF="$2"
TITLE="$3"
SRC="$4"

[[ "$TARGET_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || die "target-repo must look like owner/name (got: $TARGET_REPO)"
[[ "$ROOT_REF" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$ ]] \
  || die "root-ref must look like <owner>/<repo>#<N> (got: $ROOT_REF)"
PARENT_REPO="${BASH_REMATCH[1]}"
PARENT_NUMBER="${BASH_REMATCH[2]}"
[[ -n "$TITLE" ]] || die "title must be non-empty"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.agent-tdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found (run manifest-ensure.sh first)"

HOME_REPO="$(jq -er '.home_repo' "$MANIFEST")"
PROJECT_OWNER="$(jq -er '.project.owner' "$MANIFEST")"
PROJECT_NUMBER="$(jq -er '.project.number' "$MANIFEST")"
SUB_LABEL="$(jq -er '.labels.sub' "$MANIFEST")"
ROOT_LABEL="$(jq -er '.labels.root' "$MANIFEST")"

# Same-graph sanity: parent must be a RootIssue (carry atdd:root) in the home repo.
[[ "$PARENT_REPO" == "$HOME_REPO" ]] \
  || die "parent RootIssue must live in home repo ${HOME_REPO} (got: ${PARENT_REPO})"
PARENT_LABELS="$(gh api "repos/${PARENT_REPO}/issues/${PARENT_NUMBER}" -q '.labels[].name' 2>&1)" \
  || die "failed to fetch parent issue: $PARENT_LABELS"
grep -qxF "$ROOT_LABEL" <<<"$PARENT_LABELS" \
  || die "parent ${ROOT_REF} does not carry label '${ROOT_LABEL}' — not a RootIssue"

# Ensure the sub label exists in the target repo (a different repo than home).
if ! gh api "repos/${TARGET_REPO}/labels/${SUB_LABEL}" >/dev/null 2>&1; then
  log "creating label '${SUB_LABEL}' in ${TARGET_REPO}"
  gh api -X POST "repos/${TARGET_REPO}/labels" \
    -f name="$SUB_LABEL" \
    -f description="Agent TDD planning SubIssue (per-repo work unit)" \
    -f color="1d76db" >/dev/null \
    || die "failed to create label ${SUB_LABEL} in ${TARGET_REPO}"
fi

if [[ "$SRC" == "-" ]]; then
  BODY="$(cat)"
else
  [[ -r "$SRC" ]] || die "body file not readable: $SRC"
  BODY="$(cat "$SRC")"
fi
[[ -n "$BODY" ]] || die "body must be non-empty"

log "creating SubIssue in ${TARGET_REPO}"
CHILD_URL="$(gh issue create -R "$TARGET_REPO" \
  --title "$TITLE" \
  --body  "$BODY" \
  --label "$SUB_LABEL")"
CHILD_NUMBER="$(basename "$CHILD_URL")"
log "created ${CHILD_URL}"

# Fetch child's database id — REST integer, NOT the GraphQL node_id.
CHILD_DB_ID="$(gh api "repos/${TARGET_REPO}/issues/${CHILD_NUMBER}" -q .id)" \
  || die "failed to fetch child issue database id"

# Native sub-issue link. Must use -F (typed integer) per the GitHub API;
# -f sends a string and is rejected 422.
log "linking as native sub-issue of ${ROOT_REF}"
gh api -X POST "repos/${PARENT_REPO}/issues/${PARENT_NUMBER}/sub_issues" \
  -F sub_issue_id="$CHILD_DB_ID" >/dev/null \
  || die "failed to link sub-issue (parent=${ROOT_REF}, child_db_id=${CHILD_DB_ID})"

log "adding to project ${PROJECT_OWNER}/#${PROJECT_NUMBER}"
gh project item-add "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --url "$CHILD_URL" >/dev/null \
  || die "failed to add SubIssue to project"

printf '%s#%s\n' "$TARGET_REPO" "$CHILD_NUMBER"
