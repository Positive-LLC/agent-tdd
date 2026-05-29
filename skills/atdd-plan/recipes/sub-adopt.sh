#!/usr/bin/env bash
# sub-adopt.sh — adopt an EXISTING ("loose") issue into the planning graph as a
# SubIssue. Unlike sub-create.sh it does NOT create a new issue — the issue
# already exists. It performs the same three wiring steps:
#   1. label it `atdd:sub` (creating the label in the target repo if needed),
#   2. link it as a native sub-issue of the given RootIssue,
#   3. add it to the manifest-configured GitHubProject.
#
# Real-world planning almost always starts with loose issues someone already
# filed; this is how they enter the topology without being recreated.
#
# Idempotent: each step is skipped if already done (label present, link
# present). Safe to re-run after a partial failure.
#
# Usage:  sub-adopt.sh <target-repo> <existing-issue#> <root-ref>
#   <target-repo>      = <owner>/<repo>  (where the issue already lives)
#   <existing-issue#>  = integer issue number in <target-repo>
#   <root-ref>         = <owner>/<repo>#<N>  (the RootIssue to adopt it under)
# Output: <target-owner>/<target-repo>#<N> on stdout (one line).

set -euo pipefail

log() { printf '[sub-adopt] %s\n' "$*" >&2; }
die() { printf '[sub-adopt] ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

[[ $# -eq 3 ]] || die "usage: sub-adopt.sh <target-repo> <existing-issue#> <root-ref>"
TARGET_REPO="$1"
CHILD_NUMBER="$2"
ROOT_REF="$3"

[[ "$TARGET_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || die "target-repo must look like owner/name (got: $TARGET_REPO)"
[[ "$CHILD_NUMBER" =~ ^[0-9]+$ ]] \
  || die "existing-issue# must be an integer (got: $CHILD_NUMBER)"
[[ "$ROOT_REF" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$ ]] \
  || die "root-ref must look like <owner>/<repo>#<N> (got: $ROOT_REF)"
PARENT_REPO="${BASH_REMATCH[1]}"
PARENT_NUMBER="${BASH_REMATCH[2]}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.agent-tdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found (run manifest-ensure.sh first)"

HOME_REPO="$(jq -er '.home_repo' "$MANIFEST")"
PROJECT_OWNER="$(jq -er '.project.owner' "$MANIFEST")"
PROJECT_NUMBER="$(jq -er '.project.number' "$MANIFEST")"
SUB_LABEL="$(jq -er '.labels.sub' "$MANIFEST")"
ROOT_LABEL="$(jq -er '.labels.root' "$MANIFEST")"

# Parent must be a RootIssue (carry atdd:root) in the home repo. Same guard as
# sub-create.sh — keeps the graph a clean RootIssue-rooted forest.
[[ "$PARENT_REPO" == "$HOME_REPO" ]] \
  || die "parent RootIssue must live in home repo ${HOME_REPO} (got: ${PARENT_REPO})"
PARENT_LABELS="$(gh api "repos/${PARENT_REPO}/issues/${PARENT_NUMBER}" -q '.labels[].name' 2>&1)" \
  || die "failed to fetch parent issue ${ROOT_REF}: $PARENT_LABELS"
grep -qxF "$ROOT_LABEL" <<<"$PARENT_LABELS" \
  || die "parent ${ROOT_REF} does not carry label '${ROOT_LABEL}' — not a RootIssue"

# Fetch the existing child: its database id (for the native link) and labels
# (for the adopt-time guards + idempotency).
CHILD_JSON="$(gh api "repos/${TARGET_REPO}/issues/${CHILD_NUMBER}" 2>&1)" \
  || die "issue ${TARGET_REPO}#${CHILD_NUMBER} not found: $CHILD_JSON"
CHILD_DB_ID="$(jq -er '.id' <<<"$CHILD_JSON")" \
  || die "could not read database id of ${TARGET_REPO}#${CHILD_NUMBER}"
CHILD_LABELS="$(jq -r '.labels[].name' <<<"$CHILD_JSON")"

# Refuse to adopt a RootIssue as a SubIssue — that would corrupt the topology.
grep -qxF "$ROOT_LABEL" <<<"$CHILD_LABELS" \
  && die "${TARGET_REPO}#${CHILD_NUMBER} carries '${ROOT_LABEL}' (it is a RootIssue) — cannot adopt as a SubIssue"

# Ensure the sub label exists in the target repo (may differ from home repo).
if ! gh api "repos/${TARGET_REPO}/labels/${SUB_LABEL}" >/dev/null 2>&1; then
  log "creating label '${SUB_LABEL}' in ${TARGET_REPO}"
  gh api -X POST "repos/${TARGET_REPO}/labels" \
    -f name="$SUB_LABEL" \
    -f description="Agent TDD planning SubIssue (per-repo work unit)" \
    -f color="1d76db" >/dev/null \
    || die "failed to create label ${SUB_LABEL} in ${TARGET_REPO}"
fi

# Step 1: label atdd:sub (idempotent).
if grep -qxF "$SUB_LABEL" <<<"$CHILD_LABELS"; then
  log "${TARGET_REPO}#${CHILD_NUMBER} already labelled '${SUB_LABEL}' — skip"
else
  log "labelling ${TARGET_REPO}#${CHILD_NUMBER} '${SUB_LABEL}'"
  gh issue edit "$CHILD_NUMBER" -R "$TARGET_REPO" --add-label "$SUB_LABEL" >/dev/null \
    || die "failed to add label ${SUB_LABEL}"
fi

# Step 2: native sub-issue link (idempotent — skip if already a sub of parent).
LINKED_IDS="$(gh api "repos/${PARENT_REPO}/issues/${PARENT_NUMBER}/sub_issues" -q '.[].id' 2>/dev/null || true)"
if grep -qxF "$CHILD_DB_ID" <<<"$LINKED_IDS"; then
  log "already linked as sub-issue of ${ROOT_REF} — skip"
else
  log "linking as native sub-issue of ${ROOT_REF}"
  gh api -X POST "repos/${PARENT_REPO}/issues/${PARENT_NUMBER}/sub_issues" \
    -F sub_issue_id="$CHILD_DB_ID" >/dev/null \
    || die "failed to link sub-issue (parent=${ROOT_REF}, child_db_id=${CHILD_DB_ID})"
fi

# Step 3: add to project. gh project item-add is idempotent server-side
# (re-adding an existing item returns the existing item id, exit 0).
log "adding to project ${PROJECT_OWNER}/#${PROJECT_NUMBER}"
gh project item-add "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" \
  --url "https://github.com/${TARGET_REPO}/issues/${CHILD_NUMBER}" >/dev/null \
  || die "failed to add SubIssue to project"

printf '%s#%s\n' "$TARGET_REPO" "$CHILD_NUMBER"
