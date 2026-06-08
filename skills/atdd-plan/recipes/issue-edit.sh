#!/usr/bin/env bash
# issue-edit.sh — edit the title and/or body of an atdd-managed issue (RootIssue
# or SubIssue). Refuses to touch issues that carry neither `atdd:root` nor
# `atdd:sub`.
#
# Usage:  issue-edit.sh <ref> [--title <title>] [--body-file <file|->]
# Output: <owner>/<repo>#<N> on stdout (one line).

set -euo pipefail

log() { printf '[issue-edit] %s\n' "$*" >&2; }
die() { printf '[issue-edit] ERROR: %s\n' "$*" >&2; exit 1; }

command -v atdd >/dev/null 2>&1 || die "atdd CLI not found on PATH"
command -v jq   >/dev/null 2>&1 || die "jq not found on PATH"

[[ $# -ge 1 ]] || die "usage: issue-edit.sh <ref> [--title <title>] [--body-file <file|->]"
REF="$1"; shift
[[ "$REF" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$ ]] \
  || die "ref must look like <owner>/<repo>#<N> (got: $REF)"

TITLE=""; HAVE_TITLE=0
BODY_FILE=""; HAVE_BODY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)     [[ $# -ge 2 ]] || die "--title needs a value"; TITLE="$2"; HAVE_TITLE=1; shift 2;;
    --body-file) [[ $# -ge 2 ]] || die "--body-file needs a value"; BODY_FILE="$2"; HAVE_BODY=1; shift 2;;
    *) die "unknown argument: $1";;
  esac
done
[[ "$HAVE_TITLE" -eq 1 || "$HAVE_BODY" -eq 1 ]] \
  || die "nothing to do — pass --title and/or --body-file"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.agent-tdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found (run manifest-ensure.sh first)"
ROOT_LABEL="$(jq -er '.labels.root' "$MANIFEST")"
SUB_LABEL="$(jq -er '.labels.sub' "$MANIFEST")"

VIEW="$(atdd issue view "$REF")" || die "failed to fetch ${REF}"
jq -e --arg r "$ROOT_LABEL" --arg s "$SUB_LABEL" \
  '(.labels|index($r)) or (.labels|index($s))' >/dev/null <<<"$VIEW" \
  || die "${REF} carries neither '${ROOT_LABEL}' nor '${SUB_LABEL}' — not an atdd-managed issue"

ARGS=(issue edit "$REF")
[[ "$HAVE_TITLE" -eq 1 ]] && { [[ -n "$TITLE" ]] || die "title must be non-empty"; ARGS+=(--title "$TITLE"); }

log "editing ${REF}"
if [[ "$HAVE_BODY" -eq 1 ]]; then
  if [[ "$BODY_FILE" == "-" ]]; then BODY="$(cat)"; else
    [[ -r "$BODY_FILE" ]] || die "body file not readable: $BODY_FILE"; BODY="$(cat "$BODY_FILE")"; fi
  [[ -n "$BODY" ]] || die "body must be non-empty"
  printf '%s' "$BODY" | atdd "${ARGS[@]}" --body-file - >/dev/null || die "failed to edit ${REF}"
else
  atdd "${ARGS[@]}" >/dev/null || die "failed to edit ${REF}"
fi

printf '%s\n' "$REF"
