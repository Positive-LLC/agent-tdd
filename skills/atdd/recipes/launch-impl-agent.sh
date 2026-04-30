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
# `--permission-mode bypassPermissions` is the canonical mode for impl agents:
# non-interactive autonomy in a trusted local repo. The deprecated
# `--dangerously-skip-permissions` flag and the intermediate `auto` mode were
# both tried during smoke testing; `bypassPermissions` is the current answer.
claude -p "$(cat "${PROMPT_FILE}")" --permission-mode bypassPermissions \
  > >(tee "${LOG_DIR}/claude.stdout") \
  2> >(tee "${LOG_DIR}/claude.stderr" >&2)
rc=$?

date -Ins > "${LOG_DIR}/claude.timing.end"
echo "${rc}" > "${LOG_DIR}/claude.exitcode"

# Give the tee subshells a moment to finish writing, and let the agent's own
# atomic-status `mv` settle.
sleep 1

# Auto-promote orphan atomic-write `.tmp` files. The protocol requires the
# agent to do `cat > .tmp ; mv .tmp final`, but if the agent skipped the `mv`
# (observed: agent intentionally left a `.tmp` thinking it would signal a
# non-terminal "stuck" state — see ROADMAP "Bug B"), the watcher won't count
# it as terminal and the wave hangs forever. Auto-promote here only if the
# `.tmp` is well-formed JSON; otherwise treat as crash and preserve the
# corrupt tmp in the log dir for forensics.
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

# Write `.crashed` ONLY when claude exited non-zero AND the agent didn't write
# a terminal status itself. The orphan-promote pass above ran first, so any
# valid `.tmp` is already promoted to its final form by this point.
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
