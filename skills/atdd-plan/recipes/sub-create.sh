#!/usr/bin/env bash
# sub-create.sh — create a SubIssue in <target-repo>, label it `atdd:sub`, and
# link it as a native sub-issue of the given RootIssue (parent in home repo,
# child in target repo — cross-repo links are first-class in the atdd store).
#
# Usage:  sub-create.sh <target-repo> <root-ref> <title> <body-file|->
#   <target-repo>  = <owner>/<repo>  (where the work happens)
#   <root-ref>     = <owner>/<repo>#<N>  (the RootIssue this child belongs to)
# Output: <target-owner>/<target-repo>#<N> on stdout (one line).

set -euo pipefail

log() { printf '[sub-create] %s\n' "$*" >&2; }
die() { printf '[sub-create] ERROR: %s\n' "$*" >&2; exit 1; }

command -v atdd >/dev/null 2>&1 || die "atdd CLI not found on PATH"
command -v jq   >/dev/null 2>&1 || die "jq not found on PATH"

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
[[ -n "$TITLE" ]] || die "title must be non-empty"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.agent-tdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found (run manifest-ensure.sh first)"

HOME_REPO="$(jq -er '.home_repo' "$MANIFEST")"
SUB_LABEL="$(jq -er '.labels.sub' "$MANIFEST")"
ROOT_LABEL="$(jq -er '.labels.root' "$MANIFEST")"

# Same-graph sanity: parent must be a RootIssue (carry atdd:root) in the home repo.
[[ "$PARENT_REPO" == "$HOME_REPO" ]] \
  || die "parent RootIssue must live in home repo ${HOME_REPO} (got: ${PARENT_REPO})"
PARENT_VIEW="$(atdd issue view "$ROOT_REF")" || die "failed to fetch parent ${ROOT_REF}"
jq -e --arg l "$ROOT_LABEL" '.labels|index($l)' >/dev/null <<<"$PARENT_VIEW" \
  || die "parent ${ROOT_REF} does not carry '${ROOT_LABEL}' — not a RootIssue"

if [[ "$SRC" == "-" ]]; then
  BODY="$(cat)"
else
  [[ -r "$SRC" ]] || die "body file not readable: $SRC"
  BODY="$(cat "$SRC")"
fi
[[ -n "$BODY" ]] || die "body must be non-empty"

log "creating SubIssue in ${TARGET_REPO}"
CHILD_REF="$(printf '%s' "$BODY" | atdd issue create \
  --repo "$TARGET_REPO" --title "$TITLE" --body-file - --label "$SUB_LABEL" --porcelain)" \
  || die "failed to create SubIssue"

log "linking as native sub-issue of ${ROOT_REF}"
atdd sub link "$ROOT_REF" "$CHILD_REF" >/dev/null \
  || die "failed to link sub-issue (parent=${ROOT_REF}, child=${CHILD_REF})"

printf '%s\n' "$CHILD_REF"
