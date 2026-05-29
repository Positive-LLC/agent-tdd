#!/usr/bin/env bash
# root-undepend.sh — remove a native `blocked by` edge between two RootIssues
# (the inverse of root-depend.sh). Both arguments are RootIssue numbers in the
# manifest's home repo.
#
# Removing an edge can never create a cycle, so this skips root-depend's cycle
# check. It keeps the lighter guards: both ends must be RootIssues in the home
# repo, and the edge must actually exist (idempotent no-op otherwise).
#
# Usage:  root-undepend.sh <blocked-root#> <blocking-root#>
#   Removes "<blocked> blocked by <blocking>".
# Output: nothing on success; non-zero exit + stderr on failure.

set -euo pipefail

log() { printf '[root-undepend] %s\n' "$*" >&2; }
die() { printf '[root-undepend] ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

[[ $# -eq 2 ]] || die "usage: root-undepend.sh <blocked-root#> <blocking-root#>"
BLOCKED="$1"
BLOCKING="$2"
[[ "$BLOCKED"  =~ ^[0-9]+$ ]] || die "<blocked> must be a number (got: $BLOCKED)"
[[ "$BLOCKING" =~ ^[0-9]+$ ]] || die "<blocking> must be a number (got: $BLOCKING)"
[[ "$BLOCKED" != "$BLOCKING" ]] || die "a RootIssue cannot block itself ($BLOCKED)"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.agent-tdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found (run manifest-ensure.sh first)"
HOME_REPO="$(jq -er '.home_repo' "$MANIFEST")"
ROOT_LABEL="$(jq -er '.labels.root' "$MANIFEST")"

# Both ends must be RootIssues in the home repo.
assert_root() {
  local n="$1" labels
  labels="$(gh api "repos/${HOME_REPO}/issues/${n}" -q '.labels[].name' 2>&1)" \
    || die "failed to fetch ${HOME_REPO}#${n}: $labels"
  grep -qxF "$ROOT_LABEL" <<<"$labels" \
    || die "${HOME_REPO}#${n} does not carry '${ROOT_LABEL}' — not a RootIssue"
}
assert_root "$BLOCKED"
assert_root "$BLOCKING"

# Resolve the blocker's database id (edge is keyed by db id, supplied in path).
BLOCKING_DB_ID="$(gh api "repos/${HOME_REPO}/issues/${BLOCKING}" -q '.id' 2>&1)" \
  || die "failed to fetch ${HOME_REPO}#${BLOCKING} database id: $BLOCKING_DB_ID"

# Idempotency: only DELETE if the edge currently exists.
CURRENT_IDS="$(gh api "repos/${HOME_REPO}/issues/${BLOCKED}/dependencies/blocked_by" -q '.[].id' 2>/dev/null || true)"
if ! grep -qxF "$BLOCKING_DB_ID" <<<"$CURRENT_IDS"; then
  log "${HOME_REPO}#${BLOCKED} is not blocked by ${HOME_REPO}#${BLOCKING} — noop"
  exit 0
fi

log "removing edge: ${HOME_REPO}#${BLOCKED} blocked_by ${HOME_REPO}#${BLOCKING} (db_id=${BLOCKING_DB_ID})"
gh api -X DELETE "repos/${HOME_REPO}/issues/${BLOCKED}/dependencies/blocked_by/${BLOCKING_DB_ID}" >/dev/null \
  || die "failed to remove dependency"

log "ok"
