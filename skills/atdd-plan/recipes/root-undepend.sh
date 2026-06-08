#!/usr/bin/env bash
# root-undepend.sh — remove a native `blocked by` edge between two RootIssues
# (inverse of root-depend.sh). Idempotent (no-op if the edge is absent).
#
# Usage:  root-undepend.sh <blocked-root#> <blocking-root#>
# Output: nothing on success; non-zero exit + stderr on failure.

set -euo pipefail

log() { printf '[root-undepend] %s\n' "$*" >&2; }
die() { printf '[root-undepend] ERROR: %s\n' "$*" >&2; exit 1; }

command -v atdd >/dev/null 2>&1 || die "atdd CLI not found on PATH"
command -v jq   >/dev/null 2>&1 || die "jq not found on PATH"

[[ $# -eq 2 ]] || die "usage: root-undepend.sh <blocked-root#> <blocking-root#>"
BLOCKED="$1"
BLOCKING="$2"
[[ "$BLOCKED"  =~ ^[0-9]+$ ]] || die "<blocked> must be a number (got: $BLOCKED)"
[[ "$BLOCKING" =~ ^[0-9]+$ ]] || die "<blocking> must be a number (got: $BLOCKING)"
[[ "$BLOCKED" != "$BLOCKING" ]] || die "a RootIssue cannot block itself ($BLOCKED)"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.atdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found (run manifest-ensure.sh first)"
HOME_REPO="$(jq -er '.home_repo' "$MANIFEST")"
ROOT_LABEL="$(jq -er '.labels.root' "$MANIFEST")"

BLOCKED_REF="${HOME_REPO}#${BLOCKED}"
BLOCKING_REF="${HOME_REPO}#${BLOCKING}"

assert_root() {
  local ref="$1" view
  view="$(atdd issue view "$ref")" || die "${ref} not found"
  jq -e --arg l "$ROOT_LABEL" '.labels|index($l)' >/dev/null <<<"$view" \
    || die "${ref} is not a RootIssue (missing '${ROOT_LABEL}')"
}
assert_root "$BLOCKED_REF"
assert_root "$BLOCKING_REF"

log "removing edge: ${BLOCKED_REF} blocked_by ${BLOCKING_REF}"
atdd dep remove "$BLOCKED_REF" "$BLOCKING_REF" >/dev/null || die "failed to remove dependency"
log "ok"
