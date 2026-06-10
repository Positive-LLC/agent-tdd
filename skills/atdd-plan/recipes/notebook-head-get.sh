#!/usr/bin/env bash
# notebook-head-get.sh — read the NotebookIssue note for a single head from the
# local atdd store. Prints the note body on stdout (empty if none yet).
#
# Usage:  notebook-head-get.sh <root-ref>   (<root-ref> = <owner>/<repo>#<N>)

set -euo pipefail

die() { printf '[notebook-head-get] ERROR: %s\n' "$*" >&2; exit 1; }

command -v atdd >/dev/null 2>&1 || die "atdd CLI not found on PATH"
command -v jq   >/dev/null 2>&1 || die "jq not found on PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_project-env.sh"

[[ $# -eq 1 ]] || die "usage: notebook-head-get.sh <owner>/<repo>#<N>"
ROOT_REF="$1"
[[ "$ROOT_REF" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$ ]] \
  || die "root-ref must look like <owner>/<repo>#<N> (got: $ROOT_REF)"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.atdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found (run manifest-ensure.sh first)"
HOME_REPO="$(jq -er '.home_repo' "$MANIFEST")"
NB_NUMBER="$(jq -er '.notebook_issue.number' "$MANIFEST")"
NB_REF="${HOME_REPO}#${NB_NUMBER}"

atdd notebook head-get "$NB_REF" "$ROOT_REF"
