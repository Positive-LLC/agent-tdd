#!/usr/bin/env bash
# spawn-resume-window.sh — create a new tmux window in the dashboard session,
# launch the agent CLI in it, and send the resume slash command.
#
# Usage:  spawn-resume-window.sh <root-id>
#
# Environment: AGENT_TDD_CLI (default: claude; alt: opencode, codex). Selects the
# invocation form (`/agent-tdd:atdd resume <id>` under claude; `/atdd resume <id>`
# under opencode; `$atdd resume <id>` under codex) and the binary launched in the
# new pane.
#
# Prints the new window's stable tmux ID (e.g. @12) on stdout. All progress
# messages go to stderr. Caller (Root running /atdd-compact) captures the
# stdout to use for capture-pane in step 5.
#
# Effects:
#   - tmux new-window in the dashboard session named root-<id>-resume
#     (suffixed -2, -3, ... if collision). cwd = repo_root.
#   - sends the agent CLI + Enter to start the interactive session.
#   - polls capture-pane until the prompt indicator appears (up to 30s).
#   - sends the (CLI-appropriate) resume slash command + Enter.
#
# Failure modes:
#   - tmux session from meta.json no longer exists → die.
#   - agent prompt does not appear within 30s → die (window left alive for
#     debugging; caller decides whether to kill it).

set -euo pipefail

AGENT_TDD_CLI="${AGENT_TDD_CLI:-claude}"

log() { printf '[spawn-resume] %s\n' "$*" >&2; }
die() { printf '[spawn-resume] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 1 ]] || die "usage: $0 <root-id>"
ROOT_ID="$1"
[[ "$ROOT_ID" =~ ^root-[a-z0-9-]+$ ]] || die "bad root-id: ${ROOT_ID}"

command -v tmux >/dev/null 2>&1 || die "tmux not found on PATH"
command -v jq   >/dev/null 2>&1 || die "jq not found on PATH"

REPO_ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)" \
  || die "not inside a git repo"
META="${REPO_ROOT}/.atdd/${ROOT_ID}/meta.json"
[[ -f "$META" ]] || die "meta.json not found at ${META}"

# Active atdd project for the resumed agent (env wins, else the Root's meta.json,
# else "default") — so a resumed window stays in the same project.
PROJECT_SLUG="${ATDD_PROJECT:-}"
[[ -n "${PROJECT_SLUG}" ]] || PROJECT_SLUG="$(grep -E '"project_slug"' "${META}" | sed -E 's/.*"project_slug"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
[[ -n "${PROJECT_SLUG}" ]] || PROJECT_SLUG="default"

SESSION="$(jq -r '.root_tmux_session // empty' "$META")"
[[ -n "$SESSION" ]] || die "root_tmux_session not set in ${META}"

tmux has-session -t "${SESSION}" 2>/dev/null \
  || die "tmux session '${SESSION}' does not exist (was the dashboard session killed?)"

# --- pick a unique window name; resume-N suffix grows on collision ---
BASE_NAME="${ROOT_ID}-resume"
NAME="${BASE_NAME}"
i=2
# tmux list-windows -F '#W' lists all window names in the session.
existing="$(tmux list-windows -t "${SESSION}" -F '#W' 2>/dev/null || true)"
while echo "$existing" | grep -qx "${NAME}"; do
  NAME="${BASE_NAME}-${i}"
  i=$((i + 1))
  [[ $i -gt 32 ]] && die "too many resume windows; clean up old ones first"
done
log "new window name: ${NAME}"

# --- create the new window and capture its stable window ID ---
# -P -F '#{window_id}' prints the new window's @-id on stdout. We avoid -d
# (don't auto-switch focus) so the human's eyes stay on the old (current)
# window during verification; they'll switch manually after archive.
NEW_WIN_ID="$(tmux new-window \
  -t "${SESSION}:" \
  -n "${NAME}" \
  -c "${REPO_ROOT}" \
  -d \
  -P -F '#{window_id}')" \
  || die "tmux new-window failed"
[[ -n "$NEW_WIN_ID" ]] || die "could not capture new window's #{window_id}"
log "new window id: ${NEW_WIN_ID}"

# --- launch agent CLI in the new window ---
# Export AGENT_TDD_CLI in the new pane's env first so the resumed Root's
# subsequent recipe spawns (spawn-test-agent, spawn-impl-agent) see the same
# CLI choice. tmux's server-wide env is unreliable across sessions.
log "launching ${AGENT_TDD_CLI} in ${NEW_WIN_ID}"
tmux send-keys -t "${NEW_WIN_ID}" "export AGENT_TDD_CLI='${AGENT_TDD_CLI}'" Enter
tmux send-keys -t "${NEW_WIN_ID}" "export ATDD_PROJECT='${PROJECT_SLUG}'" Enter
tmux send-keys -t "${NEW_WIN_ID}" "${AGENT_TDD_CLI}" Enter

# --- wait for the prompt indicator to appear ---
log "waiting for ${AGENT_TDD_CLI} prompt (up to 30s)"
PROMPT_OK=0
for _ in $(seq 1 30); do
  if tmux capture-pane -p -t "${NEW_WIN_ID}" 2>/dev/null | grep -q '^>'; then
    PROMPT_OK=1
    break
  fi
  sleep 1
done
[[ $PROMPT_OK -eq 1 ]] || die "${AGENT_TDD_CLI} prompt did not appear within 30s in ${NEW_WIN_ID} — check the pane manually"

# --- send the resume invocation ---
# Each host exposes the skill differently:
#   - Claude Code: plugin commands are namespaced  -> `/agent-tdd:atdd`
#   - OpenCode:    the plugin registers them bare   -> `/atdd`
#   - Codex:       skills are invoked by name with $ -> `$atdd`
# Pick the right form so the resumed Root actually re-enters the workflow.
if [[ "${AGENT_TDD_CLI}" == "opencode" ]]; then
  SLASH="/atdd resume ${ROOT_ID}"
elif [[ "${AGENT_TDD_CLI}" == "codex" ]]; then
  SLASH="\$atdd resume ${ROOT_ID}"
else
  SLASH="/agent-tdd:atdd resume ${ROOT_ID}"
fi
log "sending: ${SLASH}"
# -l makes tmux treat the string as literal (handles the slash and spaces
# without binding to any user-defined key sequence). Then a separate Enter.
tmux send-keys -t "${NEW_WIN_ID}" -l "${SLASH}"
tmux send-keys -t "${NEW_WIN_ID}" Enter

# --- output: the new window id (the only stdout line) ---
echo "${NEW_WIN_ID}"
