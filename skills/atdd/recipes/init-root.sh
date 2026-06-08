#!/usr/bin/env bash
# init-root.sh — bootstrap a Root for Agent TDD.
#
# Usage:  init-root.sh <root-task-slug> <base-branch> <gh-account>
#
# All three arguments are required. There is no default for <base-branch>
# or <gh-account>: Root must explicitly ask the human in Wave 0 and pass the
# answers through verbatim. This guards against silent assumption of `main`
# and silent reuse of whichever GitHub account `gh` happened to have active.
#
# Effects:
#   - Atomically claims the next available root-id (root-1, root-2, ...) by
#     using `mkdir` (without -p) as the claim primitive — race-safe under
#     concurrent inits in the same repo.
#   - Creates integration branch `agent-tdd/<root-task-slug>` off <base-branch>
#     WITHOUT mutating the main worktree's HEAD (uses `git branch`, not
#     `git checkout -b`).
#   - Pushes integration branch to origin.
#   - Adds a private Root worktree at `.agent-tdd/<root-id>/root/` checked out
#     on the integration branch. Root's tmux window will `cd` into this path.
#   - Writes `.agent-tdd/.gitignore` containing `*` (self-contained — does NOT
#     touch the repo's root .gitignore).
#   - Writes `.agent-tdd/<root-id>/meta.json` (includes absolute root_worktree).
#
# Prints the chosen root-id to stdout (the only stdout output — Root reads it).
# All progress messages go to stderr.

set -euo pipefail

log() { printf '[init-root] %s\n' "$*" >&2; }
die() { printf '[init-root] ERROR: %s\n' "$*" >&2; exit 1; }

# --- args ---
[[ $# -eq 3 ]] || die "usage: init-root.sh <root-task-slug> <base-branch> <gh-account> (all three required; no defaults — ask the human in Wave 0)"
ROOT_TASK="$1"
BASE_BRANCH="$2"
GH_ACCOUNT="$3"
[[ -n "$BASE_BRANCH" ]] || die "base-branch must be non-empty (got: '')"
[[ -n "$GH_ACCOUNT" ]] || die "gh-account must be non-empty (got: '')"

[[ "$ROOT_TASK" =~ ^[a-z0-9-]+$ ]] || die "root-task must match ^[a-z0-9-]+$ (got: $ROOT_TASK)"

MAX_WAVES=10

# --- gh account ---
# Phase 1: the inner flow has NO GitHub, so there is nothing to validate or
# switch here. `<gh-account>` is retained only as an opaque string recorded in
# meta.json for the single OPTIONAL final hand-off PR to base (PROTOCOL §8),
# which is the one place `gh` may still be used. No `gh auth` in the inner flow.

# --- capture caller's tmux session and window ID ---
# The plugin does not prescribe a session name. Whatever session the human
# launched the agent CLI from is the "dashboard" session — we capture it once
# here and persist it in meta.json.
#
# We also capture the window's stable tmux ID (`#{window_id}`, e.g. `@7`) and
# persist it. This is the ONLY identifier Root targets for subsequent renames.
# Window IDs never collide and never shift, unlike window names (which Root
# rewrites on every status change) or window indexes (which `renumber-windows`
# can shift). Targeting by name is a footgun because tmux's resolution order
# tries window-index BEFORE name (man tmux: target-window), so a numeric
# default name like "3" silently becomes "the window currently at index 3".
#
# Anchor `display-message` to the calling pane via `-t "${TMUX_PANE}"`. Without
# `-t`, tmux resolves format strings against the *active pane of the attached
# client* (i.e. whichever window the human currently has focused) — not the
# pane the script is running in. If the human's focus drifted between launching
# the agent CLI and Root invoking init-root, we'd silently capture the wrong
# window's #{window_id} and every subsequent rename would target a neighbor.
# $TMUX_PANE is set by tmux for every process inside a pane (e.g. %98), is
# stable for the pane's lifetime, and is unaffected by client focus.
[[ -n "${TMUX:-}" ]] || die "init-root.sh must be run from inside tmux (TMUX env var is unset)"
[[ -n "${TMUX_PANE:-}" ]] || die "init-root.sh must be run from inside a tmux pane (TMUX_PANE env var is unset)"
ROOT_TMUX_SESSION="$(tmux display-message -p -t "${TMUX_PANE}" '#S' 2>/dev/null || true)"
ROOT_TMUX_WINDOW_ID="$(tmux display-message -p -t "${TMUX_PANE}" '#{window_id}' 2>/dev/null || true)"
[[ -n "${ROOT_TMUX_SESSION}" ]] || die "could not capture tmux session (#S) for pane ${TMUX_PANE}"
[[ -n "${ROOT_TMUX_WINDOW_ID}" ]] || die "could not capture tmux window id (#{window_id}) for pane ${TMUX_PANE}"
log "captured tmux session: ${ROOT_TMUX_SESSION}, window id: ${ROOT_TMUX_WINDOW_ID}"

# --- repo sanity ---
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repo"

# Resolve the main repo's working tree, regardless of the caller's cwd. We use
# --git-common-dir (always points at <main-repo>/.git, even from a worktree)
# so this script can be re-run after the Root worktree exists.
REPO_ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"

# Cleanliness check applies to the main worktree only — Root worktrees may
# have in-progress edits without blocking a new Root init.
git -C "$REPO_ROOT" diff --quiet \
  || die "main worktree has unstaged changes; clean up first"
git -C "$REPO_ROOT" diff --cached --quiet \
  || die "main worktree has staged changes; clean up first"

# --- atomic root-id claim ---
mkdir -p "${REPO_ROOT}/.agent-tdd"
ROOT_ID=""
STATE_DIR=""
for n in $(seq 1 32); do
  candidate="${REPO_ROOT}/.agent-tdd/root-${n}"
  # `mkdir` without -p is atomic on POSIX: succeeds iff the dir didn't exist.
  if mkdir "${candidate}" 2>/dev/null; then
    ROOT_ID="root-${n}"
    STATE_DIR="${candidate}"
    break
  fi
done
[[ -n "${ROOT_ID}" ]] || die "could not claim a root-id within 32 attempts; clean up stale .agent-tdd/root-* dirs"
log "claimed root-id: ${ROOT_ID}"

# --- ensure .agent-tdd/.gitignore ---
# Self-contained: a `.gitignore` file with `*` inside .agent-tdd/ ignores
# everything beneath it from any worktree. Avoids editing the repo's root
# .gitignore (which would dirty the main worktree or pollute <base>'s history).
GITIGNORE="${REPO_ROOT}/.agent-tdd/.gitignore"
if [[ ! -f "${GITIGNORE}" ]] || [[ "$(cat "${GITIGNORE}")" != "*" ]]; then
  log "writing ${GITIGNORE}"
  printf '*\n' > "${GITIGNORE}"
fi

# --- verify base branch exists ---
git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/${BASE_BRANCH}" \
  || git -C "$REPO_ROOT" show-ref --verify --quiet "refs/remotes/origin/${BASE_BRANCH}" \
  || die "base branch '$BASE_BRANCH' not found locally or on origin"

# --- create integration branch (no main-worktree HEAD mutation) ---
INTEGRATION_BRANCH="agent-tdd/${ROOT_TASK}"
if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/${INTEGRATION_BRANCH}"; then
  die "branch '${INTEGRATION_BRANCH}' already exists locally; pick a different task slug"
fi
if git -C "$REPO_ROOT" ls-remote --exit-code --heads origin "${INTEGRATION_BRANCH}" >/dev/null 2>&1; then
  die "branch '${INTEGRATION_BRANCH}' already exists on origin; pick a different task slug"
fi

log "creating ${INTEGRATION_BRANCH} from ${BASE_BRANCH}"
git -C "$REPO_ROOT" fetch origin "${BASE_BRANCH}" --quiet
git -C "$REPO_ROOT" branch "${INTEGRATION_BRANCH}" "origin/${BASE_BRANCH}"
git -C "$REPO_ROOT" push -u origin "${INTEGRATION_BRANCH}"

# --- add Root worktree on the integration branch ---
ROOT_WORKTREE="${STATE_DIR}/root"
log "adding Root worktree at ${ROOT_WORKTREE}"
git -C "$REPO_ROOT" worktree add "${ROOT_WORKTREE}" "${INTEGRATION_BRANCH}"

# --- workspace session name ---
# Orchestrated Roots receive a globally-unique workspace session name from the
# Notes-Agent orchestrator (so two Roots in different repos, both claiming
# root-1, don't collide on a single `ws-root-1` on the shared tmux server).
# Human/manual Roots default to `ws-<root-id>` — unchanged behavior.
WORKSPACE_SESSION="${AGENT_TDD_WS_SESSION:-ws-${ROOT_ID}}"

# --- orchestration markers (additive; null for human-driven Roots) ---
# Persisting these lets a compacted orchestrated Root re-derive from disk that it
# is orchestrated, who its proxy is, and where its signal goes — and lets the
# orchestrator rediscover a lost Root by globbing meta.json across member repos.
if [[ "${AGENT_TDD_ORCHESTRATED:-}" == "1" ]]; then
  ORCHESTRATED_JSON=true
  NOTES_ID_JSON="\"${AGENT_TDD_NOTES_ID:-}\""
  SIGNAL_PATH_JSON="\"${AGENT_TDD_SIGNAL_PATH:-}\""
  SUB_REF_JSON="\"${AGENT_TDD_SUB_REF:-}\""
else
  ORCHESTRATED_JSON=false
  NOTES_ID_JSON=null
  SIGNAL_PATH_JSON=null
  SUB_REF_JSON=null
fi

# --- meta.json ---
META="${STATE_DIR}/meta.json"
cat > "${META}" <<EOF
{
  "root_id": "${ROOT_ID}",
  "task": "${ROOT_TASK}",
  "base": "${BASE_BRANCH}",
  "gh_account": "${GH_ACCOUNT}",
  "max_waves": ${MAX_WAVES},
  "wave_size_cap": 5,
  "current_wave": 0,
  "root_worktree": "${ROOT_WORKTREE}",
  "repo_root": "${REPO_ROOT}",
  "root_tmux_session": "${ROOT_TMUX_SESSION}",
  "root_tmux_window_id": "${ROOT_TMUX_WINDOW_ID}",
  "workspace_session": "${WORKSPACE_SESSION}",
  "orchestrated": ${ORCHESTRATED_JSON},
  "notes_id": ${NOTES_ID_JSON},
  "sub_ref": ${SUB_REF_JSON},
  "signal_path": ${SIGNAL_PATH_JSON}
}
EOF
log "wrote ${META}"

# --- rename Root's tmux window via stable window ID ---
# Done here (rather than left to Root in SKILL.md) so we use the just-captured
# #{window_id} directly, never #W (which can be a numeric default name and
# would resolve as window-INDEX per tmux's resolution order).
log "renaming tmux window ${ROOT_TMUX_WINDOW_ID} to ${ROOT_ID}"
tmux rename-window -t "${ROOT_TMUX_WINDOW_ID}" "${ROOT_ID}" 2>/dev/null \
  || log "warning: failed to rename tmux window (continuing)"

# --- output the root-id (stdout) ---
echo "${ROOT_ID}"
