#!/usr/bin/env bash
# init-root.sh — bootstrap a Root for Agent TDD.
#
# Usage:  init-root.sh <root-task-slug> [base-branch]
#
# Effects:
#   - Determines next available root-id (root-1, root-2, ...).
#   - Creates integration branch `agent-tdd/<root-task-slug>` off <base-branch>.
#   - Pushes integration branch to origin.
#   - Creates `.agent-tdd/<root-id>/` and writes `meta.json`.
#   - Ensures `.agent-tdd/` is in repo `.gitignore`.
#
# Prints the chosen root-id to stdout (the only stdout output — Root reads it).
# All progress messages go to stderr.

set -euo pipefail

log() { printf '[init-root] %s\n' "$*" >&2; }
die() { printf '[init-root] ERROR: %s\n' "$*" >&2; exit 1; }

# --- args ---
[[ $# -ge 1 ]] || die "missing arg: <root-task-slug> [base-branch]"
ROOT_TASK="$1"
BASE_BRANCH="${2:-main}"

[[ "$ROOT_TASK" =~ ^[a-z0-9-]+$ ]] || die "root-task must match ^[a-z0-9-]+$ (got: $ROOT_TASK)"

# --- repo sanity ---
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repo"
git diff --quiet || die "working tree has unstaged changes; clean up first"
git diff --cached --quiet || die "working tree has staged changes; clean up first"

# --- choose root-id ---
mkdir -p .agent-tdd
existing=$(ls .agent-tdd 2>/dev/null | grep -E '^root-[0-9]+$' || true)
if [[ -z "$existing" ]]; then
  next=1
else
  next=$(echo "$existing" | sed 's/^root-//' | sort -n | tail -1)
  next=$((next + 1))
fi
ROOT_ID="root-${next}"
STATE_DIR=".agent-tdd/${ROOT_ID}"
log "chose root-id: ${ROOT_ID}"

[[ -d "$STATE_DIR" ]] && die "$STATE_DIR already exists; refusing to overwrite"
mkdir -p "$STATE_DIR"

# --- ensure .gitignore has .agent-tdd/ ---
GITIGNORE=".gitignore"
[[ -f "$GITIGNORE" ]] || touch "$GITIGNORE"
if ! grep -qE '^\.agent-tdd/?$' "$GITIGNORE"; then
  log "adding .agent-tdd/ to $GITIGNORE"
  printf '\n.agent-tdd/\n' >> "$GITIGNORE"
fi

# --- verify base branch exists ---
git show-ref --verify --quiet "refs/heads/${BASE_BRANCH}" \
  || git show-ref --verify --quiet "refs/remotes/origin/${BASE_BRANCH}" \
  || die "base branch '$BASE_BRANCH' not found locally or on origin"

# --- create + push integration branch ---
INTEGRATION_BRANCH="agent-tdd/${ROOT_TASK}"
if git show-ref --verify --quiet "refs/heads/${INTEGRATION_BRANCH}"; then
  die "branch '${INTEGRATION_BRANCH}' already exists locally; pick a different task slug"
fi
if git ls-remote --exit-code --heads origin "${INTEGRATION_BRANCH}" >/dev/null 2>&1; then
  die "branch '${INTEGRATION_BRANCH}' already exists on origin; pick a different task slug"
fi

log "creating ${INTEGRATION_BRANCH} from ${BASE_BRANCH}"
git fetch origin "${BASE_BRANCH}" --quiet
git checkout -b "${INTEGRATION_BRANCH}" "origin/${BASE_BRANCH}"
git push -u origin "${INTEGRATION_BRANCH}"

# --- meta.json ---
META="${STATE_DIR}/meta.json"
cat > "${META}" <<EOF
{
  "root_id": "${ROOT_ID}",
  "task": "${ROOT_TASK}",
  "base": "${BASE_BRANCH}",
  "max_waves": 10,
  "wave_size_cap": 5,
  "current_wave": 0
}
EOF
log "wrote ${META}"

# --- output the root-id (stdout) ---
echo "${ROOT_ID}"
