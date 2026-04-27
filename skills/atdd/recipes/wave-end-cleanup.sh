#!/usr/bin/env bash
# wave-end-cleanup.sh — wave-end cleanup of worktrees and merged issue branches.
#
# Usage:  wave-end-cleanup.sh <root-id> <wave>
#
# Behavior:
#   - For each terminal status file (issue-<N>.{done,failed,aborted,crashed})
#     in this wave, removes both the test and impl worktrees for that issue.
#   - For each `.done` issue whose impl PR is in MERGED state, deletes the
#     `issue-<N>-tests` and `issue-<N>-impl` branches (local + remote). The
#     content is captured in `agent-tdd/<task>` after the squash-merge, and
#     GitHub keeps the merged PR viewable even after the branch is deleted.
#   - For non-`.done` terminal states (`.failed`, `.aborted`, `.crashed`) and
#     for `.done` issues whose PR is NOT yet merged, branches are preserved —
#     they may hold the only copy of debugging context or open-PR work.
#   - Runs `git worktree prune` to clean up dangling references.
#   - Does NOT delete the status files themselves (they are the audit trail).

set -euo pipefail

log() { printf '[wave-end-cleanup] %s\n' "$*" >&2; }
die() { printf '[wave-end-cleanup] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: $0 <root-id> <wave>"
ROOT_ID="$1"
WAVE="$2"

REPO_ROOT="$(git rev-parse --show-toplevel)"
STATE_DIR="${REPO_ROOT}/.agent-tdd/${ROOT_ID}"
STATUS_DIR="${STATE_DIR}/wave-${WAVE}/status"
WORKTREES_DIR="${STATE_DIR}/worktrees"

[[ -d "${STATUS_DIR}" ]] || die "status dir ${STATUS_DIR} does not exist"

# --- worktree removal: all terminal states ---
shopt -s nullglob
for f in "${STATUS_DIR}"/issue-*.done \
         "${STATUS_DIR}"/issue-*.failed \
         "${STATUS_DIR}"/issue-*.aborted \
         "${STATUS_DIR}"/issue-*.crashed; do
  base="$(basename "$f")"
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

# --- branch deletion: only for .done with MERGED PR ---
for f in "${STATUS_DIR}"/issue-*.done; do
  base="$(basename "$f")"
  issue_num="${base#issue-}"
  issue_num="${issue_num%.done}"

  pr_url="$(jq -r '.pr_url // empty' "$f" 2>/dev/null || true)"
  if [[ -z "$pr_url" ]]; then
    log "issue ${issue_num}: .done has no pr_url — preserving branches"
    continue
  fi
  pr_num="${pr_url##*/}"
  if ! [[ "$pr_num" =~ ^[0-9]+$ ]]; then
    log "issue ${issue_num}: pr_url '$pr_url' did not yield a numeric PR — preserving branches"
    continue
  fi

  state="$(gh pr view "$pr_num" --json state --jq .state 2>/dev/null || echo UNKNOWN)"
  if [[ "$state" != "MERGED" ]]; then
    log "issue ${issue_num}: PR #${pr_num} state=${state} (not MERGED) — preserving branches"
    continue
  fi

  for branch in "issue-${issue_num}-tests" "issue-${issue_num}-impl"; do
    if git -C "${REPO_ROOT}" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
      log "deleting remote branch ${branch}"
      git -C "${REPO_ROOT}" push origin --delete "$branch" >/dev/null 2>&1 \
        || log "  (remote delete failed; continuing)"
    fi
    if git -C "${REPO_ROOT}" show-ref --verify --quiet "refs/heads/${branch}"; then
      log "deleting local branch ${branch}"
      git -C "${REPO_ROOT}" branch -D "$branch" >/dev/null 2>&1 \
        || log "  (local delete failed; continuing)"
    fi
  done
done

log "done"
