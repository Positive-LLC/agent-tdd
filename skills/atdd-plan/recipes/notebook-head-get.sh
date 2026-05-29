#!/usr/bin/env bash
# notebook-head-get.sh — read the NotebookIssue comment for a single head.
#
# Each head (RootIssue) gets its own comment in the NotebookIssue whose first
# line is the marker `<!-- atdd-head: <owner>/<repo>#<N> -->`. We find it by
# that marker and print the comment body (stripped of the marker line) on
# stdout. Empty output if no such comment exists yet.
#
# Usage:  notebook-head-get.sh <root-ref>
#   <root-ref> = <owner>/<repo>#<N>, e.g. Positive-LLC/pg-agent-erp#42

set -euo pipefail

log() { printf '[notebook-head-get] %s\n' "$*" >&2; }
die() { printf '[notebook-head-get] ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

[[ $# -eq 1 ]] || die "usage: notebook-head-get.sh <owner>/<repo>#<N>"
ROOT_REF="$1"
[[ "$ROOT_REF" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$ ]] \
  || die "root-ref must look like <owner>/<repo>#<N> (got: $ROOT_REF)"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.agent-tdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found (run manifest-ensure.sh first)"

HOME_REPO="$(jq -er '.home_repo' "$MANIFEST")"
NB_NUMBER="$(jq -er '.notebook_issue.number' "$MANIFEST")"

MARKER="<!-- atdd-head: ${ROOT_REF} -->"

# Walk comments page by page until we find the marker or run out.
PER_PAGE=100
page=1
while :; do
  PAGE_JSON="$(gh api \
    "repos/${HOME_REPO}/issues/${NB_NUMBER}/comments?per_page=${PER_PAGE}&page=${page}" 2>&1)" \
    || die "failed to list NotebookIssue comments: $PAGE_JSON"

  COUNT="$(jq 'length' <<<"$PAGE_JSON")"
  [[ "$COUNT" -gt 0 ]] || { log "marker not found in any comment"; exit 0; }

  # First *comment* whose body starts with the marker — not the first *line*.
  # (head -n 1 would keep only the marker line, which awk then strips to "".)
  BODY="$(jq -r --arg m "$MARKER" \
    'first(.[] | select(.body | startswith($m)) | .body) // empty' <<<"$PAGE_JSON")"
  if [[ -n "$BODY" ]]; then
    # Strip the marker line + the immediately following blank line, if any.
    awk -v m="$MARKER" '
      NR == 1 && $0 == m { skip_next_blank=1; next }
      skip_next_blank && $0 == "" { skip_next_blank=0; next }
      { skip_next_blank=0; print }
    ' <<<"$BODY"
    exit 0
  fi

  if [[ "$COUNT" -lt "$PER_PAGE" ]]; then
    log "marker not found"
    exit 0
  fi
  page=$((page + 1))
done
