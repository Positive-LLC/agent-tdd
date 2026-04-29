#!/usr/bin/env bash
# spawn-impl-agent.sh — spawn the Implementation Agent for one issue (called by the test agent).
#
# Usage:  spawn-impl-agent.sh <root-id> <wave> <issue-num> <plugin-dir> <workspace-session> <root-task>
#
# Effects:
#   - Creates the impl worktree at .agent-tdd/<root-id>/worktrees/issue-<N>-impl
#     on a new branch issue-<N>-impl stacked off issue-<N>-tests.
#   - Opens a new tmux window <workspace-session>:issue-<N>-PR.
#   - Launches the impl agent via `launch-impl-agent.sh`, which wraps `claude -p`
#     with stdout/stderr capture, exit-code recording, a `.crashed` status marker
#     on silent death, and hardened `tmux kill-window` cleanup.
#
# Fire-and-forget. The test agent self-closes after this returns.

set -euo pipefail

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

# --- launch via wrapper that captures logs + writes .crashed on silent death ---
LOG_DIR="${STATE_DIR}/wave-${WAVE}/logs/issue-${ISSUE_NUM}"
mkdir -p "${LOG_DIR}"
LAUNCHER="${PLUGIN_DIR}/recipes/launch-impl-agent.sh"
[[ -x "${LAUNCHER}" ]] || die "launcher not executable: ${LAUNCHER}"

# tmux send-keys with -l sends the line literally; the receiving bash parses
# and runs it. The wrapper reads $TMUX_PANE from its env (set by tmux).
LAUNCH_CMD="bash '${LAUNCHER}' '${ISSUE_NUM}' '${PROMPT_FILE}' '${LOG_DIR}' '${STATUS_DIR}'"
tmux send-keys -t "${TARGET}" -l "${LAUNCH_CMD}"
tmux send-keys -t "${TARGET}" Enter
log "impl agent for issue #${ISSUE_NUM} dispatched (fire-and-forget); logs at ${LOG_DIR}"
