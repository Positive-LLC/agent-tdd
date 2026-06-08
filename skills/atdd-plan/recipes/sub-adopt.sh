#!/usr/bin/env bash
# sub-adopt.sh — adopt an EXISTING work-item into the planning graph as a
# SubIssue (it must already exist in the atdd store). Does not create an issue;
# it performs the wiring: label `atdd:sub` + link as a native sub-issue of the
# RootIssue. Idempotent (label/link are no-ops if already present).
#
# Usage:  sub-adopt.sh <target-repo> <existing-issue#> <root-ref>
# Output: <target-owner>/<target-repo>#<N> on stdout (one line).

set -euo pipefail

log() { printf '[sub-adopt] %s\n' "$*" >&2; }
die() { printf '[sub-adopt] ERROR: %s\n' "$*" >&2; exit 1; }

command -v atdd >/dev/null 2>&1 || die "atdd CLI not found on PATH"
command -v jq   >/dev/null 2>&1 || die "jq not found on PATH"

[[ $# -eq 3 ]] || die "usage: sub-adopt.sh <target-repo> <existing-issue#> <root-ref>"
TARGET_REPO="$1"
CHILD_NUMBER="$2"
ROOT_REF="$3"

[[ "$TARGET_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || die "target-repo must look like owner/name (got: $TARGET_REPO)"
[[ "$CHILD_NUMBER" =~ ^[0-9]+$ ]] \
  || die "existing-issue# must be an integer (got: $CHILD_NUMBER)"
[[ "$ROOT_REF" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$ ]] \
  || die "root-ref must look like <owner>/<repo>#<N> (got: $ROOT_REF)"
PARENT_REPO="${BASH_REMATCH[1]}"
CHILD_REF="${TARGET_REPO}#${CHILD_NUMBER}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.atdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found (run manifest-ensure.sh first)"

HOME_REPO="$(jq -er '.home_repo' "$MANIFEST")"
SUB_LABEL="$(jq -er '.labels.sub' "$MANIFEST")"
ROOT_LABEL="$(jq -er '.labels.root' "$MANIFEST")"

[[ "$PARENT_REPO" == "$HOME_REPO" ]] \
  || die "parent RootIssue must live in home repo ${HOME_REPO} (got: ${PARENT_REPO})"
PARENT_VIEW="$(atdd issue view "$ROOT_REF")" || die "failed to fetch parent ${ROOT_REF}"
jq -e --arg l "$ROOT_LABEL" '.labels|index($l)' >/dev/null <<<"$PARENT_VIEW" \
  || die "parent ${ROOT_REF} does not carry '${ROOT_LABEL}' — not a RootIssue"

CHILD_VIEW="$(atdd issue view "$CHILD_REF")" || die "issue ${CHILD_REF} not found in store"
# Refuse to adopt a RootIssue as a SubIssue — that would corrupt the topology.
jq -e --arg l "$ROOT_LABEL" '.labels|index($l)' >/dev/null <<<"$CHILD_VIEW" \
  && die "${CHILD_REF} carries '${ROOT_LABEL}' (it is a RootIssue) — cannot adopt as a SubIssue" || true

log "labelling ${CHILD_REF} '${SUB_LABEL}' and linking under ${ROOT_REF} (idempotent)"
atdd label add "$CHILD_REF" "$SUB_LABEL" >/dev/null || die "failed to label ${CHILD_REF}"
atdd sub link "$ROOT_REF" "$CHILD_REF" >/dev/null || die "failed to link ${CHILD_REF}"

printf '%s\n' "$CHILD_REF"
