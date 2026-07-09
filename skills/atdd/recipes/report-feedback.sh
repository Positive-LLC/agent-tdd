#!/usr/bin/env bash
# report-feedback.sh — upsert an agent feedback issue in the atdd project store.
#
# ATDD is in early alpha. When any agent (Root, Test, Impl, Rebase, Notes) hits
# friction — a bug, confusing UX, repeated error, or a design idea — it calls
# this script to file (or augment) an issue in the "atdd" project.
#
# Upsert logic:
#   1. List open issues carrying the agent-feedback label.
#   2. If an existing issue's title shares keywords with --summary, add a
#      comment to that issue (avoids duplicates).
#   3. Otherwise, create a new issue with the agent-feedback label.
#
# Usage:
#   report-feedback.sh --summary "<one line>" [--role <r>] [--body "<detail>"]
#   printf '<detail>' | report-feedback.sh --summary "..." --role test
#
#   --summary   REQUIRED one-line gist (becomes the issue title after "[feedback]").
#   --role      the reporting agent (test|impl|root|rebase|notes).
#               Defaults to $ATDD_ROLE (set for Test/Impl by their launch env).
#   --body      optional rich detail (mutually exclusive with stdin pipe).
#   STDIN       optional rich body (read only when piped, never blocks on TTY).
#
# Non-blocking guarantee: uses set -uo pipefail (no -e). Any failure = silent
# no-op (exit 0). This must never abort the agent's real TDD task.
#
# exit: 0 always (success or graceful no-op) · 2 = bad args.

set -uo pipefail

log() { printf '[report-feedback] %s\n' "$*" >&2; }
die() { printf '[report-feedback] ERROR: %s\n' "$*" >&2; exit 2; }

SUMMARY=""
ROLE="${ATDD_ROLE:-unknown}"
BODY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --summary) SUMMARY="${2:-}"; shift 2 ;;
    --role)    ROLE="${2:-}";    shift 2 ;;
    --body)    BODY="${2:-}";    shift 2 ;;
    *) die "unknown arg: $1 (usage: report-feedback.sh --summary \"<one line>\" [--role <r>] [--body \"...\"])" ;;
  esac
done

[[ -n "$SUMMARY" ]] || die "--summary \"<one line>\" is required"

# Optional body from stdin (only when piped — never block on TTY).
if [[ -z "$BODY" ]] && [[ ! -t 0 ]]; then BODY="$(cat)"; fi

# Metadata (best-effort, never fatal).
PROJECT="${ATDD_PROJECT:-unknown}"
REPO="hn12404988/atdd-cli"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
WORKING_REPO="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo unknown)" 2>/dev/null || echo unknown)"
VER="unknown"
if command -v atdd >/dev/null 2>&1; then
  VER="$(atdd --version 2>/dev/null | awk '{print $NF}')"
  VER="${VER:-unknown}"
fi

# Format the issue/comment body.
format_body() {
  printf '## Agent Feedback\n\n'
  printf -- '- **Role:** %s\n' "$ROLE"
  printf -- '- **Project:** %s\n' "$PROJECT"
  printf -- '- **Repo:** %s\n' "$WORKING_REPO"
  printf -- '- **atdd version:** %s\n' "$VER"
  printf -- '- **When:** %s\n\n' "$TS"
  printf '## Summary\n%s\n\n' "$SUMMARY"
  printf '## Detail\n%s\n' "${BODY:-(none)}"
}

REPORT_BODY="$(format_body)"

# --- Upsert logic ---

# 1. List existing open feedback issues.
EXISTING=$(atdd --project atdd issue list --repo "$REPO" --label agent-feedback --state open 2>/dev/null || echo '{"issues":[]}')

# 2. Extract significant keywords from summary (words >= 4 chars, lowercase).
KEYWORDS=$(echo "$SUMMARY" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | awk 'length >= 4')

MATCH_REF=""
MATCH_SCORE=0

# 3. Score each existing issue by keyword overlap.
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  REF=$(echo "$line" | jq -r '.ref // ""')
  TITLE=$(echo "$line" | jq -r '.title // ""')
  [[ -z "$REF" || -z "$TITLE" ]] && continue

  TITLE_LOWER=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]')
  SCORE=0
  while IFS= read -r kw; do
    [[ -z "$kw" ]] && continue
    if echo "$TITLE_LOWER" | grep -q "$kw"; then
      SCORE=$((SCORE + 1))
    fi
  done <<< "$KEYWORDS"

  # Match threshold: at least 2 keywords overlap, or 1 keyword if summary is short.
  KW_COUNT=$(echo "$KEYWORDS" | grep -c . || true)
  THRESHOLD=2
  [[ "$KW_COUNT" -le 2 ]] && THRESHOLD=1

  if [[ "$SCORE" -ge "$THRESHOLD" ]] && [[ "$SCORE" -gt "$MATCH_SCORE" ]]; then
    MATCH_REF="$REF"
    MATCH_SCORE="$SCORE"
  fi
done < <(echo "$EXISTING" | jq -c '.issues[]? | {ref, title}' 2>/dev/null)

# 4. Upsert: comment on match, or create new.
if [[ -n "$MATCH_REF" ]]; then
  log "found similar issue: $MATCH_REF (score=$MATCH_SCORE) — adding comment"
  if atdd --project atdd comment add "$MATCH_REF" --body "$REPORT_BODY" 2>/dev/null; then
    log "comment added to $MATCH_REF"
  else
    log "failed to add comment — falling back to create"
    atdd --project atdd issue create --repo "$REPO" \
      --title "[feedback] $SUMMARY" --body "$REPORT_BODY" \
      --label agent-feedback 2>/dev/null \
      && log "new issue created (fallback)" \
      || log "create also failed — feedback dropped silently"
  fi
else
  log "no similar issue found — creating new issue"
  if atdd --project atdd issue create --repo "$REPO" \
    --title "[feedback] $SUMMARY" --body "$REPORT_BODY" \
    --label agent-feedback 2>/dev/null; then
    log "new feedback issue created"
  else
    log "failed to create issue — feedback dropped silently"
  fi
fi

exit 0
