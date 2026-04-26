#!/usr/bin/env bash
# prune-worktrees.sh — remove worktrees of completed issues at wave end.
#
# Usage:  prune-worktrees.sh <root-id> <wave>
#
# Behavior:
#   - For each terminal status file (issue-<N>.{done,failed,aborted}) in this wave,
#     removes both the test and impl worktrees for that issue (if they exist).
#   - Also runs `git worktree prune` to clean up dangling references.
#   - Does NOT delete the status files themselves (they're the audit trail).

set -euo pipefail

log() { printf '[prune] %s\n' "$*" >&2; }
die() { printf '[prune] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: $0 <root-id> <wave>"
ROOT_ID="$1"
WAVE="$2"

REPO_ROOT="$(git rev-parse --show-toplevel)"
STATE_DIR="${REPO_ROOT}/.agent-tdd/${ROOT_ID}"
STATUS_DIR="${STATE_DIR}/wave-${WAVE}/status"
WORKTREES_DIR="${STATE_DIR}/worktrees"

[[ -d "${STATUS_DIR}" ]] || die "status dir ${STATUS_DIR} does not exist"

shopt -s nullglob
for f in "${STATUS_DIR}"/issue-*.done "${STATUS_DIR}"/issue-*.failed "${STATUS_DIR}"/issue-*.aborted; do
  base="$(basename "$f")"
  # extract issue number: issue-3.done -> 3
  issue_num="${base#issue-}"
  issue_num="${issue_num%.*}"
  for kind in tests impl; do
    wt="${WORKTREES_DIR}/issue-${issue_num}-${kind}"
    if [[ -d "$wt" ]]; then
      log "removing worktree ${wt}"
      git -C "${REPO_ROOT}" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
    fi
  done
done

git -C "${REPO_ROOT}" worktree prune
log "done"
