#!/usr/bin/env bash
# root-create.sh — create a RootIssue in the home repo, labelled `atdd:root`,
# in the local atdd store. Membership in the topology is implicit: any work-item
# carrying `atdd:root` is a RootIssue (the GitHubProject is gone — see cli_v2.md).
#
# The body must already contain the distilled Input/Output and shared context
# (see CORE.md §3.2). This recipe does not template the body.
#
# Usage:  root-create.sh <title> <body-file|->
# Output: <owner>/<repo>#<N> on stdout (one line).

set -euo pipefail

log() { printf '[root-create] %s\n' "$*" >&2; }
die() { printf '[root-create] ERROR: %s\n' "$*" >&2; exit 1; }

command -v atdd >/dev/null 2>&1 || die "atdd CLI not found on PATH"
command -v jq   >/dev/null 2>&1 || die "jq not found on PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_project-env.sh"

[[ $# -eq 2 ]] || die "usage: root-create.sh <title> <body-file|->"
TITLE="$1"
SRC="$2"
[[ -n "$TITLE" ]] || die "title must be non-empty"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.atdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found (run manifest-ensure.sh first)"

HOME_REPO="$(jq -er '.home_repo' "$MANIFEST")"
ROOT_LABEL="$(jq -er '.labels.root' "$MANIFEST")"

if [[ "$SRC" == "-" ]]; then
  BODY="$(cat)"
else
  [[ -r "$SRC" ]] || die "body file not readable: $SRC"
  BODY="$(cat "$SRC")"
fi
[[ -n "$BODY" ]] || die "body must be non-empty"

log "creating RootIssue in ${HOME_REPO}"
REF="$(printf '%s' "$BODY" | atdd issue create \
  --repo "$HOME_REPO" --title "$TITLE" --body-file - --label "$ROOT_LABEL" --porcelain)" \
  || die "failed to create RootIssue"

printf '%s\n' "$REF"
