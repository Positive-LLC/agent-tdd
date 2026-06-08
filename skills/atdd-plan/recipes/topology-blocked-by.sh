#!/usr/bin/env bash
# topology-blocked-by.sh — emit the RootIssues that <root#> depends on
# directly (i.e. they appear in <root#>'s `blocked_by`). Upstream neighbours.
#
# Usage:  topology-blocked-by.sh <root#>
# Output: JSON array on stdout.

set -euo pipefail

die() { printf '[topology-blocked-by] ERROR: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

[[ $# -eq 1 ]] || die "usage: topology-blocked-by.sh <root#>"
ROOT_N="$1"
[[ "$ROOT_N" =~ ^[0-9]+$ ]] || die "<root#> must be a number (got: $ROOT_N)"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.atdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found"
HOME_REPO="$(jq -er '.home_repo' "$MANIFEST")"
TARGET_REF="${HOME_REPO}#${ROOT_N}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GRAPH_JSON="$("${SCRIPT_DIR}/_graph.sh")" || die "graph fetch failed"

# Find the target, take its blocked_by list, then join back to full issue records.
jq --arg ref "$TARGET_REF" '
  ( [ .issues[] | select(.ref == $ref) ] | first ) as $me
  | if $me == null then [] else
      ( $me.blocked_by ) as $upstream_refs
      | [ .issues[]
          | select(.ref as $r | $upstream_refs | index($r))
          | { number, repo, ref, title, state, created_at, transitive_blocking_count }
        ]
      | sort_by( [ -.transitive_blocking_count, .created_at ] )
    end
' <<<"$GRAPH_JSON"
