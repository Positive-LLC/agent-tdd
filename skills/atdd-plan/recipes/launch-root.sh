#!/usr/bin/env bash
# launch-root.sh — session supervisor for an orchestrated Root Agent.
#
# The Notes-Agent-orchestration analogue of launch-impl-agent.sh. Runs inside
# the Root's tmux pane (spawn-root.sh sends this call via tmux send-keys), so
# $TMUX_PANE is set automatically. Its tail launches the agent CLI interactively
# in the FOREGROUND (never `exec` — an exec would replace this process and
# destroy the crash trap). spawn-root.sh pastes the Root bootstrap prompt into
# the pane afterwards (same delivery as test/impl agents).
#
# Why this exists: a spawned Root is the longest-lived child in the whole system
# and previously had NO silent-death detection (unlike impl agents). If the
# Root's CLI session ends without reaching a clean terminal signal, this
# supervisor writes a `crashed` signal so the orchestrator's roots-watcher sees
# it (EVENT=root-escalation / root-dead) instead of hanging until a timeout.
#
# Crash trigger is STATUS ABSENCE, not exit code (an interactive /exit returns 0
# regardless of outcome). A Root that reaches a CLEAN terminal signal —
# `awaiting-merge-confirm` (handed the irreversible base merge to the orchestrator
# and exited), `failed`, or `complete` — is NOT a crash. Any other ending state
# (running, paused-needs-proxy, rebase-blocked, stuck, or no signal at all) means
# the Root died mid-flight → write `crashed`.
#
# This supervisor deliberately does NOT kill the tmux window on exit (unlike the
# impl supervisor): the Root's window lives in the orchestrator's own session and
# is left for forensics/inspection. The orchestrator removes it during cleanup.
#
# Usage:  launch-root.sh <log-dir>
#
# Environment (set on the launch line by spawn-root.sh):
#   AGENT_TDD_CLI            CLI binary (default: claude; alt: opencode, codex, deepcode)
#   AGENT_TDD_SIGNAL_PATH    absolute path to this Root's root-signal.json
#   AGENT_TDD_ORCHESTRATED   "1" (write-signal.sh is gated on it)
#   CLAUDE_SKILL_DIR         used to locate write-signal.sh
#
# Side effects under <log-dir>/: agent.exitcode, agent.timing.{start,end}.

set -uo pipefail   # intentionally NOT -e: cleanup must run regardless

AGENT_TDD_CLI="${AGENT_TDD_CLI:-claude}"

[[ $# -eq 1 ]] || { echo "usage: $0 <log-dir>" >&2; exit 1; }
LOG_DIR="$1"
mkdir -p "${LOG_DIR}"

rc=""
CLEANUP_DONE=0

cleanup() {
  [[ "${CLEANUP_DONE}" -eq 1 ]] && return
  CLEANUP_DONE=1

  date -u +%Y-%m-%dT%H:%M:%SZ > "${LOG_DIR}/agent.timing.end" 2>/dev/null || true
  echo "${rc:-unknown}" > "${LOG_DIR}/agent.exitcode"

  # Let the Root's own atomic signal `mv` settle.
  sleep 1

  # Read the current signal state. Clean terminal states need no crash marker.
  local state=""
  if [[ -n "${AGENT_TDD_SIGNAL_PATH:-}" ]] && [[ -f "${AGENT_TDD_SIGNAL_PATH}" ]] \
     && command -v jq >/dev/null 2>&1; then
    state="$(jq -r '.state // empty' "${AGENT_TDD_SIGNAL_PATH}" 2>/dev/null || echo "")"
  fi

  case "${state}" in
    awaiting-merge-confirm|failed|complete)
      printf '[launch-root] clean exit (signal state=%s); no crash marker\n' "${state}" >&2
      ;;
    *)
      # Silent death: session ended without a clean terminal signal. Emit a
      # `crashed` signal so the orchestrator detects it. Reuse write-signal.sh
      # (env-gated; located via CLAUDE_SKILL_DIR) so the seq bump is consistent.
      local ws="${CLAUDE_SKILL_DIR:-}/../atdd/recipes/write-signal.sh"
      if [[ -f "${ws}" ]]; then
        bash "${ws}" crashed \
          --detail "Root CLI session ended with signal state='${state:-none}' (not a clean terminal). exit_code=${rc:-unknown}; see ${LOG_DIR}/tmux.pane" \
          --recommendation "Root died silently; recommend re-spawn from the SubIssue after inspecting the log bundle." \
          >&2 2>&1 || printf '[launch-root] WARNING: write-signal.sh crashed failed\n' >&2
      else
        printf '[launch-root] WARNING: write-signal.sh not found at %s; cannot mark crash\n' "${ws}" >&2
      fi
      ;;
  esac
}
trap cleanup EXIT HUP TERM

date -u +%Y-%m-%dT%H:%M:%SZ > "${LOG_DIR}/agent.timing.start" 2>/dev/null || true

# Launch the agent CLI interactively in the foreground. Per-CLI branch selects
# launch FLAGS only; the bootstrap prompt arrives via tmux paste from
# spawn-root.sh after the TUI is ready.
#   - claude:   --permission-mode bypassPermissions (trusted local repos; same
#               posture as test/impl agents). NOTE: whether this defeats a
#               project's permissions.ask for `git push` is an OPEN smoke risk
#               (ROADMAP) — the orchestrator must watch for a Root wedged on an
#               in-pane permission prompt.
#   - opencode: --auto (auto-approve permissions; --dangerously-skip-permissions is a hidden alias).
#   - codex:    bare TUI, orchestrated launch deferred/untested.
#   - deepcode: bare TUI (permissions handled by Deep Code's own system).
if [[ "${AGENT_TDD_CLI}" == "opencode" ]]; then
  opencode --auto
elif [[ "${AGENT_TDD_CLI}" == "codex" ]]; then
  codex
elif [[ "${AGENT_TDD_CLI}" == "deepcode" ]]; then
  deepcode
else
  claude --permission-mode bypassPermissions
fi
rc=$?

# Cleanup (timing, exit code, crash decision) runs via the EXIT trap.
