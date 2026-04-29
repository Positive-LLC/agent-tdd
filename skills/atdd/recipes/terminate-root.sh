#!/usr/bin/env bash
# terminate-root.sh — clean termination of a Root.
#
# Usage:  terminate-root.sh <root-id> <root-task>
#
# Behavior (idempotent — safe to re-run after partial failure):
#   1. Removes Root's private worktree at .agent-tdd/<root-id>/root/.
#      MUST happen before branch deletion (git refuses to delete a branch that
#      is checked out in any worktree).
#   2. Deletes the integration branch agent-tdd/<task> on origin (if present).
#   3. Deletes the integration branch locally (if present).
#   4. Prunes dangling worktree references.
#
# Does NOT delete .agent-tdd/<root-id>/ itself — the audit trail (status files,
# logs, meta.json, feedback.md) is preserved for forensics. The human can
# `rm -rf .agent-tdd/<root-id>/` once they don't need it.
#
# All progress messages go to stderr.

set -uo pipefail   # NOT -e: we want to continue past idempotent no-ops

log() { printf '[terminate-root] %s\n' "$*" >&2; }
die() { printf '[terminate-root] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: $0 <root-id> <root-task>"
ROOT_ID="$1"
ROOT_TASK="$2"

[[ "$ROOT_ID" =~ ^root-[0-9]+$ ]] || die "invalid root-id: $ROOT_ID"
[[ "$ROOT_TASK" =~ ^[a-z0-9-]+$ ]] || die "invalid root-task: $ROOT_TASK"

# Recover main repo path; --git-common-dir works whether the caller is in the
# main worktree, Root's worktree, or any child worktree.
REPO_ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)" \
  || die "could not resolve REPO_ROOT — are you inside the repo?"

STATE_DIR="${REPO_ROOT}/.agent-tdd/${ROOT_ID}"
ROOT_WORKTREE="${STATE_DIR}/root"
INTEGRATION_BRANCH="agent-tdd/${ROOT_TASK}"

# --- step 1: remove Root's worktree (must precede branch deletion) ---
if [[ -d "${ROOT_WORKTREE}" ]]; then
  log "removing Root worktree ${ROOT_WORKTREE}"
  git -C "${REPO_ROOT}" worktree remove --force "${ROOT_WORKTREE}" 2>/dev/null \
    || rm -rf "${ROOT_WORKTREE}"
else
  log "Root worktree ${ROOT_WORKTREE} already absent"
fi

# --- step 2: delete remote integration branch ---
if git -C "${REPO_ROOT}" ls-remote --exit-code --heads origin "${INTEGRATION_BRANCH}" >/dev/null 2>&1; then
  log "deleting remote branch ${INTEGRATION_BRANCH}"
  git -C "${REPO_ROOT}" push origin --delete "${INTEGRATION_BRANCH}" >/dev/null 2>&1 \
    || log "  (remote delete failed; continuing — branch may have already been deleted)"
else
  log "remote branch ${INTEGRATION_BRANCH} already absent"
fi

# --- step 3: delete local integration branch ---
if git -C "${REPO_ROOT}" show-ref --verify --quiet "refs/heads/${INTEGRATION_BRANCH}"; then
  log "deleting local branch ${INTEGRATION_BRANCH}"
  git -C "${REPO_ROOT}" branch -D "${INTEGRATION_BRANCH}" >/dev/null 2>&1 \
    || die "local branch delete failed — is it checked out elsewhere? Run 'git worktree list' to investigate"
else
  log "local branch ${INTEGRATION_BRANCH} already absent"
fi

# --- step 4: prune dangling worktree refs ---
git -C "${REPO_ROOT}" worktree prune

log "done"
