#!/usr/bin/env bash
# issue-edit.sh — edit the title and/or body of an atdd-managed issue
# (a RootIssue or a SubIssue). This is the "U" (update content) of CRUD for
# both entity types — the mechanism is identical, only the guard differs, so
# one recipe serves both.
#
# Refuses to touch any issue that is not managed by this system (must carry
# `atdd:root` or `atdd:sub`) — prevents accidental edits to unrelated issues.
#
# Usage:  issue-edit.sh <ref> [--title <title>] [--body-file <file|->]
#   <ref>          = <owner>/<repo>#<N>
#   --title        = new title (optional)
#   --body-file    = path to new body markdown, or "-" to read stdin (optional)
# At least one of --title / --body-file must be given.
# Output: <owner>/<repo>#<N> on stdout (one line).

set -euo pipefail

log() { printf '[issue-edit] %s\n' "$*" >&2; }
die() { printf '[issue-edit] ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

[[ $# -ge 1 ]] || die "usage: issue-edit.sh <ref> [--title <title>] [--body-file <file|->]"
REF="$1"; shift
[[ "$REF" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$ ]] \
  || die "ref must look like <owner>/<repo>#<N> (got: $REF)"
REPO="${BASH_REMATCH[1]}"
NUMBER="${BASH_REMATCH[2]}"

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

# Guard: only edit issues this system manages.
LBL_LIST="$(gh api "repos/${REPO}/issues/${NUMBER}" -q '.labels[].name' 2>&1)" \
  || die "failed to fetch ${REF}: $LBL_LIST"
grep -qxF "$ROOT_LABEL" <<<"$LBL_LIST" || grep -qxF "$SUB_LABEL" <<<"$LBL_LIST" \
  || die "${REF} carries neither '${ROOT_LABEL}' nor '${SUB_LABEL}' — not an atdd-managed issue"

# Resolve body content up-front so we can pass it via --body (handles "-"
# stdin uniformly and avoids depending on gh's own --body-file path parsing).
ARGS=(issue edit "$NUMBER" -R "$REPO")
if [[ "$HAVE_TITLE" -eq 1 ]]; then
  [[ -n "$TITLE" ]] || die "title must be non-empty"
  ARGS+=(--title "$TITLE")
fi
if [[ "$HAVE_BODY" -eq 1 ]]; then
  if [[ "$BODY_FILE" == "-" ]]; then
    BODY="$(cat)"
  else
    [[ -r "$BODY_FILE" ]] || die "body file not readable: $BODY_FILE"
    BODY="$(cat "$BODY_FILE")"
  fi
  [[ -n "$BODY" ]] || die "body must be non-empty"
  ARGS+=(--body "$BODY")
fi

log "editing ${REF}"
gh "${ARGS[@]}" >/dev/null || die "failed to edit ${REF}"

printf '%s\n' "$REF"
