#!/usr/bin/env bash
# spawn-test-agent.sh — spawn a Test Agent for one issue.
#
# Usage:  spawn-test-agent.sh <root-id> <wave> <issue-num> <plugin-dir> <workspace-session> <root-task>
#
# Effects:
#   - Creates the test worktree at .atdd/<root-id>/worktrees/issue-<N>-tests
#     on a new branch issue-<N>-tests off agent-tdd/<root-task>.
#   - Creates the workspace tmux session if missing.
#   - Opens a new tmux window <workspace-session>:issue-<N> anchored at the worktree.
#   - Starts `tmux pipe-pane` writing pane output to logs/issue-<N>/tmux.pane
#     so the interactive session is captured to disk for forensics.
#   - Launches the agent CLI in that window.
#   - Pastes the constructed initial prompt (TEST_AGENT_ROLE.md + per-issue task block).
#   - Submits the prompt with Enter.
#
# Environment: AGENT_TDD_CLI (default: claude; alt: opencode, codex). The value
# is the interactive binary launched in the window (`claude` / `opencode` /
# `codex`), so no per-CLI branch is needed here — the prompt is pasted the same
# way for all three.
#
# spawn-impl-agent.sh is the parallel implementation for impl agents (same
# launch + prompt-ready poll + paste flow, but routed through the
# launch-impl-agent.sh session supervisor); keep the two in sync when
# touching the launch flow.
#
# All progress messages go to stderr. Nothing on stdout (the recipe is fire-and-forget).

set -euo pipefail

AGENT_TDD_CLI="${AGENT_TDD_CLI:-claude}"

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

# Recover the main repo's working tree regardless of caller's cwd. Root now
# runs in its own worktree (.atdd/<root-id>/root/), so --show-toplevel
# would return that worktree's path, breaking the ${REPO_ROOT}/.atdd/...
# join. --git-common-dir always points at <main-repo>/.git from any worktree.
REPO_ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
STATE_DIR="${REPO_ROOT}/.atdd/${ROOT_ID}"
STATUS_DIR="${STATE_DIR}/wave-${WAVE}/status"
WORKTREE_DIR="${STATE_DIR}/worktrees/issue-${ISSUE_NUM}-tests"
TEST_BRANCH="issue-${ISSUE_NUM}-tests"
ROOT_BRANCH="agent-tdd/${ROOT_TASK}"
WINDOW="issue-${ISSUE_NUM}"
TARGET="${WORKSPACE_SESSION}:${WINDOW}"

# --- read gh_account from meta.json (required) ---
META="${STATE_DIR}/meta.json"
[[ -f "${META}" ]] || die "meta.json not found at ${META}; was init-root.sh run?"
GH_ACCOUNT="$(grep -E '"gh_account"' "${META}" | sed -E 's/.*"gh_account"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
[[ -n "${GH_ACCOUNT}" ]] || die "meta.json:gh_account is empty or missing; bump the Root with a re-init"

# --- active atdd project to scope the test agent's `atdd` calls (env wins, else
#     the Root's meta.json, else "default") ---
PROJECT_SLUG="${ATDD_PROJECT:-}"
[[ -n "${PROJECT_SLUG}" ]] || PROJECT_SLUG="$(grep -E '"project_slug"' "${META}" | sed -E 's/.*"project_slug"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
[[ -n "${PROJECT_SLUG}" ]] || PROJECT_SLUG="default"

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

# --- start pane capture before launching agent CLI ---
# Test agents are interactive; pane scrollback is volatile and lost on
# `tmux kill-window`. Pipe-pane snapshots everything to disk in real time.
LOG_DIR="${STATE_DIR}/wave-${WAVE}/logs/issue-${ISSUE_NUM}"
mkdir -p "${LOG_DIR}"
tmux pipe-pane -t "${TARGET}" "cat >> '${LOG_DIR}/tmux.pane'"
log "capturing pane to ${LOG_DIR}/tmux.pane"

# --- launch agent CLI ---
# claude: launch with bypassPermissions so the test agent's single push of the
# tests branch does not stall on a project `ask` rule (e.g. `Bash(git push:*)`).
# Mirrors launch-impl-agent.sh, which already uses this posture for impl agents
# (trusted local repos only). opencode/codex: bare TUI, flags unverified.
if [[ "${AGENT_TDD_CLI}" == "claude" ]]; then
	tmux send-keys -t "${TARGET}" "ATDD_PROJECT='${PROJECT_SLUG}' ATDD_ROLE=test ATDD_ISSUE='${ISSUE_NUM}' ATDD_STATUS_DIR='${STATUS_DIR}' claude --permission-mode bypassPermissions" Enter
else
    tmux send-keys -t "${TARGET}" "ATDD_PROJECT='${PROJECT_SLUG}' ${AGENT_TDD_CLI}" Enter
fi

# Wait for the prompt (matched by '> ' or similar).
log "waiting for ${AGENT_TDD_CLI} prompt in ${TARGET}"
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
  echo "GH_ACCOUNT=${GH_ACCOUNT}"
  echo
  echo "Begin now."
} > "${PROMPT_FILE}"
log "wrote prompt to ${PROMPT_FILE}"

# --- paste it via tmux buffer ---
BUF="atdd-spawn-test-${ISSUE_NUM}"
tmux load-buffer -b "${BUF}" "${PROMPT_FILE}"
# bracketed paste keeps the agent CLI from treating each newline as a submit.
tmux paste-buffer -p -t "${TARGET}" -b "${BUF}"
tmux delete-buffer -b "${BUF}" 2>/dev/null || true

# Submit
sleep 0.3
tmux send-keys -t "${TARGET}" Enter
log "test agent for issue #${ISSUE_NUM} dispatched"
