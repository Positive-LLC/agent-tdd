#!/usr/bin/env bash
# root-depend.sh — add a native `blocked by` edge between two RootIssues. Both
# args are RootIssue numbers in the manifest's home repo.
#
# Invariants (the atdd store enforces self-loop + cycle; this recipe adds the
# same-graph guard so callers get a clear message):
#   1. No self-loop : reject if <blocked> == <blocking>.
#   2. No cycle      : the store rejects an edge that would close a loop.
#   3. Same-graph    : both ends must carry `atdd:root`.
#
# Usage:  root-depend.sh <blocked-root-number> <blocking-root-number>
# Output: nothing on success; non-zero exit + stderr message on rejection.

set -euo pipefail

log() { printf '[root-depend] %s\n' "$*" >&2; }
die() { printf '[root-depend] ERROR: %s\n' "$*" >&2; exit 1; }

command -v atdd >/dev/null 2>&1 || die "atdd CLI not found on PATH"
command -v jq   >/dev/null 2>&1 || die "jq not found on PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_project-env.sh"

[[ $# -eq 2 ]] || die "usage: root-depend.sh <blocked-root#> <blocking-root#>"
BLOCKED="$1"
BLOCKING="$2"
[[ "$BLOCKED"  =~ ^[0-9]+$ ]] || die "<blocked> must be a number (got: $BLOCKED)"
[[ "$BLOCKING" =~ ^[0-9]+$ ]] || die "<blocking> must be a number (got: $BLOCKING)"
[[ "$BLOCKED" != "$BLOCKING" ]] || die "rule#1 self-loop: $BLOCKED depends on itself"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.atdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found (run manifest-ensure.sh first)"
HOME_REPO="$(jq -er '.home_repo' "$MANIFEST")"
ROOT_LABEL="$(jq -er '.labels.root' "$MANIFEST")"

BLOCKED_REF="${HOME_REPO}#${BLOCKED}"
BLOCKING_REF="${HOME_REPO}#${BLOCKING}"

assert_root() {
  local ref="$1" view
  view="$(atdd issue view "$ref")" || die "rule#3 same-graph: ${ref} not found"
  jq -e --arg l "$ROOT_LABEL" '.labels|index($l)' >/dev/null <<<"$view" \
    || die "rule#3 same-graph: ${ref} is not a RootIssue (missing '${ROOT_LABEL}')"
}
assert_root "$BLOCKED_REF"
assert_root "$BLOCKING_REF"

log "adding ${BLOCKED_REF} blocked_by ${BLOCKING_REF}"
# The store enforces rule#2 (cycle) and rejects with a clear message.
atdd dep add "$BLOCKED_REF" "$BLOCKING_REF" >/dev/null \
  || die "rule#2 cycle (or store error): refused '${BLOCKED_REF} blocked by ${BLOCKING_REF}'"
log "ok"
