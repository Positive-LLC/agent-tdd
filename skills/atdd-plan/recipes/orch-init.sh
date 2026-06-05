#!/usr/bin/env bash
# orch-init.sh — bootstrap the Notes-Agent orchestrator (orchestration mode).
#
# The planning <-> orchestration analogue of init-root.sh. Run ONCE, at the
# go-gate, after planning has produced >=1 ready RootIssue and the human said
# "go". Unlike planning (CORE.md §2), orchestration MUST be inside tmux — it
# spawns Root windows — so this recipe requires TMUX/TMUX_PANE, exactly as
# init-root.sh does.
#
# Usage:  orch-init.sh <gh-account> [<concurrent-root-cap>]
#
#   <gh-account>            GitHub account the orchestrator's own gh reads run
#                           under (validated against `gh auth status`; NOT
#                           switched — per-Root merges use isolated GH_CONFIG_DIR,
#                           see spawn-root.sh / ORCHESTRATE.md §4).
#   <concurrent-root-cap>   max concurrent Roots per cohort (default 3).
#
# Effects (all under the INVOKING repo's working tree — the repo the human
# launched /agent-tdd:fix from, which already carries manifest.json and a
# `.agent-tdd/.gitignore`):
#   - Atomically claims the next free notes-id (notes-1, notes-2, ...) via
#     `mkdir` (race-safe), sibling to any root-N dirs in the same repo.
#   - Captures the orchestrator's own tmux session + stable window id, anchored
#     to $TMUX_PANE (defeats client focus drift — same rationale as init-root.sh).
#   - Writes .agent-tdd/<notes-id>/meta.json (the orchestration registry; see
#     ORCHESTRATE.md §2). base_by_repo / member_repo_paths / current_rootissue /
#     roots start empty and are filled by the orchestration loop.
#
# Prints the claimed notes-id to stdout (the only stdout output). Progress to stderr.

set -euo pipefail

log() { printf '[orch-init] %s\n' "$*" >&2; }
die() { printf '[orch-init] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $# -ge 1 ]] || die "usage: orch-init.sh <gh-account> [<concurrent-root-cap>]"
GH_ACCOUNT="$1"
CONCURRENT_CAP="${2:-3}"
[[ -n "${GH_ACCOUNT}" ]] || die "gh-account must be non-empty"
[[ "${CONCURRENT_CAP}" =~ ^[0-9]+$ ]] || die "concurrent-root-cap must be an integer (got: ${CONCURRENT_CAP})"

COHORT_WALLCLOCK_CAP_SEC=21600   # 6h per-cohort ceiling (forced human checkpoint)

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

# --- validate gh account exists (do NOT switch: orchestrator reads are account
#     -agnostic; per-Root merges switch within an isolated GH_CONFIG_DIR) ---
GH_STATUS="$(gh auth status 2>&1 || true)"
if ! grep -qE "Logged in to github\.com account ${GH_ACCOUNT}( |$|\))" <<<"${GH_STATUS}"; then
  die "gh account '${GH_ACCOUNT}' is not logged in. \`gh auth status\`:
${GH_STATUS}"
fi

# --- tmux capture (orchestration requires tmux) ---
[[ -n "${TMUX:-}" ]] || die "orch-init.sh must run inside tmux (TMUX unset). Relaunch: tmux new -s atdd, then your CLI, then re-run /agent-tdd:fix."
[[ -n "${TMUX_PANE:-}" ]] || die "orch-init.sh must run inside a tmux pane (TMUX_PANE unset)."
ORCH_TMUX_SESSION="$(tmux display-message -p -t "${TMUX_PANE}" '#S' 2>/dev/null || true)"
ORCH_TMUX_WINDOW_ID="$(tmux display-message -p -t "${TMUX_PANE}" '#{window_id}' 2>/dev/null || true)"
[[ -n "${ORCH_TMUX_SESSION}" ]] || die "could not capture tmux session (#S) for pane ${TMUX_PANE}"
[[ -n "${ORCH_TMUX_WINDOW_ID}" ]] || die "could not capture tmux window id (#{window_id}) for pane ${TMUX_PANE}"
log "captured tmux session: ${ORCH_TMUX_SESSION}, window id: ${ORCH_TMUX_WINDOW_ID}"

# --- repo + manifest sanity ---
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repo"
REPO_ROOT="$(git rev-parse --show-toplevel)"
MANIFEST="${REPO_ROOT}/.agent-tdd/manifest.json"
[[ -f "${MANIFEST}" ]] || die "no manifest at ${MANIFEST} — run planning (/agent-tdd:fix) first so manifest-ensure.sh creates it"

# --- ensure .agent-tdd + its .gitignore ---
mkdir -p "${REPO_ROOT}/.agent-tdd"
GITIGNORE="${REPO_ROOT}/.agent-tdd/.gitignore"
if [[ ! -f "${GITIGNORE}" ]]; then
  printf '*\n!.gitignore\n!manifest.json\n' > "${GITIGNORE}"
fi

# --- atomic notes-id claim ---
NOTES_ID=""
STATE_DIR=""
for n in $(seq 1 32); do
  candidate="${REPO_ROOT}/.agent-tdd/notes-${n}"
  if mkdir "${candidate}" 2>/dev/null; then
    NOTES_ID="notes-${n}"
    STATE_DIR="${candidate}"
    break
  fi
done
[[ -n "${NOTES_ID}" ]] || die "could not claim a notes-id within 32 attempts; clean up stale .agent-tdd/notes-* dirs"
log "claimed orchestration id: ${NOTES_ID}"

# --- carry the manifest's home_repo + notebook for convenience ---
HOME_REPO="$(jq -r '.home_repo // empty' "${MANIFEST}")"
NB_NUMBER="$(jq -r '.notebook_issue.number // empty' "${MANIFEST}")"

# --- write meta.json ---
META="${STATE_DIR}/meta.json"
TMP="${META}.tmp.$$"
jq -n \
  --arg notes_id   "${NOTES_ID}" \
  --arg repo_root  "${REPO_ROOT}" \
  --arg home_repo  "${HOME_REPO}" \
  --arg nb         "${NB_NUMBER}" \
  --arg gh_account "${GH_ACCOUNT}" \
  --arg session    "${ORCH_TMUX_SESSION}" \
  --arg window     "${ORCH_TMUX_WINDOW_ID}" \
  --argjson cap    "${CONCURRENT_CAP}" \
  --argjson wallcap "${COHORT_WALLCLOCK_CAP_SEC}" '
  {
    notes_id:                 $notes_id,
    invoking_repo_root:       $repo_root,
    home_repo:                $home_repo,
    notebook_issue:           (if $nb == "" then null else ($nb|tonumber) end),
    gh_account:               $gh_account,
    notes_tmux_session:       $session,
    notes_tmux_window_id:     $window,
    concurrent_root_cap:      $cap,
    cohort_wallclock_cap_sec: $wallcap,
    base_by_repo:             {},
    current_rootissue:        null
  }
' > "${TMP}"
mv "${TMP}" "${META}"
log "wrote ${META}"

# --- breadcrumb log (compaction recovery) ---
printf '%s orch-init notes_id=%s cap=%s account=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo now)" \
  "${NOTES_ID}" "${CONCURRENT_CAP}" "${GH_ACCOUNT}" >> "${STATE_DIR}/orch.log"

echo "${NOTES_ID}"
