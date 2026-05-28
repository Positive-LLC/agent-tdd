#!/usr/bin/env bash
# topology-available.sh — emit every OPEN RootIssue whose blockers are all
# closed (i.e. workable right now), sorted by transitive_blocking_count DESC,
# then created_at ASC.
#
# Usage:  topology-available.sh
# Output: JSON array on stdout, items
#         { number, repo, ref, title, state, created_at, transitive_blocking_count }

set -euo pipefail

die() { printf '[topology-available] ERROR: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GRAPH_JSON="$("${SCRIPT_DIR}/_graph.sh")" || die "graph fetch failed"

jq '
  [ .issues[] | select(.state == "OPEN") ] as $open
  | ($open | map(.ref)) as $open_refs
  | [ $open[]
      | select( (.blocked_by | map(select(. as $r | $open_refs | index($r))) | length) == 0 )
      | { number, repo, ref, title, state, created_at, transitive_blocking_count }
    ]
  | sort_by( [ -.transitive_blocking_count, .created_at ] )
' <<<"$GRAPH_JSON"
