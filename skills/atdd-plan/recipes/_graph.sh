#!/usr/bin/env bash
# _graph.sh — internal helper. Emit the RootIssue topology graph from the local
# atdd store. Now a thin wrapper over `atdd topology graph` (Phase 1: GitHub /
# the GitHubProject are gone; membership is implicit — any work-item carrying
# `atdd:root` is a RootIssue).
#
# Output shape (stable; topology-*.sh + notebook-index-update.sh depend on it):
#   { "issues": [ { number, repo, ref, title, state, created_at, node_id,
#                   labels, blocked_by, blocking, transitive_blocking_count } ] }
#
# `transitive_blocking_count` is computed in the atdd store (open-only forward
# adjacency over the DAG), matching the old jq exactly.
#
# Usage: _graph.sh   (any args are ignored — the store is the single source)

set -euo pipefail

die() { printf '[_graph] ERROR: %s\n' "$*" >&2; exit 1; }
command -v atdd >/dev/null 2>&1 || die "atdd CLI not found on PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_project-env.sh"

atdd topology graph
