#!/usr/bin/env bash
# root-depend.sh — add a native `blocked by` edge between two RootIssues.
#
# Both arguments are RootIssue numbers in the manifest's home repo. (Topology
# only lives between RootIssues, and they all live in the home repo by §3.2.)
#
# Enforces three invariants BEFORE writing — graph integrity is centralised
# here so every topology query downstream can trust the graph is a clean,
# RootIssue-only DAG:
#
#   1. No self-loop  : reject if <blocked> == <blocking>.
#   2. No cycle      : walk <blocking>'s transitive blockers in the live
#                      graph; reject if <blocked> appears.
#   3. Same-graph    : both ends must carry `atdd:root` AND appear as items
#                      of the manifest's GitHubProject.
#
# Usage:  root-depend.sh <blocked-root-number> <blocking-root-number>
# Output: nothing on success; non-zero exit + stderr message on rejection.

set -euo pipefail

log() { printf '[root-depend] %s\n' "$*" >&2; }
die() { printf '[root-depend] ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

[[ $# -eq 2 ]] || die "usage: root-depend.sh <blocked-root#> <blocking-root#>"
BLOCKED="$1"
BLOCKING="$2"
[[ "$BLOCKED"  =~ ^[0-9]+$ ]] || die "<blocked> must be a number (got: $BLOCKED)"
[[ "$BLOCKING" =~ ^[0-9]+$ ]] || die "<blocking> must be a number (got: $BLOCKING)"

# (1) no self-loop ----------------------------------------------------------
[[ "$BLOCKED" != "$BLOCKING" ]] || die "rule#1 self-loop: $BLOCKED depends on itself"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.agent-tdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found (run manifest-ensure.sh first)"
HOME_REPO="$(jq -er '.home_repo' "$MANIFEST")"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GRAPH_JSON="$("${SCRIPT_DIR}/_graph.sh")" || die "failed to fetch graph"

BLOCKED_REF="${HOME_REPO}#${BLOCKED}"
BLOCKING_REF="${HOME_REPO}#${BLOCKING}"

# (3) same-graph — both must be in the project + RootIssue-labelled ---------
present_check() {
  local ref="$1"
  jq -e --arg r "$ref" '
    .issues | map(.ref) | index($r) != null
  ' >/dev/null <<<"$GRAPH_JSON"
}
present_check "$BLOCKED_REF" \
  || die "rule#3 same-graph: ${BLOCKED_REF} is not a RootIssue in this project"
present_check "$BLOCKING_REF" \
  || die "rule#3 same-graph: ${BLOCKING_REF} is not a RootIssue in this project"

# (2) cycle check — would the new edge close a loop? ------------------------
# Adding `BLOCKED <- BLOCKING` (BLOCKED is now blocked by BLOCKING). A cycle
# forms iff BLOCKING transitively depends on BLOCKED. So we walk BLOCKING's
# blocked_by closure and reject if BLOCKED appears.
CYCLE_HIT="$(jq -r \
  --arg start "$BLOCKING_REF" \
  --arg target "$BLOCKED_REF" '
  # Build forward adjacency: ref -> [refs that block it]
  ( .issues | map({ key: .ref, value: .blocked_by }) | from_entries ) as $adj
  | def visit($node; $seen):
      if $seen[$node] then $seen
      else ($seen + { ($node): true }) as $s2
        | reduce ($adj[$node] // [])[] as $n ($s2; visit($n; .))
      end;
  visit($start; {}) | has($target) | if . then "HIT" else "OK" end
' <<<"$GRAPH_JSON")"

if [[ "$CYCLE_HIT" == "HIT" ]]; then
  die "rule#2 cycle: ${BLOCKING_REF} transitively depends on ${BLOCKED_REF} — adding '${BLOCKED_REF} blocked by ${BLOCKING_REF}' would form a cycle"
fi

# --- write the dependency ---
# REST endpoint POST /repos/{owner}/{repo}/issues/{N}/dependencies/blocked_by
# expects an integer issue_id (mirroring the sub_issues pattern). Fetch the
# blocker's database id, then POST.
BLOCKING_DB_ID="$(gh api "repos/${HOME_REPO}/issues/${BLOCKING}" -q .id)" \
  || die "failed to fetch ${BLOCKING_REF} database id"

log "adding ${BLOCKED_REF} blocked_by ${BLOCKING_REF} (db_id=${BLOCKING_DB_ID})"
gh api -X POST "repos/${HOME_REPO}/issues/${BLOCKED}/dependencies/blocked_by" \
  -F issue_id="$BLOCKING_DB_ID" >/dev/null \
  || die "failed to write dependency"

log "ok"
