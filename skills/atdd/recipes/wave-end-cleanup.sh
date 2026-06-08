#!/usr/bin/env bash
# wave-end-cleanup.sh — wave-end cleanup of worktrees and merged issue branches.
#
# Usage:  wave-end-cleanup.sh <root-id> <wave>
#
# Behavior:
#   - For each terminal status file (issue-<N>.{done,failed,aborted,crashed})
#     in this wave, removes both the test and impl worktrees for that issue,
#     and kills any leftover tmux windows (`issue-<N>`, `issue-<N>-PR`) in the
#     ws-<root-id> workspace session. Windows normally close on their own
#     (the impl supervisor kills its window; the test CLI exits) but a window
#     lingers when the agent idles at the prompt instead of exiting, or when
#     the test window's shell survives the CLI exit.
#   - For each `.done` issue marked merged (`"merged": true` in its status file,
#     written by Root after a successful `atdd integrate`), deletes the
#     `issue-<N>-tests` and `issue-<N>-impl` branches (local + remote). The
#     content is captured in `agent-tdd/<task>` after the git merge.
#   - For non-`.done` terminal states (`.failed`, `.aborted`, `.crashed`) and
#     for `.done` issues NOT yet merged, branches are preserved — they may hold
#     the only copy of debugging context or unmerged work.
#   - Runs `git worktree prune` to clean up dangling references.
#   - Does NOT delete the status files themselves (they are the audit trail).

set -euo pipefail

log() { printf '[wave-end-cleanup] %s\n' "$*" >&2; }
die() { printf '[wave-end-cleanup] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: $0 <root-id> <wave>"
ROOT_ID="$1"
WAVE="$2"

# Recover the main repo's working tree regardless of caller's cwd. Root runs
# in its own worktree (.atdd/<root-id>/root/); --show-toplevel would
# return that path. --git-common-dir always points at <main-repo>/.git.
REPO_ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
STATE_DIR="${REPO_ROOT}/.atdd/${ROOT_ID}"
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
  # Kill leftover child windows for this terminal issue. Non-numeric window
  # names resolve by exact name match (the index-before-name pitfall only
  # bites numeric names — see PROTOCOL §2.1); already-closed windows are a
  # harmless no-op.
  for win in "issue-${issue_num}" "issue-${issue_num}-PR"; do
    if tmux kill-window -t "ws-${ROOT_ID}:${win}" 2>/dev/null; then
      log "killed leftover window ws-${ROOT_ID}:${win}"
    fi
  done
done

git -C "${REPO_ROOT}" worktree prune

# --- branch deletion: only for .done issues merged into the root branch ---
for f in "${STATUS_DIR}"/issue-*.done; do
  base="$(basename "$f")"
  issue_num="${base#issue-}"
  issue_num="${issue_num%.done}"

  merged="$(jq -r '.merged // false' "$f" 2>/dev/null || echo false)"
  if [[ "$merged" != "true" ]]; then
    log "issue ${issue_num}: .done not marked merged — preserving branches"
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
