#!/usr/bin/env bash
# launch-impl-agent.sh — session supervisor for an INTERACTIVE impl agent.
#
# Runs inside the impl agent's tmux pane (spawn-impl-agent.sh sends the call
# via tmux send-keys), so $TMUX_PANE is set by tmux automatically. Starts the
# agent CLI as an interactive foreground child — the prompt is NOT passed as
# an argument; spawn-impl-agent.sh pastes it into the pane afterwards via
# tmux load-buffer/paste-buffer (same delivery as test agents).
#
# Cleanup runs whenever the session ends, however it ends:
#   - A trap on EXIT/HUP/TERM runs the cleanup block even when the window is
#     killed out from under the session (tmux kill-window SIGHUPs the pane's
#     process group; the CLI child dies, bash's wait returns, the trap fires).
#   - The CLI is run as a foreground child, never `exec`'d — an exec would
#     replace this process and destroy the trap (and all crash detection).
#   - Pane output is captured by `tmux pipe-pane` (started by
#     spawn-impl-agent.sh) to <log-dir>/tmux.pane; this wrapper does no
#     stdout/stderr capture of its own.
#
# `.crashed` trigger is STATUS ABSENCE, not exit code. An interactive session
# exit returns 0 regardless of outcome, so the exit code means nothing. If
# the session ends and no terminal status (.done/.failed/.aborted) exists
# after orphan promotion, the agent died silently. In that case any stale
# `.paused` is removed FIRST — a dead session must not look paused: the
# wave-watcher short-circuits on `.paused` before its timeout, so a stale
# pause file would make Root answer a dead window in a livelock — then
# `.crashed` is written atomically. Crash wins over pause.
#
# Usage:  launch-impl-agent.sh <issue-num> <log-dir> <status-dir>
#
# Environment:
#   AGENT_TDD_CLI           CLI binary (default: claude; alt: opencode, codex)
#
# Side effects under <log-dir>/:
#   agent.exitcode       CLI exit code (informational only — NOT the
#                        .crashed trigger; interactive /exit returns 0)
#   agent.timing.start   ISO-8601 timestamp before launch
#   agent.timing.end     ISO-8601 timestamp after session end
#
# Side effect under <status-dir>/ (only when the session ends with no
# terminal status written by the agent):
#   issue-<N>.crashed     JSON: {issue, outcome:"crashed", exit_code, log_dir, cli, exit_reason}

set -uo pipefail   # intentionally NOT -e: cleanup must run regardless

AGENT_TDD_CLI="${AGENT_TDD_CLI:-claude}"

[[ $# -eq 3 ]] || { echo "usage: $0 <issue-num> <log-dir> <status-dir>" >&2; exit 1; }
ISSUE_NUM="$1"
LOG_DIR="$2"
STATUS_DIR="$3"

mkdir -p "${LOG_DIR}" "${STATUS_DIR}"

rc=""             # CLI exit code; stays empty if the CLI never returned
CLEANUP_DONE=0

# Defined before the trap line so the trap can never fire on an undefined
# function. Guarded against re-entry: the kill-window at the end SIGHUPs
# this very process.
cleanup() {
  [[ "${CLEANUP_DONE}" -eq 1 ]] && return
  CLEANUP_DONE=1

  date -Ins > "${LOG_DIR}/agent.timing.end"
  echo "${rc:-unknown}" > "${LOG_DIR}/agent.exitcode"

  # Let the agent's own atomic-status `mv` settle.
  sleep 1

  # Auto-promote orphan atomic-write `.tmp` files. The protocol requires the
  # agent to do `cat > .tmp ; mv .tmp final`, but if the agent skipped the `mv`
  # (observed: agent intentionally left a `.tmp` thinking it would signal a
  # non-terminal "stuck" state — see ROADMAP "Bug B"), the watcher won't count
  # it as terminal and the wave hangs forever. Auto-promote here only if the
  # `.tmp` is well-formed JSON; otherwise treat as crash and preserve the
  # corrupt tmp in the log dir for forensics.
  local status TMP FINAL
  for status in done failed aborted; do
    TMP="${STATUS_DIR}/issue-${ISSUE_NUM}.${status}.tmp"
    FINAL="${STATUS_DIR}/issue-${ISSUE_NUM}.${status}"
    [[ -f "${TMP}" && ! -f "${FINAL}" ]] || continue
    if jq -e . "${TMP}" >/dev/null 2>&1; then
      mv "${TMP}" "${FINAL}"
      echo "[launch-impl] auto-promoted orphan ${TMP##*/} -> ${FINAL##*/}" >&2
    else
      cp "${TMP}" "${LOG_DIR}/orphan-${status}.tmp"
      rm -f "${TMP}"
      echo "[launch-impl] discarded malformed orphan ${TMP##*/} (preserved at logs/orphan-${status}.tmp)" >&2
    fi
  done

  # Write `.crashed` iff the session ended with NO terminal status (the
  # orphan-promote pass above ran first, so any valid `.tmp` already counts).
  # The exit code is recorded but deliberately NOT consulted: an interactive
  # /exit returns 0 whether or not the agent did its job.
  if [[ ! -f "${STATUS_DIR}/issue-${ISSUE_NUM}.done" ]] \
     && [[ ! -f "${STATUS_DIR}/issue-${ISSUE_NUM}.failed" ]] \
     && [[ ! -f "${STATUS_DIR}/issue-${ISSUE_NUM}.aborted" ]]; then
    # Remove any stale `.paused` BEFORE writing `.crashed`: the session is
    # dead, so the pause can never be answered; leaving it would loop the
    # wave-watcher on EVENT=paused forever. Crash wins over pause.
    rm -f "${STATUS_DIR}/issue-${ISSUE_NUM}.paused"
    TMP="${STATUS_DIR}/issue-${ISSUE_NUM}.crashed.tmp"
    cat > "${TMP}" <<EOF
{
  "issue": ${ISSUE_NUM},
  "outcome": "crashed",
  "exit_code": ${rc:-null},
  "log_dir": "${LOG_DIR}",
  "cli": "${AGENT_TDD_CLI}",
  "exit_reason": "${AGENT_TDD_CLI} session ended before a terminal status was written; see tmux.pane"
}
EOF
    mv "${TMP}" "${STATUS_DIR}/issue-${ISSUE_NUM}.crashed"
  fi

  # Hardened tmux window cleanup. The previously-used bare `; tmux kill-window`
  # was observed to return 0 yet leave the window alive (race with SessionEnd
  # hook subprocess teardown). Explicit pane-target + retry handles both:
  #   - kill returned non-zero → next attempt may succeed
  #   - kill returned 0 but window persisted → next attempt re-issues
  # A successful kill terminates this script when the pane dies (re-entry is
  # blocked by CLEANUP_DONE), so a working kill exits the loop implicitly.
  # On the SIGHUP path the window is already gone and every kill is a no-op.
  for _ in 1 2 3; do
    if [[ -n "${TMUX_PANE:-}" ]]; then
      tmux kill-window -t "${TMUX_PANE}" 2>/dev/null
    else
      tmux kill-window 2>/dev/null
    fi
    sleep 1
  done
}
trap cleanup EXIT HUP TERM

date -Ins > "${LOG_DIR}/agent.timing.start"

# Launch the agent CLI interactively in the foreground (never `exec` — see
# header). The per-CLI branch now selects launch FLAGS only; the prompt
# arrives via tmux paste from spawn-impl-agent.sh after the TUI is ready.
#   - claude:   `--permission-mode bypassPermissions` is valid for interactive
#               sessions too — same no-prompt posture the headless form used
#               (trusted local repos only).
#   - opencode: bare TUI. Interactive permission flags are unverified —
#               see ROADMAP Smoke-Test Risk #7.
#   - codex:    bare TUI. Interactive driving is entirely unverified —
#               see ROADMAP Smoke-Test Risk #7.
if [[ "${AGENT_TDD_CLI}" == "opencode" ]]; then
  opencode
elif [[ "${AGENT_TDD_CLI}" == "codex" ]]; then
  codex
else
  claude --permission-mode bypassPermissions
fi
rc=$?

# Cleanup (timing, exit code, orphan promotion, .crashed decision,
# kill-window) runs via the EXIT trap.
