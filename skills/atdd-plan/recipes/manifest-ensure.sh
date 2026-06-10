#!/usr/bin/env bash
# manifest-ensure.sh — read or create ${REPO_ROOT}/.atdd/manifest.json.
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
MANIFEST_DIR="${REPO_ROOT}/.atdd"
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

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# --- fast path: manifest is COMPLETE (a project is already pinned) ---
if [[ -f "$MANIFEST" ]] && [[ -n "$(jq -r '.project_slug // empty' "$MANIFEST" 2>/dev/null)" ]]; then
  jq '.' "$MANIFEST"
  exit 0
fi

command -v atdd >/dev/null 2>&1 || die "atdd CLI not found on PATH (needed to bootstrap)"

# --- ensure a skeleton manifest (home_repo + labels); the project + NotebookIssue
#     are wired per-project by project-set.sh below (the notebook is per-project) ---
if [[ ! -f "$MANIFEST" ]]; then
  log "no manifest at $MANIFEST — bootstrapping skeleton"
  HOME_REPO="${1:-}"
  if [[ -z "$HOME_REPO" ]]; then
    printf 'Home repo (e.g. Positive-LLC/pg-agent-erp) — where the NotebookIssue + RootIssues live: ' >&2
    read -r HOME_REPO
  fi
  [[ "$HOME_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || die "home repo must look like owner/name (got: $HOME_REPO)"
  mkdir -p "$MANIFEST_DIR"
  GITIGNORE="${MANIFEST_DIR}/.gitignore"
  [[ -f "$GITIGNORE" ]] || printf '*\n!.gitignore\n!manifest.json\n' > "$GITIGNORE"
  TMP="${MANIFEST}.tmp.$$"
  jq -n --arg home "$HOME_REPO" '
    {
      home_repo: $home,
      labels: { notebook: "atdd:notebook", root: "atdd:root", sub: "atdd:sub", ready: "atdd:ready" }
    }
  ' > "$TMP"
  mv "$TMP" "$MANIFEST"
  log "wrote skeleton $MANIFEST"
else
  log "skeleton manifest exists but no project pinned yet — resolving"
fi

# --- resolve the active project, asking the human ONLY when ambiguous ---
SLUG="${2:-}"   # an explicit slug (non-interactive / scripted) wins.
if [[ -z "$SLUG" ]]; then
  set +e
  CANDIDATES="$("${HERE}/project-resolve.sh")"; RC=$?
  set -e
  case "$RC" in
    0)  SLUG="$CANDIDATES" ;;                                  # env-set or single project
    10)                                                        # zero projects: first-time
        if [[ -t 0 ]]; then
          printf 'Project slug [default]: ' >&2
          read -r SLUG; SLUG="${SLUG:-default}"
        else
          SLUG="default"
        fi
        ;;
    11)                                                        # ambiguous: cannot auto-pick
        log "home repo belongs to multiple projects: ${CANDIDATES//$'\n'/, }"
        die "ambiguous project — re-run with a slug (manifest-ensure.sh <home> <slug>) or run project-set.sh <slug>"
        ;;
    *)  die "project-resolve.sh failed (rc=$RC)" ;;
  esac
fi

# project-set.sh creates the project, registers the home repo, finds/creates the
# per-project NotebookIssue, pins project_slug + notebook_issue, and prints the
# completed manifest.
exec "${HERE}/project-set.sh" "$SLUG"
