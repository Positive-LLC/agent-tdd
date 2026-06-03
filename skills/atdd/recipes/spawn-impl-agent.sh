#!/usr/bin/env bash
# spawn-impl-agent.sh — spawn the Implementation Agent for one issue (called by the test agent).
#
# Usage:  spawn-impl-agent.sh <root-id> <wave> <issue-num> <plugin-dir> <workspace-session> <root-task>
#
# Effects:
#   - Creates the impl worktree at .agent-tdd/<root-id>/worktrees/issue-<N>-impl
#     on a new branch issue-<N>-impl stacked off issue-<N>-tests.
#   - Opens a new tmux window <workspace-session>:issue-<N>-PR.
#   - Starts `tmux pipe-pane` writing pane output to logs/issue-<N>/tmux.pane
#     so the interactive session is captured to disk for forensics.
#   - Launches the agent CLI INTERACTIVELY via `launch-impl-agent.sh` (the
#     session supervisor), which records timing, writes a `.crashed` status
#     marker if the session ends with no terminal status, removes any stale
#     `.paused` in that case, and hardened-kills the window afterwards.
#   - Waits for the CLI prompt, then pastes the constructed initial prompt
#     (IMPL_AGENT_ROLE.md + per-issue task block) and submits it with Enter —
#     the same delivery as spawn-test-agent.sh (the parallel implementation
#     for test agents; keep the two in sync when touching the launch flow).
#
# Environment: AGENT_TDD_CLI (default: claude) — propagated explicitly into the
# tmux send-keys command line so the new pane's shell sees it regardless of
# whether AGENT_TDD_CLI was inherited via tmux server env.
#
# Fire-and-forget from the test agent's perspective: this recipe returns after
# the prompt is pasted; the impl agent runs on in its own window.

set -euo pipefail

AGENT_TDD_CLI="${AGENT_TDD_CLI:-claude}"

log() { printf '[spawn-impl] %s\n' "$*" >&2; }
die() { printf '[spawn-impl] ERROR: %s\n' "$*" >&2; exit 1; }

# --- args ---
[[ $# -eq 6 ]] || die "usage: $0 <root-id> <wave> <issue-num> <plugin-dir> <workspace-session> <root-task>"
ROOT_ID="$1"
WAVE="$2"
ISSUE_NUM="$3"
PLUGIN_DIR="$4"
WORKSPACE_SESSION="$5"
ROOT_TASK="$6"

# NOTE: this recipe is invoked by a test agent whose CWD is its own worktree.
# `--show-toplevel` would return the worktree path, not the main repo. Use
# `--git-common-dir` (which always points at <main-repo>/.git) to recover the
# main worktree regardless of which worktree is calling.
REPO_ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
STATE_DIR="${REPO_ROOT}/.agent-tdd/${ROOT_ID}"
STATUS_DIR="${STATE_DIR}/wave-${WAVE}/status"
WORKTREE_DIR="${STATE_DIR}/worktrees/issue-${ISSUE_NUM}-impl"
TEST_BRANCH="issue-${ISSUE_NUM}-tests"
IMPL_BRANCH="issue-${ISSUE_NUM}-impl"
ROOT_BRANCH="agent-tdd/${ROOT_TASK}"
WINDOW="issue-${ISSUE_NUM}-PR"
TARGET="${WORKSPACE_SESSION}:${WINDOW}"

# --- read gh_account from meta.json (required) ---
META="${STATE_DIR}/meta.json"
[[ -f "${META}" ]] || die "meta.json not found at ${META}; was init-root.sh run?"
GH_ACCOUNT="$(grep -E '"gh_account"' "${META}" | sed -E 's/.*"gh_account"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
[[ -n "${GH_ACCOUNT}" ]] || die "meta.json:gh_account is empty or missing; bump the Root with a re-init"

mkdir -p "${STATUS_DIR}"

# --- create impl worktree (stacked off test branch) ---
if [[ -d "${WORKTREE_DIR}" ]]; then
  die "worktree ${WORKTREE_DIR} already exists; aborting"
fi
log "creating worktree ${WORKTREE_DIR} on branch ${IMPL_BRANCH} (stacked on ${TEST_BRANCH})"

# fetch the test branch from origin (test agent pushed it)
git fetch origin "${TEST_BRANCH}" --quiet
git worktree add "${WORKTREE_DIR}" -b "${IMPL_BRANCH}" "origin/${TEST_BRANCH}"

# --- ensure workspace session ---
if ! tmux has-session -t "${WORKSPACE_SESSION}" 2>/dev/null; then
  die "workspace session ${WORKSPACE_SESSION} missing; should have been created by Root"
fi

# --- open the impl window ---
if tmux list-windows -t "${WORKSPACE_SESSION}" -F '#W' 2>/dev/null | grep -qx "${WINDOW}"; then
  die "window ${TARGET} already exists; aborting"
fi
log "opening tmux window ${TARGET} at ${WORKTREE_DIR}"
tmux new-window -t "${WORKSPACE_SESSION}:" -n "${WINDOW}" -c "${WORKTREE_DIR}"

# --- start pane capture before launching agent CLI ---
# Impl agents are interactive now; pane scrollback is volatile and lost on
# `tmux kill-window`. Pipe-pane snapshots everything to disk in real time —
# this replaces the stdout/stderr capture the old headless wrapper did.
LOG_DIR="${STATE_DIR}/wave-${WAVE}/logs/issue-${ISSUE_NUM}"
mkdir -p "${LOG_DIR}"
tmux pipe-pane -t "${TARGET}" "cat >> '${LOG_DIR}/tmux.pane'"
log "capturing pane to ${LOG_DIR}/tmux.pane"

# --- launch agent CLI via the session supervisor ---
LAUNCHER="${PLUGIN_DIR}/recipes/launch-impl-agent.sh"
[[ -x "${LAUNCHER}" ]] || die "launcher not executable: ${LAUNCHER}"

# tmux send-keys with -l sends the line literally; the receiving bash parses
# and runs it. The wrapper reads $TMUX_PANE from its env (set by tmux). We
# prefix AGENT_TDD_CLI so the launcher uses the correct CLI even if the new
# pane's shell didn't inherit our env (tmux env propagation is unreliable
# across servers and pre-existing sessions). The wrapper starts the CLI
# interactively; the prompt is pasted below, not passed as an argument.
LAUNCH_CMD="AGENT_TDD_CLI='${AGENT_TDD_CLI}' bash '${LAUNCHER}' '${ISSUE_NUM}' '${LOG_DIR}' '${STATUS_DIR}'"
tmux send-keys -t "${TARGET}" -l "${LAUNCH_CMD}"
tmux send-keys -t "${TARGET}" Enter

# Wait for the prompt (matched by '> ' or similar).
log "waiting for ${AGENT_TDD_CLI} prompt in ${TARGET}"
for _ in $(seq 1 60); do
  if tmux capture-pane -p -t "${TARGET}" 2>/dev/null | tail -5 | grep -qE '^[> ]'; then
    break
  fi
  sleep 1
done

# --- build the prompt file ---
PROMPT_FILE="${STATE_DIR}/wave-${WAVE}/spawn-impl-${ISSUE_NUM}.txt"
mkdir -p "$(dirname "${PROMPT_FILE}")"
{
  cat "${PLUGIN_DIR}/roles/IMPL_AGENT_ROLE.md"
  echo
  echo "---"
  echo
  echo "## Per-Issue Task"
  echo
  echo "ISSUE_NUM=${ISSUE_NUM}"
  echo "ROOT_ID=${ROOT_ID}"
  echo "WAVE=${WAVE}"
  echo "STATUS_DIR=${STATUS_DIR}"
  echo "WORKTREE_DIR=${WORKTREE_DIR}"
  echo "TEST_BRANCH=${TEST_BRANCH}"
  echo "IMPL_BRANCH=${IMPL_BRANCH}"
  echo "ROOT_BRANCH=${ROOT_BRANCH}"
  echo "ROOT_TASK=${ROOT_TASK}"
  echo "GH_ACCOUNT=${GH_ACCOUNT}"
  echo
  echo "Begin now."
} > "${PROMPT_FILE}"
log "wrote prompt to ${PROMPT_FILE}"

# --- paste it via tmux buffer ---
BUF="atdd-spawn-impl-${ISSUE_NUM}"
tmux load-buffer -b "${BUF}" "${PROMPT_FILE}"
# bracketed paste keeps the agent CLI from treating each newline as a submit.
tmux paste-buffer -p -t "${TARGET}" -b "${BUF}"
tmux delete-buffer -b "${BUF}" 2>/dev/null || true

# Submit
sleep 0.3
tmux send-keys -t "${TARGET}" Enter
log "impl agent for issue #${ISSUE_NUM} dispatched; logs at ${LOG_DIR}"
