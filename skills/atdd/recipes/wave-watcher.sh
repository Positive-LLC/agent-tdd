#!/usr/bin/env bash
# wave-watcher.sh — single-shot background event watcher for a wave.
#
# Usage:  wave-watcher.sh <root-id> <wave> <expected-terminal-count> [<result-file>]
#
# Behavior:
#   - Polls .atdd/<root-id>/wave-<N>/status/ every 10 seconds.
#   - Exits 0 with `EVENT=terminal` when terminal count >= expected.
#   - Exits 0 with `EVENT=paused FILE=<path>` if any .paused appears.
#   - Exits 0 with `EVENT=timeout` when WAVE_WATCHER_TIMEOUT_SEC
#     (default 1800 = 30 min) of wall-clock elapses from this invocation's
#     start without a terminal/paused event. The deadline is set once at
#     start and is NOT reset by activity in the worktree or pane — so the
#     semantics are "max wall-clock per invocation," not "max time between
#     events." Across re-issues each new invocation gets a fresh budget.
#   - With 3 args: writes event lines to stdout (legacy; for Claude Code
#     run_in_background / OpenCode bash_bg).
#   - With 4 args: writes event lines ATOMICALLY to <result-file> (writes to
#     a .tmp sibling then mv's on exit — no partial reads). This is the
#     cross-platform daemon form: launched via nohup, with the agent polling
#     the result file from a foreground Bash loop (see PROTOCOL.md §6.1).
#
# Root issues this exactly once per wait. When it exits, Root resumes and
# decides based on the EVENT line. On EVENT=timeout the wave has not reached
# Gate 1 within this invocation's budget; Root inspects each non-terminal
# issue per PROTOCOL §6.1's health checklist and either re-issues once (if
# all signals green and this issue has not been self-extended this wave) or
# escalates to the human (PROTOCOL §1.5 P6).

set -uo pipefail

[[ $# -eq 3 || $# -eq 4 ]] || { echo "usage: $0 <root-id> <wave> <expected-terminal-count> [<result-file>]" >&2; exit 1; }
ROOT_ID="$1"
WAVE="$2"
EXPECTED="$3"

# --- atomic result-file mode (4-arg form; cross-platform daemon) ---
if [[ $# -eq 4 ]]; then
  RESULT_FILE="$4"
  TMP_OUT="${RESULT_FILE}.tmp"
  # Redirect stdout to the temp file; stderr stays on real stderr.
  exec > "${TMP_OUT}"
  # On any exit, atomically mv the completed temp file to the result file.
  # The agent's polling loop checks for existence of RESULT_FILE (not the
  # .tmp), so partial output is never observed.
  trap '[[ -f "${TMP_OUT}" ]] && mv "${TMP_OUT}" "${RESULT_FILE}"' EXIT
fi

# Hard ceiling per watcher invocation. Override via env var only for testing.
TIMEOUT_SEC="${WAVE_WATCHER_TIMEOUT_SEC:-1800}"
DEADLINE=$(( $(date +%s) + TIMEOUT_SEC ))

# Recover the main repo's working tree regardless of caller's cwd. Root runs
# in its own worktree (.atdd/<root-id>/root/); --show-toplevel would
# return that path. --git-common-dir always points at <main-repo>/.git.
REPO_ROOT="$(cd "$(git rev-parse --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd)"
[[ -n "${REPO_ROOT}" ]] || REPO_ROOT="$(pwd)"
STATUS_DIR="${REPO_ROOT}/.atdd/${ROOT_ID}/wave-${WAVE}/status"
mkdir -p "${STATUS_DIR}"

while true; do
  # Count terminal files
  terminal_count=$(find "${STATUS_DIR}" -maxdepth 1 -type f \
    \( -name '*.done' -o -name '*.failed' -o -name '*.aborted' -o -name '*.crashed' \) 2>/dev/null | wc -l)
  paused_file=$(find "${STATUS_DIR}" -maxdepth 1 -type f -name '*.paused' 2>/dev/null | head -1)

  if [[ "${terminal_count}" -ge "${EXPECTED}" ]]; then
    echo "EVENT=terminal"
    echo "TERMINAL_COUNT=${terminal_count}"
    exit 0
  fi
  if [[ -n "${paused_file}" ]]; then
    echo "EVENT=paused"
    echo "FILE=${paused_file}"
    exit 0
  fi
  if [[ "$(date +%s)" -ge "${DEADLINE}" ]]; then
    echo "EVENT=timeout"
    echo "TERMINAL_COUNT=${terminal_count}"
    echo "EXPECTED=${EXPECTED}"
    echo "TIMEOUT_SEC=${TIMEOUT_SEC}"
    exit 0
  fi
  sleep 10
done
