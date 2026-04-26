#!/usr/bin/env bash
# spawn-test-agent.sh — spawn a Test Agent for one issue.
#
# Usage:  spawn-test-agent.sh <root-id> <wave> <issue-num> <plugin-dir> <workspace-session> <root-task>
#
# Effects:
#   - Creates the test worktree at .agent-tdd/<root-id>/worktrees/issue-<N>-tests
#     on a new branch issue-<N>-tests off agent-tdd/<root-task>.
#   - Creates the workspace tmux session if missing.
#   - Opens a new tmux window <workspace-session>:issue-<N> anchored at the worktree.
#   - Launches `claude` in that window.
#   - Pastes the constructed initial prompt (TEST_AGENT_ROLE.md + per-issue task block).
#   - Submits the prompt with Enter.
#
# All progress messages go to stderr. Nothing on stdout (the recipe is fire-and-forget).

set -euo pipefail

log() { printf '[spawn-test] %s\n' "$*" >&2; }
die() { printf '[spawn-test] ERROR: %s\n' "$*" >&2; exit 1; }

# --- args ---
[[ $# -eq 6 ]] || die "usage: $0 <root-id> <wave> <issue-num> <plugin-dir> <workspace-session> <root-task>"
ROOT_ID="$1"
WAVE="$2"
ISSUE_NUM="$3"
PLUGIN_DIR="$4"
WORKSPACE_SESSION="$5"
ROOT_TASK="$6"

REPO_ROOT="$(git rev-parse --show-toplevel)"
STATE_DIR="${REPO_ROOT}/.agent-tdd/${ROOT_ID}"
STATUS_DIR="${STATE_DIR}/wave-${WAVE}/status"
WORKTREE_DIR="${STATE_DIR}/worktrees/issue-${ISSUE_NUM}-tests"
TEST_BRANCH="issue-${ISSUE_NUM}-tests"
ROOT_BRANCH="agent-tdd/${ROOT_TASK}"
WINDOW="issue-${ISSUE_NUM}"
TARGET="${WORKSPACE_SESSION}:${WINDOW}"

mkdir -p "${STATUS_DIR}"

# --- create worktree ---
if [[ -d "${WORKTREE_DIR}" ]]; then
  die "worktree ${WORKTREE_DIR} already exists; clean up first"
fi
log "creating worktree ${WORKTREE_DIR} on branch ${TEST_BRANCH}"
git worktree add "${WORKTREE_DIR}" -b "${TEST_BRANCH}" "${ROOT_BRANCH}"

# --- ensure workspace session ---
if ! tmux has-session -t "${WORKSPACE_SESSION}" 2>/dev/null; then
  log "creating workspace session ${WORKSPACE_SESSION}"
  tmux new-session -d -s "${WORKSPACE_SESSION}"
fi

# --- open the agent window ---
if tmux list-windows -t "${WORKSPACE_SESSION}" -F '#W' 2>/dev/null | grep -qx "${WINDOW}"; then
  die "window ${TARGET} already exists; aborting"
fi
log "opening tmux window ${TARGET} at ${WORKTREE_DIR}"
tmux new-window -t "${WORKSPACE_SESSION}:" -n "${WINDOW}" -c "${WORKTREE_DIR}"

# --- launch claude ---
tmux send-keys -t "${TARGET}" 'claude' Enter

# Wait for the claude prompt (matched by '> ' or similar).
log "waiting for claude prompt in ${TARGET}"
for _ in $(seq 1 60); do
  if tmux capture-pane -p -t "${TARGET}" 2>/dev/null | tail -5 | grep -qE '^[> ]'; then
    break
  fi
  sleep 1
done

# --- build the initial prompt ---
PROMPT_FILE="${STATE_DIR}/wave-${WAVE}/spawn-test-${ISSUE_NUM}.txt"
mkdir -p "$(dirname "${PROMPT_FILE}")"
{
  cat "${PLUGIN_DIR}/roles/TEST_AGENT_ROLE.md"
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
  echo "PLUGIN_DIR=${PLUGIN_DIR}"
  echo "WORKSPACE_SESSION=${WORKSPACE_SESSION}"
  echo "ROOT_TASK=${ROOT_TASK}"
  echo
  echo "Begin now."
} > "${PROMPT_FILE}"
log "wrote prompt to ${PROMPT_FILE}"

# --- paste it via tmux buffer ---
BUF="atdd-spawn-test-${ISSUE_NUM}"
tmux load-buffer -b "${BUF}" "${PROMPT_FILE}"
# bracketed paste keeps Claude Code from treating each newline as a submit.
tmux paste-buffer -p -t "${TARGET}" -b "${BUF}"
tmux delete-buffer -b "${BUF}" 2>/dev/null || true

# Submit
sleep 0.3
tmux send-keys -t "${TARGET}" Enter
log "test agent for issue #${ISSUE_NUM} dispatched"
