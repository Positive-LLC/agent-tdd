#!/usr/bin/env bash
# root-create.sh — create a RootIssue in the home repo, label it `atdd:root`,
# and add it to the manifest-configured GitHubProject.
#
# The body must already contain the distilled Input/Output and shared context
# (see CORE.md §3.2). This recipe does not template the body — that's the
# Notes Agent's job.
#
# Usage:  root-create.sh <title> <body-file|->
# Output: <owner>/<repo>#<N> on stdout (one line).

set -euo pipefail

log() { printf '[root-create] %s\n' "$*" >&2; }
die() { printf '[root-create] ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

[[ $# -eq 2 ]] || die "usage: root-create.sh <title> <body-file|->"
TITLE="$1"
SRC="$2"
[[ -n "$TITLE" ]] || die "title must be non-empty"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.agent-tdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found (run manifest-ensure.sh first)"

HOME_REPO="$(jq -er '.home_repo' "$MANIFEST")"
PROJECT_OWNER="$(jq -er '.project.owner' "$MANIFEST")"
PROJECT_NUMBER="$(jq -er '.project.number' "$MANIFEST")"
ROOT_LABEL="$(jq -er '.labels.root' "$MANIFEST")"

if [[ "$SRC" == "-" ]]; then
  BODY="$(cat)"
else
  [[ -r "$SRC" ]] || die "body file not readable: $SRC"
  BODY="$(cat "$SRC")"
fi
[[ -n "$BODY" ]] || die "body must be non-empty"

log "creating RootIssue in ${HOME_REPO}"
URL="$(gh issue create -R "$HOME_REPO" \
  --title "$TITLE" \
  --body  "$BODY" \
  --label "$ROOT_LABEL")"
NUMBER="$(basename "$URL")"
log "created ${URL}"

log "adding to project ${PROJECT_OWNER}/#${PROJECT_NUMBER}"
gh project item-add "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --url "$URL" >/dev/null \
  || die "failed to add RootIssue to project"

printf '%s#%s\n' "$HOME_REPO" "$NUMBER"
