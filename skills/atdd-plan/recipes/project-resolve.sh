#!/usr/bin/env bash
# project-resolve.sh — decide which atdd project this repo's planning runs in,
# WITHOUT asking the human unless it is genuinely ambiguous.
#
# Source of truth for membership is the atdd master registry (`atdd repo where`).
# This is the "exact timing" hook: run it at the start of a planning run.
#
# Resolution (precedence): $ATDD_PROJECT or the manifest's pinned .project_slug
# win immediately (a decision was already made — never re-ask). Otherwise consult
# `atdd repo where <home_repo>`:
#   exactly 1 project  -> print it, exit 0          (auto; no ask)
#   zero projects      -> exit 10                    (first-time bootstrap needed)
#   more than 1        -> print the slugs, exit 11   (AMBIGUOUS; caller must ask)
#
# Output: on exit 0, the single resolved slug on stdout. On exit 11, the candidate
# slugs (one per line) on stdout. Progress on stderr.

set -euo pipefail

log() { printf '[project-resolve] %s\n' "$*" >&2; }
die() { printf '[project-resolve] ERROR: %s\n' "$*" >&2; exit 1; }

command -v atdd >/dev/null 2>&1 || die "atdd CLI not found on PATH"
command -v jq   >/dev/null 2>&1 || die "jq not found on PATH"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.atdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "no manifest at $MANIFEST — run manifest-ensure.sh first"

# 1. Explicit env override wins.
if [[ -n "${ATDD_PROJECT:-}" ]]; then
  printf '%s\n' "${ATDD_PROJECT}"
  exit 0
fi

# 2. A pinned manifest slug means the decision was already made — honour it.
PINNED="$(jq -r '.project_slug // empty' "$MANIFEST")"
if [[ -n "$PINNED" ]]; then
  printf '%s\n' "$PINNED"
  exit 0
fi

# 3. Not yet decided — consult the master registry for the home repo.
HOME_REPO="$(jq -er '.home_repo' "$MANIFEST")" || die "manifest has no home_repo"
WHERE="$(atdd repo where "$HOME_REPO")" || die "atdd repo where failed"
mapfile -t PROJECTS < <(jq -r '.projects[]? // empty' <<<"$WHERE")

case "${#PROJECTS[@]}" in
  0)
    log "${HOME_REPO} is in no project yet (first-time bootstrap)"
    exit 10
    ;;
  1)
    log "${HOME_REPO} is in exactly one project: ${PROJECTS[0]} (auto)"
    printf '%s\n' "${PROJECTS[0]}"
    exit 0
    ;;
  *)
    log "${HOME_REPO} is in ${#PROJECTS[@]} projects — ambiguous, ask the human"
    printf '%s\n' "${PROJECTS[@]}"
    exit 11
    ;;
esac
