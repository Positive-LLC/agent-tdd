#!/usr/bin/env bash
# project-set.sh — set (or switch to) the active atdd project for this repo, and
# wire everything that is per-project. Idempotent.
#
# Does, in order:
#   1. validate the slug (same rules as the atdd CLI),
#   2. `atdd project create <slug>` (idempotent; auto-creates "default" too),
#   3. register the home repo into that project (records master membership, so
#      `atdd repo where` and project-resolve.sh see it),
#   4. find-or-create the NotebookIssue IN that project (per-project numbering),
#   5. persist `project_slug` + the project's `notebook_issue` into the manifest.
#
# Usage:  project-set.sh <slug>
# Output: the manifest JSON on stdout. Progress on stderr.

set -euo pipefail

log() { printf '[project-set] %s\n' "$*" >&2; }
die() { printf '[project-set] ERROR: %s\n' "$*" >&2; exit 1; }

command -v atdd >/dev/null 2>&1 || die "atdd CLI not found on PATH"
command -v jq   >/dev/null 2>&1 || die "jq not found on PATH"

SLUG="${1:-}"
[[ -n "$SLUG" ]] || die "usage: project-set.sh <slug>"
[[ "$SLUG" =~ ^[a-z0-9][a-z0-9._-]*$ && ${#SLUG} -le 64 ]] \
  || die "invalid project slug '$SLUG' (allowed: ^[a-z0-9][a-z0-9._-]*\$, <=64 chars)"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.atdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "no manifest at $MANIFEST — run manifest-ensure.sh first"

HOME_REPO="$(jq -er '.home_repo' "$MANIFEST")" || die "manifest has no home_repo"
NOTEBOOK_LABEL="$(jq -er '.labels.notebook' "$MANIFEST")" || die "manifest has no labels.notebook"

# Every atdd call below is scoped to this project.
export ATDD_PROJECT="$SLUG"

log "ensuring project '${SLUG}' exists"
atdd project create "$SLUG" >/dev/null 2>&1 || true   # idempotent

log "registering home repo ${HOME_REPO} into '${SLUG}'"
atdd repo register "$HOME_REPO" "$REPO_ROOT" --home >/dev/null \
  || die "failed to register home repo into project '${SLUG}'"

# --- find or create the NotebookIssue in THIS project ---
log "resolving NotebookIssue (label=${NOTEBOOK_LABEL}) in ${HOME_REPO} / project ${SLUG}"
EXISTING="$(atdd issue list --repo "$HOME_REPO" --label "$NOTEBOOK_LABEL" --state open)" \
  || die "atdd issue list failed"
NB_REF="$(jq -r 'if length > 0 then .[0].ref else empty end' <<<"$EXISTING")"
if [[ -z "$NB_REF" ]]; then
  NB_TITLE="Agent TDD — Notes Agent notebook"
  NB_BODY="**Notes Agent private notebook** for home repo \`${HOME_REPO}\` in project \`${SLUG}\` (local atdd store).

Body is populated on the first \`notebook-index-update.sh\` run."
  NB_REF="$(printf '%s' "$NB_BODY" | atdd issue create \
    --repo "$HOME_REPO" --title "$NB_TITLE" --body-file - --label "$NOTEBOOK_LABEL" --porcelain)" \
    || die "failed to create NotebookIssue in project '${SLUG}'"
  log "created NotebookIssue ${NB_REF}"
else
  log "reusing existing NotebookIssue ${NB_REF}"
fi
NB_NUMBER="${NB_REF##*#}"
NB_URL="atdd://${HOME_REPO}/issues/${NB_NUMBER}"

# --- persist project_slug + notebook_issue into the manifest (atomic) ---
TMP="${MANIFEST}.tmp.$$"
jq --arg slug "$SLUG" --arg nb_url "$NB_URL" --argjson nb_num "$NB_NUMBER" \
  '.project_slug = $slug | .notebook_issue = { url: $nb_url, number: $nb_num }' \
  "$MANIFEST" > "$TMP"
mv "$TMP" "$MANIFEST"
log "set active project '${SLUG}', notebook ${NB_REF}"

jq '.' "$MANIFEST"
