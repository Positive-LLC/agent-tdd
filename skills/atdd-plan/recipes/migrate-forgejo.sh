#!/usr/bin/env bash
# migrate-forgejo.sh — one-shot: migrate all open Forgejo issues into the atdd store.
#
# Reads open issues from the Forgejo REST API (via the Makefile in atdd-cli),
# creates each as a work-item in the "atdd" project, then closes the Forgejo
# original. Idempotent: skips issues whose title already exists in the atdd
# project with the forgejo-migrated label.
#
# Usage:
#   bash skills/atdd-plan/recipes/migrate-forgejo.sh [--dry-run]
#
# Requires: atdd binary, jq, curl, make (in /home/m6/willy/atdd-cli).

set -euo pipefail

log() { printf '[migrate-forgejo] %s\n' "$*" >&2; }

ATDD_CLI_DIR="/home/m6/willy/atdd-cli"
REPO="hn12404988/atdd-cli"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# Ensure the forgejo-migrated label exists.
log "ensuring forgejo-migrated label..."
if [[ $DRY_RUN -eq 0 ]]; then
  atdd --project atdd label ensure --repo "$REPO" \
    --name forgejo-migrated --color d4c5f9 \
    --description "Migrated from Forgejo issue tracker" 2>/dev/null || true
fi

# Collect open issue numbers from Forgejo.
log "listing open Forgejo issues..."
ISSUE_NUMS=$(cd "$ATDD_CLI_DIR" && make forgejo-list 2>/dev/null \
  | jq -r 'select(.state == "open") | .number')

if [[ -z "$ISSUE_NUMS" ]]; then
  log "no open Forgejo issues found."
  exit 0
fi

COUNT=$(echo "$ISSUE_NUMS" | wc -l)
log "found $COUNT open Forgejo issues."

# Collect existing atdd titles (for skip-if-exists).
EXISTING_TITLES=$(atdd --project atdd issue list --repo "$REPO" --label forgejo-migrated 2>/dev/null \
  | jq -r '.issues[]? | .title' 2>/dev/null || echo "")

MIGRATED=0
SKIPPED=0
FAILED=0

for NUM in $ISSUE_NUMS; do
  log "--- issue #$NUM ---"

  # Fetch full issue JSON from Forgejo.
  RAW=$(cd "$ATDD_CLI_DIR" && make forgejo-get N="$NUM" 2>/dev/null)
  TITLE=$(echo "$RAW" | jq -r '.title')
  BODY=$(echo "$RAW" | jq -r '.body // ""')

  if [[ -z "$TITLE" ]]; then
    log "  SKIP: could not read title"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Skip if already migrated (title match).
  if echo "$EXISTING_TITLES" | grep -qFx "$TITLE"; then
    log "  SKIP: already migrated (title match)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    log "  DRY-RUN: would create \"$TITLE\""
    MIGRATED=$((MIGRATED + 1))
    continue
  fi

  # Create in atdd store.
  if atdd --project atdd issue create --repo "$REPO" \
    --title "$TITLE" --body "${BODY:-(migrated from Forgejo #$NUM)}" \
    --label forgejo-migrated 2>/dev/null; then
    log "  created in atdd store"

    # Close on Forgejo.
    if (cd "$ATDD_CLI_DIR" && make forgejo-close N="$NUM" 2>/dev/null); then
      log "  closed on Forgejo"
    else
      log "  WARNING: created in atdd but failed to close on Forgejo"
    fi
    MIGRATED=$((MIGRATED + 1))
  else
    log "  FAILED: could not create in atdd store"
    FAILED=$((FAILED + 1))
  fi
done

log "done: migrated=$MIGRATED skipped=$SKIPPED failed=$FAILED"
