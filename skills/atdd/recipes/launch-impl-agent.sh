#!/usr/bin/env bash
# launch-impl-agent.sh — wrapper that runs `claude -p` for an impl agent with
# full output capture, exit-code recording, a `.crashed` status marker on
# silent death, and hardened tmux window cleanup.
#
# Runs inside the impl agent's tmux pane (spawn-impl-agent.sh sends the call
# via tmux send-keys), so $TMUX_PANE is set by tmux automatically.
#
# Usage:  launch-impl-agent.sh <issue-num> <prompt-file> <log-dir> <status-dir>
#
# Side effects under <log-dir>/:
#   claude.stdout         full stdout from `claude -p`
#   claude.stderr         full stderr from `claude -p`
#   claude.exitcode       integer exit code
#   claude.timing.start   ISO-8601 timestamp before launch
#   claude.timing.end     ISO-8601 timestamp after exit
#
# Side effect under <status-dir>/ (only when claude exits non-zero AND the
# agent didn't write its own terminal status):
#   issue-<N>.crashed     JSON: {issue, outcome:"crashed", exit_code, log_dir, exit_reason}

set -uo pipefail   # intentionally NOT -e: we need to read claude's exit code

[[ $# -eq 4 ]] || { echo "usage: $0 <issue-num> <prompt-file> <log-dir> <status-dir>" >&2; exit 1; }
ISSUE_NUM="$1"
PROMPT_FILE="$2"
LOG_DIR="$3"
STATUS_DIR="$4"

mkdir -p "${LOG_DIR}" "${STATUS_DIR}"

date -Ins > "${LOG_DIR}/claude.timing.start"

# Capture stdout and stderr to disk while keeping them visible in the pane.
# Process substitution + tee preserves real-time visibility AND on-disk logs.
claude -p "$(cat "${PROMPT_FILE}")" --dangerously-skip-permissions \
  > >(tee "${LOG_DIR}/claude.stdout") \
  2> >(tee "${LOG_DIR}/claude.stderr" >&2)
rc=$?

date -Ins > "${LOG_DIR}/claude.timing.end"
echo "${rc}" > "${LOG_DIR}/claude.exitcode"

# Give the tee subshells a moment to finish writing, and let the agent's own
# atomic-status `mv` settle, before deciding whether to write `.crashed`.
sleep 1

# Write `.crashed` ONLY when claude exited non-zero AND the agent didn't write
# a terminal status itself. This avoids racing the agent's own `.done` etc.
if [[ "${rc}" -ne 0 ]] \
   && [[ ! -f "${STATUS_DIR}/issue-${ISSUE_NUM}.done" ]] \
   && [[ ! -f "${STATUS_DIR}/issue-${ISSUE_NUM}.failed" ]] \
   && [[ ! -f "${STATUS_DIR}/issue-${ISSUE_NUM}.aborted" ]]; then
  TMP="${STATUS_DIR}/issue-${ISSUE_NUM}.crashed.tmp"
  cat > "${TMP}" <<EOF
{
  "issue": ${ISSUE_NUM},
  "outcome": "crashed",
  "exit_code": ${rc},
  "log_dir": "${LOG_DIR}",
  "exit_reason": "claude -p exited ${rc} before writing terminal status; see claude.stderr"
}
EOF
  mv "${TMP}" "${STATUS_DIR}/issue-${ISSUE_NUM}.crashed"
fi

# Hardened tmux window cleanup. The previously-used bare `; tmux kill-window`
# was observed to return 0 yet leave the window alive (race with SessionEnd
# hook subprocess teardown). Explicit pane-target + retry handles both:
#   - kill returned non-zero → next attempt may succeed
#   - kill returned 0 but window persisted → next attempt re-issues
# A successful kill terminates this script when the pane dies, so a working
# kill exits the loop implicitly.
for _ in 1 2 3; do
  if [[ -n "${TMUX_PANE:-}" ]]; then
    tmux kill-window -t "${TMUX_PANE}" 2>/dev/null
  else
    tmux kill-window 2>/dev/null
  fi
  sleep 1
done
