#!/usr/bin/env bash
# sub-unlink.sh — remove the native sub-issue link between a SubIssue and its
# parent RootIssue. Detaches the edge only; does not close the issue or remove
# its `atdd:sub` label. Idempotent (no-op if not currently linked).
#
# Usage:  sub-unlink.sh <sub-ref> <root-ref>
# Output: nothing on success; non-zero exit + stderr on failure.

set -euo pipefail

log() { printf '[sub-unlink] %s\n' "$*" >&2; }
die() { printf '[sub-unlink] ERROR: %s\n' "$*" >&2; exit 1; }

command -v atdd >/dev/null 2>&1 || die "atdd CLI not found on PATH"
command -v jq   >/dev/null 2>&1 || die "jq not found on PATH"

[[ $# -eq 2 ]] || die "usage: sub-unlink.sh <sub-ref> <root-ref>"
SUB_REF="$1"
ROOT_REF="$2"
[[ "$SUB_REF" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$ ]] \
  || die "sub-ref must look like <owner>/<repo>#<N> (got: $SUB_REF)"
[[ "$ROOT_REF" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#[0-9]+$ ]] \
  || die "root-ref must look like <owner>/<repo>#<N> (got: $ROOT_REF)"
PARENT_REPO="${BASH_REMATCH[1]}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.agent-tdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found (run manifest-ensure.sh first)"
HOME_REPO="$(jq -er '.home_repo' "$MANIFEST")"
ROOT_LABEL="$(jq -er '.labels.root' "$MANIFEST")"

[[ "$PARENT_REPO" == "$HOME_REPO" ]] \
  || die "parent RootIssue must live in home repo ${HOME_REPO} (got: ${PARENT_REPO})"
PARENT_VIEW="$(atdd issue view "$ROOT_REF")" || die "failed to fetch parent ${ROOT_REF}"
jq -e --arg l "$ROOT_LABEL" '.labels|index($l)' >/dev/null <<<"$PARENT_VIEW" \
  || die "parent ${ROOT_REF} does not carry '${ROOT_LABEL}' — not a RootIssue"

log "unlinking ${SUB_REF} from ${ROOT_REF}"
atdd sub unlink "$ROOT_REF" "$SUB_REF" >/dev/null || die "failed to unlink ${SUB_REF}"
log "ok"
