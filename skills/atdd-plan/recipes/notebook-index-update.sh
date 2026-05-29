#!/usr/bin/env bash
# notebook-index-update.sh — regenerate the NotebookIssue body's topology
# index from live GitHub state.
#
# The body is a cached projection (single source of truth = GitHub). Re-run
# this after any RootIssue create/depend/close so the index stays current.
#
# Usage:  notebook-index-update.sh

set -euo pipefail

log() { printf '[notebook-index-update] %s\n' "$*" >&2; }
die() { printf '[notebook-index-update] ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
MANIFEST="${REPO_ROOT}/.agent-tdd/manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found (run manifest-ensure.sh first)"

HOME_REPO="$(jq -er '.home_repo' "$MANIFEST")"
NB_NUMBER="$(jq -er '.notebook_issue.number' "$MANIFEST")"
NB_URL="$(jq -er '.notebook_issue.url' "$MANIFEST")"
PROJECT_TITLE="$(jq -er '.project.title' "$MANIFEST")"
PROJECT_URL="$(jq -er '.project.url' "$MANIFEST")"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GRAPH_JSON="$("${SCRIPT_DIR}/_graph.sh")" || die "graph fetch failed"

# Build the markdown body.
TABLE="$(jq -r '
  if (.issues | length) == 0 then
    "_No RootIssues yet._"
  else
    "| Ref | State | TBC | Title |\n|---|---|---|---|\n" +
    ( .issues
      | sort_by(.number)
      | map("| [\(.ref)](https://github.com/\(.repo)/issues/\(.number)) | \(.state) | \(.transitive_blocking_count) | \(.title | gsub("\\|"; "\\|")) |")
      | join("\n") )
  end
' <<<"$GRAPH_JSON")"

ADJ="$(jq -r '
  if (.issues | map(select(.blocked_by | length > 0)) | length) == 0 then
    "_No dependencies._"
  else
    [ .issues[]
      | select(.blocked_by | length > 0)
      | "- `\(.ref)` blocked by: " + ( .blocked_by | map("`" + . + "`") | join(", ") )
    ] | sort | join("\n")
  end
' <<<"$GRAPH_JSON")"

TBC_LEGEND="TBC = transitive_blocking_count (distinct OPEN downstream RootIssues that depend on this one). Higher = closing this unblocks more."

NOW="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

BODY=$(cat <<EOF
**Notes Agent private notebook** for GitHubProject [${PROJECT_TITLE}](${PROJECT_URL}).

This issue is the durable working memory of the Agent TDD Notes Agent. The
body below is the topology index of every RootIssue. One comment per
RootIssue holds that head's detailed notes (look for a leading
\`<!-- atdd-head: <owner>/<repo>#<N> -->\` marker).

Maintained by recipes under \`skills/atdd-plan/recipes/\` of
\`Positive-LLC/agent-tdd\`. Do **not** edit this body manually — re-run
\`notebook-index-update.sh\` instead.

## Topology index

${TBC_LEGEND}

${TABLE}

## Dependencies (blocked-by)

${ADJ}

---
_Last updated: ${NOW} (UTC)_
EOF
)

log "PATCH ${NB_URL} body"
gh api -X PATCH "repos/${HOME_REPO}/issues/${NB_NUMBER}" \
  -f body="$BODY" >/dev/null \
  || die "failed to PATCH NotebookIssue body"

log "ok"
