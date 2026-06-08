#!/usr/bin/env bash
# topology-blocking.sh — emit the RootIssues that depend on <root#> directly
# (i.e. <root#> appears in their `blocked_by`). Downstream neighbours.
#
# Sorted the same way as available/next-urgent so output is stable.
#
# Usage:  topology-blocking.sh <root#>
# Output: JSON array on stdout.

set -euo pipefail

die() { printf '[topology-blocking] ERROR: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

[[ $# -eq 1 ]] || die "usage: topology-blocking.sh <root#>"
ROOT_N="$1"
[[ "$ROOT_N" =~ ^[0-9]+$ ]] || die "<root#> must be a number (got: $ROOT_N)"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.atdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found"
HOME_REPO="$(jq -er '.home_repo' "$MANIFEST")"
TARGET_REF="${HOME_REPO}#${ROOT_N}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GRAPH_JSON="$("${SCRIPT_DIR}/_graph.sh")" || die "graph fetch failed"

jq --arg ref "$TARGET_REF" '
  [ .issues[]
    | select(.blocked_by | index($ref))
    | { number, repo, ref, title, state, created_at, transitive_blocking_count }
  ]
  | sort_by( [ -.transitive_blocking_count, .created_at ] )
' <<<"$GRAPH_JSON"
