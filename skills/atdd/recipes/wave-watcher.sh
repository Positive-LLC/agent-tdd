#!/usr/bin/env bash
# wave-watcher.sh — single-shot background event watcher for a wave.
#
# Usage:  wave-watcher.sh <root-id> <wave> <expected-terminal-count>
#
# Behavior:
#   - Polls .agent-tdd/<root-id>/wave-<N>/status/ every 10 seconds.
#   - Exits 0 with `EVENT=terminal` to stdout when terminal count >= expected.
#   - Exits 0 with `EVENT=paused FILE=<path>` to stdout if any .paused appears.
#   - No timeout. Designed to be invoked once per wave with run_in_background=true.
#
# Root issues this exactly once per wave. When it exits, Root resumes and decides
# what to do based on the EVENT line.

set -uo pipefail

[[ $# -eq 3 ]] || { echo "usage: $0 <root-id> <wave> <expected-terminal-count>" >&2; exit 1; }
ROOT_ID="$1"
WAVE="$2"
EXPECTED="$3"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
STATUS_DIR="${REPO_ROOT}/.agent-tdd/${ROOT_ID}/wave-${WAVE}/status"
mkdir -p "${STATUS_DIR}"

while true; do
  # Count terminal files
  terminal_count=$(find "${STATUS_DIR}" -maxdepth 1 -type f \
    \( -name '*.done' -o -name '*.failed' -o -name '*.aborted' \) 2>/dev/null | wc -l)
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
  sleep 10
done
