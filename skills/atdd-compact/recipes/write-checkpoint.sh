#!/usr/bin/env bash
# write-checkpoint.sh — persist the compact-handoff brief and post it to the
# wave's in-flight GitHub artifacts.
#
# Usage:  write-checkpoint.sh <root-id> <handoff-content-file>
#
#   <root-id>               — e.g. root-3
#   <handoff-content-file>  — absolute path to the rendered brief (Root drafts
#                             it from templates/checkpoint-comment.md and writes
#                             to /tmp/atdd-handoff-<root-id>-<wave>.md before
#                             calling this recipe)
#
# Effects:
#   1. Copies the brief to .agent-tdd/<root-id>/wave-<N>/handoff.md (durable;
#      survives the prior Root's death and any GitHub-side issues).
#   2. Posts the brief as a comment on every issue with labels
#      agent-tdd:active-wave-<N> AND agent-tdd:root-<id>.
#   3. Posts the brief as a comment on every open impl PR for those issues
#      (head ref pattern: issue-<X>-impl).
#
# Idempotent in the durable-write sense (handoff.md gets overwritten); GitHub
# comments are append-only by nature, so re-running this recipe will produce
# duplicate comments. Root only invokes it once per /atdd-compact run.
#
# Progress messages → stderr. Stdout is empty on success.

set -euo pipefail

log() { printf '[write-checkpoint] %s\n' "$*" >&2; }
die() { printf '[write-checkpoint] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: $0 <root-id> <handoff-content-file>"
ROOT_ID="$1"
BRIEF="$2"

[[ "$ROOT_ID" =~ ^root-[a-z0-9-]+$ ]] || die "bad root-id: ${ROOT_ID}"
[[ -f "$BRIEF" ]] || die "brief file not found: ${BRIEF}"
[[ -s "$BRIEF" ]] || die "brief file is empty: ${BRIEF}"

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

# --- resolve repo root + state dir + wave ---
REPO_ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)" \
  || die "not inside a git repo"
STATE_DIR="${REPO_ROOT}/.agent-tdd/${ROOT_ID}"
META="${STATE_DIR}/meta.json"
[[ -f "$META" ]] || die "meta.json not found at ${META}"

WAVE="$(jq -r '.current_wave' "$META")"
[[ "$WAVE" =~ ^[0-9]+$ ]] && (( WAVE > 0 )) \
  || die "current_wave is not a positive integer (got: ${WAVE})"

WAVE_DIR="${STATE_DIR}/wave-${WAVE}"
[[ -d "$WAVE_DIR" ]] || die "wave directory missing: ${WAVE_DIR}"

# --- ensure correct gh account ---
GH_ACCOUNT="$(jq -r '.gh_account // empty' "$META")"
if [[ -n "$GH_ACCOUNT" ]]; then
  log "switching gh account to ${GH_ACCOUNT}"
  gh auth switch --user "$GH_ACCOUNT" >/dev/null 2>&1 \
    || die "failed to gh auth switch --user ${GH_ACCOUNT}"
fi

# --- 1. write durable handoff.md ---
HANDOFF="${WAVE_DIR}/handoff.md"
log "writing ${HANDOFF}"
cp "$BRIEF" "$HANDOFF"

# --- 2. enumerate active wave issues ---
log "listing active wave issues (wave-${WAVE}, ${ROOT_ID})"
ISSUES_JSON="$(gh issue list \
  --label "agent-tdd:active-wave-${WAVE}" \
  --label "agent-tdd:root-${ROOT_ID}" \
  --state all \
  --json number,title,state \
  --limit 50)" || die "gh issue list failed"

ISSUE_NUMBERS=()
while IFS= read -r n; do
  [[ -n "$n" ]] && ISSUE_NUMBERS+=("$n")
done < <(echo "$ISSUES_JSON" | jq -r '.[].number')

if [[ ${#ISSUE_NUMBERS[@]} -eq 0 ]]; then
  log "warning: no issues found with labels agent-tdd:active-wave-${WAVE} + agent-tdd:root-${ROOT_ID}"
  log "(handoff.md was still written; new Root will read it from disk)"
  exit 0
fi
log "found ${#ISSUE_NUMBERS[@]} active wave issue(s): ${ISSUE_NUMBERS[*]}"

# --- 3. comment brief on every active wave issue ---
ISSUE_FAILS=0
for n in "${ISSUE_NUMBERS[@]}"; do
  if gh issue comment "$n" --body-file "$BRIEF" >/dev/null 2>&1; then
    log "  posted brief to issue #${n}"
  else
    log "  WARN: failed to post brief to issue #${n}"
    ISSUE_FAILS=$((ISSUE_FAILS + 1))
  fi
done

# --- 4. find and comment on impl PRs for those issues ---
# Each impl PR's head branch follows the pattern issue-<N>-impl; we ask gh
# explicitly per issue to avoid pulling unrelated PRs into the result.
PR_FAILS=0
PR_HITS=0
for n in "${ISSUE_NUMBERS[@]}"; do
  PR_LIST="$(gh pr list \
    --head "issue-${n}-impl" \
    --state all \
    --json number,state,url \
    --limit 5 2>/dev/null || true)"
  while IFS= read -r pr; do
    [[ -z "$pr" || "$pr" == "null" ]] && continue
    # Only comment on non-merged PRs. Merged PRs are immutable in spirit; the
    # handoff is for in-flight work, and merged-PR comments add noise.
    pr_state="$(echo "$PR_LIST" | jq -r ".[] | select(.number == ${pr}) | .state")"
    case "$pr_state" in
      OPEN|CLOSED) ;;  # comment-eligible
      MERGED) log "  skipping PR #${pr} (already MERGED)"; continue ;;
      *) ;;
    esac
    if gh pr comment "$pr" --body-file "$BRIEF" >/dev/null 2>&1; then
      log "  posted brief to PR #${pr} (issue #${n}, state=${pr_state})"
      PR_HITS=$((PR_HITS + 1))
    else
      log "  WARN: failed to post brief to PR #${pr}"
      PR_FAILS=$((PR_FAILS + 1))
    fi
  done < <(echo "$PR_LIST" | jq -r '.[].number')
done

log "summary: ${#ISSUE_NUMBERS[@]} issue comments (${ISSUE_FAILS} failed), ${PR_HITS} PR comments (${PR_FAILS} failed)"
log "durable copy: ${HANDOFF}"

# Non-zero exit if everything failed; partial failures are warnings (the
# durable handoff.md is the load-bearing artifact).
if [[ $ISSUE_FAILS -eq ${#ISSUE_NUMBERS[@]} ]] && [[ ${#ISSUE_NUMBERS[@]} -gt 0 ]]; then
  die "all issue comments failed — check gh auth and rate limits"
fi

exit 0
