#!/usr/bin/env bash
# issue-close.sh — close (or reopen) an atdd-managed issue. In this workflow
# GitHub issues are never hard-deleted; "delete" in CRUD terms is the lifecycle
# transition close <-> reopen. Works for both RootIssues and SubIssues.
#
# Per CORE §9, closing a RootIssue is a deliberate Notes-Agent + human act once
# all its SubIssues are closed. This recipe is the mechanism; it does NOT decide
# WHEN to close — that judgement stays with the Notes Agent.
#
# Idempotent: closing an already-closed issue (or reopening an open one) is a
# no-op.
#
# Usage:  issue-close.sh <ref> [--reopen] [--reason <completed|not_planned>]
#   <ref>      = <owner>/<repo>#<N>
#   --reopen   = reopen instead of close
#   --reason   = close reason (default: completed). Ignored with --reopen.
# Output: <owner>/<repo>#<N> on stdout (one line).

set -euo pipefail

log() { printf '[issue-close] %s\n' "$*" >&2; }
die() { printf '[issue-close] ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

[[ $# -ge 1 ]] || die "usage: issue-close.sh <ref> [--reopen] [--reason <completed|not_planned>]"
REF="$1"; shift
[[ "$REF" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$ ]] \
  || die "ref must look like <owner>/<repo>#<N> (got: $REF)"
REPO="${BASH_REMATCH[1]}"
NUMBER="${BASH_REMATCH[2]}"

REOPEN=0
REASON="completed"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reopen) REOPEN=1; shift;;
    --reason) [[ $# -ge 2 ]] || die "--reason needs a value"; REASON="$2"; shift 2;;
    *) die "unknown argument: $1";;
  esac
done
case "$REASON" in
  completed|not_planned) ;;
  *) die "--reason must be 'completed' or 'not_planned' (got: $REASON)";;
esac

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.agent-tdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found (run manifest-ensure.sh first)"
ROOT_LABEL="$(jq -er '.labels.root' "$MANIFEST")"
SUB_LABEL="$(jq -er '.labels.sub' "$MANIFEST")"

# Guard: only act on managed issues. Fetch state + labels in one call.
ISSUE_JSON="$(gh api "repos/${REPO}/issues/${NUMBER}" 2>&1)" \
  || die "failed to fetch ${REF}: $ISSUE_JSON"
LBL_LIST="$(jq -r '.labels[].name' <<<"$ISSUE_JSON")"
grep -qxF "$ROOT_LABEL" <<<"$LBL_LIST" || grep -qxF "$SUB_LABEL" <<<"$LBL_LIST" \
  || die "${REF} carries neither '${ROOT_LABEL}' nor '${SUB_LABEL}' — not an atdd-managed issue"
# REST returns lowercase state ("open"/"closed").
STATE="$(jq -r '.state' <<<"$ISSUE_JSON" | tr '[:upper:]' '[:lower:]')"

if [[ "$REOPEN" -eq 1 ]]; then
  if [[ "$STATE" == "open" ]]; then
    log "${REF} already open — noop"
  else
    log "reopening ${REF}"
    gh issue reopen "$NUMBER" -R "$REPO" >/dev/null || die "failed to reopen ${REF}"
  fi
else
  if [[ "$STATE" == "closed" ]]; then
    log "${REF} already closed — noop"
  else
    # gh expects the reason spelled "not planned" (with a space).
    GH_REASON="completed"
    [[ "$REASON" == "not_planned" ]] && GH_REASON="not planned"
    log "closing ${REF} (reason: ${GH_REASON})"
    gh issue close "$NUMBER" -R "$REPO" --reason "$GH_REASON" >/dev/null \
      || die "failed to close ${REF}"
  fi
fi

printf '%s\n' "$REF"
