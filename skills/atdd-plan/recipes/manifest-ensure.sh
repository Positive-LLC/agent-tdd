#!/usr/bin/env bash
# manifest-ensure.sh — read or create ${REPO_ROOT}/.agent-tdd/manifest.json.
#
# If the manifest exists, this is a pure read: prints the JSON to stdout.
# If it does not exist, the recipe asks for inputs interactively (the Notes
# Agent forwards each question to the human), creates the NotebookIssue,
# writes the manifest, then prints it.
#
# Inputs requested when bootstrapping:
#   - GitHubProject URL — org- or user-owned, i.e.
#     https://github.com/orgs/<org>/projects/<n> or
#     https://github.com/users/<user>/projects/<n>
#   - home repo (e.g. Positive-LLC/pg-agent-erp)
#
# Usage:
#   manifest-ensure.sh                         # interactive on first run
#   manifest-ensure.sh <project-url> <home-repo>   # non-interactive (CI/tests)
#
# Output: manifest JSON on stdout. Progress on stderr.

set -euo pipefail

log() { printf '[manifest-ensure] %s\n' "$*" >&2; }
die() { printf '[manifest-ensure] ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "not inside a git repo — manifest is per-repo, run from the repo you're planning in"
MANIFEST_DIR="${REPO_ROOT}/.agent-tdd"
MANIFEST="${MANIFEST_DIR}/manifest.json"

# --- fast path: manifest exists, just print it ---
if [[ -f "$MANIFEST" ]]; then
  jq '.' "$MANIFEST"
  exit 0
fi

log "no manifest at $MANIFEST — bootstrapping"

# --- gather inputs ---
PROJECT_URL="${1:-}"
HOME_REPO="${2:-}"

if [[ -z "$PROJECT_URL" ]]; then
  printf 'GitHubProject URL (https://github.com/orgs/<org>/projects/<n> or .../users/<user>/projects/<n>): ' >&2
  read -r PROJECT_URL
fi
[[ -n "$PROJECT_URL" ]] || die "project URL is required"

# Parse owner + number from the URL.
if [[ "$PROJECT_URL" =~ /orgs/([^/]+)/projects/([0-9]+) ]]; then
  PROJECT_OWNER="${BASH_REMATCH[1]}"
  PROJECT_NUMBER="${BASH_REMATCH[2]}"
elif [[ "$PROJECT_URL" =~ /users/([^/]+)/projects/([0-9]+) ]]; then
  PROJECT_OWNER="${BASH_REMATCH[1]}"
  PROJECT_NUMBER="${BASH_REMATCH[2]}"
else
  die "could not parse owner+number from URL: $PROJECT_URL"
fi

if [[ -z "$HOME_REPO" ]]; then
  printf 'Home repo (e.g. Positive-LLC/pg-agent-erp) — where NotebookIssue + RootIssues will live: ' >&2
  read -r HOME_REPO
fi
[[ "$HOME_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || die "home repo must look like owner/name (got: $HOME_REPO)"

# --- resolve project ID + title (owner-agnostic: org- AND user-owned projects) ---
# `gh project view` accepts any owner login; the old GraphQL organization(login:)
# lookup returned null for user-owned projects (/users/<user>/projects/<n>).
log "resolving project ${PROJECT_OWNER}/#${PROJECT_NUMBER}"
# Capture stdout only — gh notices on stderr must not be folded into the
# parsed JSON. gh's own error text flows through to our stderr on failure.
PROJ_JSON="$(gh project view "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json)" \
  || die "project lookup failed (does the token have 'project' scope? does the project exist?)"

PROJECT_ID="$(jq -er '.id // empty' <<<"$PROJ_JSON")" \
  || die "could not resolve project id from: $PROJ_JSON"
PROJECT_TITLE="$(jq -er '.title // empty' <<<"$PROJ_JSON")" \
  || die "could not resolve project title from: $PROJ_JSON"
log "project resolved: id=${PROJECT_ID} title='${PROJECT_TITLE}'"

# --- ensure labels exist in the home repo ---
NOTEBOOK_LABEL="atdd:notebook"
ROOT_LABEL="atdd:root"
SUB_LABEL="atdd:sub"
READY_LABEL="atdd:ready"

ensure_label() {
  local label="$1" desc="$2" color="$3"
  if ! gh api "repos/${HOME_REPO}/labels/${label}" >/dev/null 2>&1; then
    log "creating label '${label}' in ${HOME_REPO}"
    gh api -X POST "repos/${HOME_REPO}/labels" \
      -f name="$label" -f description="$desc" -f color="$color" >/dev/null \
      || die "failed to create label ${label}"
  fi
}
ensure_label "$NOTEBOOK_LABEL" "Agent TDD Notes Agent private notebook"            "5319e7"
ensure_label "$ROOT_LABEL"     "Agent TDD planning RootIssue (head)"               "0e8a16"
ensure_label "$SUB_LABEL"      "Agent TDD planning SubIssue (per-repo work unit)"  "1d76db"
ensure_label "$READY_LABEL"    "SubIssue is ready for /atdd to consume"            "fbca04"

# --- find or create NotebookIssue ---
log "searching for existing NotebookIssue (label=${NOTEBOOK_LABEL}) in ${HOME_REPO}"
EXISTING="$(gh issue list -R "$HOME_REPO" --label "$NOTEBOOK_LABEL" --state open \
  --json number,url --limit 5)" || die "issue list failed"
NB_NUMBER="$(jq -r 'if length > 0 then .[0].number else empty end' <<<"$EXISTING")"
NB_URL="$(jq -r 'if length > 0 then .[0].url else empty end' <<<"$EXISTING")"

if [[ -z "$NB_NUMBER" ]]; then
  log "no NotebookIssue found — creating one"
  NB_TITLE="Agent TDD — Notes Agent notebook"
  NB_BODY=$(cat <<EOF
**Notes Agent private notebook** for GitHubProject [${PROJECT_TITLE}](${PROJECT_URL}).

This issue is the durable working memory of the Agent TDD Notes Agent. The
body holds the topology index of every RootIssue; one comment per RootIssue
holds that head's detailed notes (look for a leading
\`<!-- atdd-head: <owner>/<repo>#<N> -->\` marker).

Maintained by the recipes under \`skills/atdd-plan/recipes/\` of
\`Positive-LLC/agent-tdd\`. Do not edit manually — re-run
\`notebook-index-update.sh\` instead.

> _Body will be populated on the first \`notebook-index-update.sh\` run._
EOF
)
  NB_URL="$(gh issue create -R "$HOME_REPO" \
    --title "$NB_TITLE" \
    --body "$NB_BODY" \
    --label "$NOTEBOOK_LABEL")"
  NB_NUMBER="$(basename "$NB_URL")"
  log "created NotebookIssue: ${NB_URL}"

  # Add NotebookIssue to the Project too (so it's discoverable from the board,
  # even if you keep it filtered out of work views).
  gh project item-add "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --url "$NB_URL" >/dev/null \
    || log "WARNING: failed to add NotebookIssue to project (continuing — it can be added manually)"
else
  log "reusing existing NotebookIssue: ${NB_URL}"
fi

# --- write manifest atomically ---
mkdir -p "$MANIFEST_DIR"

# Self-contained .gitignore so the agent's working files never sneak into git.
GITIGNORE="${MANIFEST_DIR}/.gitignore"
if [[ ! -f "$GITIGNORE" ]]; then
  printf '*\n!.gitignore\n!manifest.json\n' > "$GITIGNORE"
fi

TMP="${MANIFEST}.tmp.$$"
jq -n \
  --arg url     "$PROJECT_URL" \
  --argjson num "$PROJECT_NUMBER" \
  --arg id      "$PROJECT_ID" \
  --arg title   "$PROJECT_TITLE" \
  --arg owner   "$PROJECT_OWNER" \
  --arg home    "$HOME_REPO" \
  --arg nb_url  "$NB_URL" \
  --argjson nb_num "$NB_NUMBER" \
  --arg lbl_nb  "$NOTEBOOK_LABEL" \
  --arg lbl_rt  "$ROOT_LABEL" \
  --arg lbl_sb  "$SUB_LABEL" \
  --arg lbl_rd  "$READY_LABEL" '
  {
    project: { url: $url, number: $num, id: $id, title: $title, owner: $owner },
    home_repo: $home,
    notebook_issue: { url: $nb_url, number: $nb_num },
    labels: { notebook: $lbl_nb, root: $lbl_rt, sub: $lbl_sb, ready: $lbl_rd }
  }
' > "$TMP"
mv "$TMP" "$MANIFEST"
log "wrote $MANIFEST"

jq '.' "$MANIFEST"
