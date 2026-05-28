#!/usr/bin/env bash
# _graph.sh — internal helper. Fetch every RootIssue in the configured
# GitHubProject together with its direct `blocked by` and `blocking`
# neighbours, then emit one JSON object on stdout.
#
# Output shape (stable, downstream recipes depend on it):
#
#   {
#     "project_id": "PVT_xxx",
#     "issues": [
#       {
#         "number": 42,                          # issue number (in its repo)
#         "repo":   "Positive-LLC/pg-agent-erp", # nameWithOwner
#         "ref":    "Positive-LLC/pg-agent-erp#42",
#         "title":  "...",
#         "state":  "OPEN" | "CLOSED",
#         "created_at": "2026-05-28T01:23:45Z",
#         "node_id": "I_kwDO...",                # GraphQL global id
#         "labels": ["atdd:root", ...],
#         "blocked_by": ["Positive-LLC/pg-agent-erp#7", ...],
#         "blocking":   ["Positive-LLC/pg-agent-erp#99", ...],
#         "transitive_blocking_count": 3   # distinct OPEN downstream issues
#       },
#       ...
#     ]
#   }
#
# `transitive_blocking_count` is computed in jq assuming the graph is a DAG
# (which root-depend.sh enforces). The walk only traverses OPEN downstream:
# closed downstream issues are "already resolved" and do not need this node
# to close.
#
# Scoping rule (mirrors the same-graph invariant in §1/§7 of CORE.md):
# only RootIssues — i.e. issues whose labels include `atdd:root` AND that
# appear as items in the manifest-configured GitHubProject — are emitted.
#
# Underscore prefix = internal. Higher-level recipes call this; callers from
# outside the recipes/ dir should use topology-*.sh instead.
#
# Usage: _graph.sh [<manifest-path>]
#   <manifest-path> defaults to ${REPO_ROOT}/.agent-tdd/manifest.json,
#   resolved from `git rev-parse --show-toplevel`.

set -euo pipefail

log() { printf '[_graph] %s\n' "$*" >&2; }
die() { printf '[_graph] ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

# --- locate manifest ---
if [[ $# -ge 1 ]]; then
  MANIFEST="$1"
else
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die "not inside a git repo and no manifest path given"
  MANIFEST="${REPO_ROOT}/.agent-tdd/manifest.json"
fi
[[ -f "$MANIFEST" ]] || die "manifest not found at $MANIFEST (run manifest-ensure.sh first)"

PROJECT_OWNER="$(jq -er '.project.owner' "$MANIFEST")" \
  || die "manifest missing .project.owner — re-run manifest-ensure.sh"
PROJECT_NUMBER="$(jq -er '.project.number' "$MANIFEST")" \
  || die "manifest missing .project.number"
PROJECT_ID="$(jq -er '.project.id' "$MANIFEST")" \
  || die "manifest missing .project.id"
ROOT_LABEL="$(jq -er '.labels.root // "atdd:root"' "$MANIFEST")"

log "scope: org=${PROJECT_OWNER} project#${PROJECT_NUMBER} (${PROJECT_ID}) label=${ROOT_LABEL}"

# --- paginated GraphQL ---
# One page = 100 items + 50 direct neighbours per side. For the scale we
# expect (tens of RootIssues), this caps at one or two pages. Higher scale
# would warrant tightening the per-issue neighbour cap; revisit then.
QUERY='
query($org: String!, $proj: Int!, $after: String) {
  organization(login: $org) {
    projectV2(number: $proj) {
      items(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          content {
            ... on Issue {
              number
              title
              state
              createdAt
              id
              repository { nameWithOwner }
              labels(first: 30) { nodes { name } }
              blockedBy(first: 50) {
                nodes { number repository { nameWithOwner } state }
              }
              blocking(first: 50) {
                nodes { number repository { nameWithOwner } state }
              }
            }
          }
        }
      }
    }
  }
}'

# Accumulate raw item arrays page by page.
raw_items='[]'
after='null'
page=1
while :; do
  if [[ "$after" == "null" ]]; then
    resp="$(gh api graphql \
      -f query="$QUERY" \
      -F org="$PROJECT_OWNER" \
      -F proj="$PROJECT_NUMBER")"
  else
    resp="$(gh api graphql \
      -f query="$QUERY" \
      -F org="$PROJECT_OWNER" \
      -F proj="$PROJECT_NUMBER" \
      -F after="$after")"
  fi
  page_items="$(jq '.data.organization.projectV2.items.nodes' <<<"$resp")"
  raw_items="$(jq -s '.[0] + .[1]' <(echo "$raw_items") <(echo "$page_items"))"
  has_next="$(jq -r '.data.organization.projectV2.items.pageInfo.hasNextPage' <<<"$resp")"
  if [[ "$has_next" == "true" ]]; then
    after="$(jq -r '.data.organization.projectV2.items.pageInfo.endCursor' <<<"$resp")"
    log "fetched page ${page}, paging on..."
    page=$((page + 1))
  else
    log "fetched page ${page}, done"
    break
  fi
done

# --- shape, filter to RootIssues, compute transitive_blocking_count, emit ---
jq --arg root_label "$ROOT_LABEL" --arg project_id "$PROJECT_ID" '
  # Step 1: shape and filter RootIssues only.
  [ .[]
    | .content
    | select(. != null and (.labels.nodes | map(.name) | index($root_label)))
    | {
        number: .number,
        repo:   .repository.nameWithOwner,
        ref:    (.repository.nameWithOwner + "#" + (.number | tostring)),
        title:  .title,
        state:  .state,
        created_at: .createdAt,
        node_id: .id,
        labels: (.labels.nodes | map(.name)),
        blocked_by: (.blockedBy.nodes | map(.repository.nameWithOwner + "#" + (.number | tostring))),
        blocking:   (.blocking.nodes   | map(.repository.nameWithOwner + "#" + (.number | tostring)))
      }
  ] as $issues

  # Step 2: build OPEN-only forward adjacency for downstream walks.
  # adj_open[ref] = list of OPEN downstream refs (direct).
  | ([ $issues[] | select(.state == "OPEN") | .ref ]) as $open_refs
  | ( [ $issues[] | { (.ref): (.blocking | map(select(. as $r | $open_refs | index($r)))) } ] | add // {} ) as $adj_open

  # Step 3: transitive walk over the DAG.
  | def reach($adj; $node):
      ($adj[$node] // []) as $direct
      | ($direct + ($direct | map(reach($adj; .)) | add // [])) | unique;

  # Step 4: attach the count to each issue.
  {
    project_id: $project_id,
    issues: ( $issues | map(. + { transitive_blocking_count: (reach($adj_open; .ref) | length) }) )
  }
' <<<"$raw_items"
