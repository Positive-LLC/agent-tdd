#!/usr/bin/env bash
# notebook-head-set.sh — upsert the NotebookIssue comment for a single head.
#
# Reads the comment body from <markdown-file> (use "-" for stdin), prepends
# the marker line, then either PATCHes the existing comment (matched by
# leading marker) or creates a new comment.
#
# Usage:  notebook-head-set.sh <root-ref> <markdown-file>
#   <root-ref>       = <owner>/<repo>#<N>
#   <markdown-file>  = path to markdown body, or "-" to read stdin

set -euo pipefail

log() { printf '[notebook-head-set] %s\n' "$*" >&2; }
die() { printf '[notebook-head-set] ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

[[ $# -eq 2 ]] || die "usage: notebook-head-set.sh <owner>/<repo>#<N> <markdown-file|->"
ROOT_REF="$1"
SRC="$2"
[[ "$ROOT_REF" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$ ]] \
  || die "root-ref must look like <owner>/<repo>#<N> (got: $ROOT_REF)"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.agent-tdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found (run manifest-ensure.sh first)"
HOME_REPO="$(jq -er '.home_repo' "$MANIFEST")"
NB_NUMBER="$(jq -er '.notebook_issue.number' "$MANIFEST")"

MARKER="<!-- atdd-head: ${ROOT_REF} -->"

# Read body
if [[ "$SRC" == "-" ]]; then
  BODY_CONTENT="$(cat)"
else
  [[ -r "$SRC" ]] || die "markdown file not readable: $SRC"
  BODY_CONTENT="$(cat "$SRC")"
fi
NEW_BODY="${MARKER}

${BODY_CONTENT}"

# Find existing comment id (if any) by marker scan.
EXISTING_ID=""
PER_PAGE=100
page=1
while :; do
  PAGE_JSON="$(gh api \
    "repos/${HOME_REPO}/issues/${NB_NUMBER}/comments?per_page=${PER_PAGE}&page=${page}")" \
    || die "failed to list NotebookIssue comments"
  COUNT="$(jq 'length' <<<"$PAGE_JSON")"
  [[ "$COUNT" -gt 0 ]] || break
  EXISTING_ID="$(jq -r --arg m "$MARKER" \
    '.[] | select(.body | startswith($m)) | .id' <<<"$PAGE_JSON" \
    | head -n 1)"
  [[ -n "$EXISTING_ID" ]] && break
  [[ "$COUNT" -lt "$PER_PAGE" ]] && break
  page=$((page + 1))
done

if [[ -n "$EXISTING_ID" ]]; then
  log "PATCH existing comment id=${EXISTING_ID}"
  gh api -X PATCH "repos/${HOME_REPO}/issues/comments/${EXISTING_ID}" \
    -f body="$NEW_BODY" >/dev/null \
    || die "failed to PATCH comment"
  echo "$EXISTING_ID"
else
  log "creating new comment for ${ROOT_REF}"
  CREATED="$(gh api -X POST "repos/${HOME_REPO}/issues/${NB_NUMBER}/comments" \
    -f body="$NEW_BODY")" || die "failed to create comment"
  jq -r '.id' <<<"$CREATED"
fi
