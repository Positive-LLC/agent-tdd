#!/usr/bin/env bash
# ready-unmark.sh — remove the `atdd:ready` label from a SubIssue (inverse of
# ready-mark.sh). Idempotent (no-op if not currently marked ready).
#
# Usage:  ready-unmark.sh <sub-ref>   (<sub-ref> = <owner>/<repo>#<N>)

set -euo pipefail

log() { printf '[ready-unmark] %s\n' "$*" >&2; }
die() { printf '[ready-unmark] ERROR: %s\n' "$*" >&2; exit 1; }

command -v atdd >/dev/null 2>&1 || die "atdd CLI not found on PATH"
command -v jq   >/dev/null 2>&1 || die "jq not found on PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_project-env.sh"

[[ $# -eq 1 ]] || die "usage: ready-unmark.sh <owner>/<repo>#<N>"
SUB_REF="$1"
[[ "$SUB_REF" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$ ]] \
  || die "sub-ref must look like <owner>/<repo>#<N> (got: $SUB_REF)"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.atdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found (run manifest-ensure.sh first)"
SUB_LABEL="$(jq -er '.labels.sub' "$MANIFEST")"
READY_LABEL="$(jq -er '.labels.ready' "$MANIFEST")"

VIEW="$(atdd issue view "$SUB_REF")" || die "failed to fetch ${SUB_REF}"
jq -e --arg l "$SUB_LABEL" '.labels|index($l)' >/dev/null <<<"$VIEW" \
  || die "${SUB_REF} does not carry '${SUB_LABEL}' — only SubIssues can be (un)marked ready"

log "removing label '${READY_LABEL}' from ${SUB_REF}"
atdd label remove "$SUB_REF" "$READY_LABEL" >/dev/null || die "failed to remove label"
log "ok"
