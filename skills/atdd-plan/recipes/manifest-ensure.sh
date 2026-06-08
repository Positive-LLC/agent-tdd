#!/usr/bin/env bash
# manifest-ensure.sh — read or create ${REPO_ROOT}/.agent-tdd/manifest.json.
#
# Phase 1: the GitHubProject is gone. The manifest now records only the home
# repo, the NotebookIssue (in the local atdd store), the label names, and the
# orchestration member-repo registry. Topology membership is implicit (any
# work-item labelled `atdd:root`).
#
# Usage:
#   manifest-ensure.sh                 # interactive bootstrap on first run
#   manifest-ensure.sh <home-repo>     # non-interactive bootstrap (CI/tests)
#   manifest-ensure.sh --resolve-member <owner/repo>
#   manifest-ensure.sh --register-member <owner/repo> <abs-local-path>
#
# Output: manifest JSON on stdout. Progress on stderr.

set -euo pipefail

log() { printf '[manifest-ensure] %s\n' "$*" >&2; }
die() { printf '[manifest-ensure] ERROR: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "not inside a git repo — manifest is per-repo, run from the repo you're planning in"
MANIFEST_DIR="${REPO_ROOT}/.agent-tdd"
MANIFEST="${MANIFEST_DIR}/manifest.json"

# --- member-repo registry subcommands (orchestration mode) -------------------
# Pure local git/jq — these never touch GitHub or the atdd store. See CORE.md §4.

# origin "owner/repo" of a local clone (parses ssh or https origin URL).
origin_nwo() {
  local path="$1" url
  url="$(git -C "${path}" remote get-url origin 2>/dev/null)" || return 1
  url="${url%.git}"
  case "${url}" in
    *github.com:*)  printf '%s\n' "${url##*github.com:}" ;;
    *github.com/*)  printf '%s\n' "${url##*github.com/}" ;;
    *) return 1 ;;
  esac
}

if [[ "${1:-}" == "--resolve-member" ]]; then
  REPO_REF="${2:-}"
  [[ -n "${REPO_REF}" ]] || die "usage: manifest-ensure.sh --resolve-member <owner/repo>"
  [[ -f "$MANIFEST" ]] || die "no manifest at $MANIFEST — run planning first"
  LOCAL="$(jq -r --arg r "${REPO_REF}" '.members[$r].local_path // empty' "$MANIFEST")"
  [[ -n "${LOCAL}" ]] || { log "no recorded local_path for ${REPO_REF}"; exit 3; }
  [[ -d "${LOCAL}" ]] || { log "recorded local_path for ${REPO_REF} no longer exists: ${LOCAL}"; exit 3; }
  GOT="$(origin_nwo "${LOCAL}" || true)"
  if [[ "${GOT}" != "${REPO_REF}" ]]; then
    log "recorded path ${LOCAL} is not a clone of ${REPO_REF} (origin: ${GOT:-none})"
    exit 3
  fi
  printf '%s\n' "${LOCAL}"
  exit 0
fi

if [[ "${1:-}" == "--register-member" ]]; then
  REPO_REF="${2:-}"; LOCAL="${3:-}"
  [[ -n "${REPO_REF}" && -n "${LOCAL}" ]] || die "usage: manifest-ensure.sh --register-member <owner/repo> <abs-local-path>"
  [[ -f "$MANIFEST" ]] || die "no manifest at $MANIFEST — run planning first"
  [[ "${LOCAL}" = /* ]] || die "local path must be absolute (got: ${LOCAL})"
  [[ -d "${LOCAL}" ]] || die "local path does not exist: ${LOCAL}"
  git -C "${LOCAL}" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: ${LOCAL}"
  GOT="$(origin_nwo "${LOCAL}" || true)"
  [[ "${GOT}" == "${REPO_REF}" ]] || die "path ${LOCAL} origin is '${GOT:-none}', not ${REPO_REF} — refusing (would send a Root to the wrong repo)"
  TMP="${MANIFEST}.tmp.$$"
  jq --arg r "${REPO_REF}" --arg p "${LOCAL}" \
    '.members = ((.members // {}) + { ($r): { local_path: $p } })' \
    "$MANIFEST" > "$TMP"
  mv "$TMP" "$MANIFEST"
  log "registered member ${REPO_REF} -> ${LOCAL}"
  printf '%s\n' "${LOCAL}"
  exit 0
fi

# --- fast path: manifest exists, just print it ---
if [[ -f "$MANIFEST" ]]; then
  jq '.' "$MANIFEST"
  exit 0
fi

command -v atdd >/dev/null 2>&1 || die "atdd CLI not found on PATH (needed to bootstrap the NotebookIssue)"
log "no manifest at $MANIFEST — bootstrapping"

HOME_REPO="${1:-}"
if [[ -z "$HOME_REPO" ]]; then
  printf 'Home repo (e.g. Positive-LLC/pg-agent-erp) — where the NotebookIssue + RootIssues live: ' >&2
  read -r HOME_REPO
fi
[[ "$HOME_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || die "home repo must look like owner/name (got: $HOME_REPO)"

NOTEBOOK_LABEL="atdd:notebook"
ROOT_LABEL="atdd:root"
SUB_LABEL="atdd:sub"
READY_LABEL="atdd:ready"

# --- find or create the NotebookIssue in the local store ---
log "looking for an existing NotebookIssue (label=${NOTEBOOK_LABEL}) in ${HOME_REPO}"
EXISTING="$(atdd issue list --repo "$HOME_REPO" --label "$NOTEBOOK_LABEL" --state open)" \
  || die "atdd issue list failed"
NB_REF="$(jq -r 'if length > 0 then .[0].ref else empty end' <<<"$EXISTING")"

if [[ -z "$NB_REF" ]]; then
  log "no NotebookIssue found — creating one"
  NB_TITLE="Agent TDD — Notes Agent notebook"
  NB_BODY="**Notes Agent private notebook** for home repo \`${HOME_REPO}\` (local atdd store).

Body is populated on the first \`notebook-index-update.sh\` run."
  NB_REF="$(printf '%s' "$NB_BODY" | atdd issue create \
    --repo "$HOME_REPO" --title "$NB_TITLE" --body-file - --label "$NOTEBOOK_LABEL" --porcelain)" \
    || die "failed to create NotebookIssue"
  log "created NotebookIssue ${NB_REF}"
else
  log "reusing existing NotebookIssue ${NB_REF}"
fi
NB_NUMBER="${NB_REF##*#}"
NB_URL="atdd://${HOME_REPO}/issues/${NB_NUMBER}"

# --- write manifest atomically ---
mkdir -p "$MANIFEST_DIR"
GITIGNORE="${MANIFEST_DIR}/.gitignore"
if [[ ! -f "$GITIGNORE" ]]; then
  printf '*\n!.gitignore\n!manifest.json\n' > "$GITIGNORE"
fi

TMP="${MANIFEST}.tmp.$$"
jq -n \
  --arg home    "$HOME_REPO" \
  --arg nb_url  "$NB_URL" \
  --argjson nb_num "$NB_NUMBER" \
  --arg lbl_nb  "$NOTEBOOK_LABEL" \
  --arg lbl_rt  "$ROOT_LABEL" \
  --arg lbl_sb  "$SUB_LABEL" \
  --arg lbl_rd  "$READY_LABEL" '
  {
    home_repo: $home,
    notebook_issue: { url: $nb_url, number: $nb_num },
    labels: { notebook: $lbl_nb, root: $lbl_rt, sub: $lbl_sb, ready: $lbl_rd }
  }
' > "$TMP"
mv "$TMP" "$MANIFEST"
log "wrote $MANIFEST"

jq '.' "$MANIFEST"
