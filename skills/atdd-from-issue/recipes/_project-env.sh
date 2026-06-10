# _project-env.sh — sourced by every recipe that shells out to `atdd`. Resolves
# the active project ONCE and exports ATDD_PROJECT, so every `atdd` call in the
# sourcing process is scoped to the right project.
#
# Precedence: existing $ATDD_PROJECT (orchestration / spawned agents already set
# it) > the manifest's .project_slug (planning / human Root) > "default".
#
# Sourced under the caller's `set -euo pipefail`, so every line here must be
# -e-safe (failures are swallowed; the worst case is the "default" fallback).
#
# Usage (near the top of a recipe, after the `command -v atdd` check):
#   source "$(dirname "${BASH_SOURCE[0]}")/_project-env.sh"

if [[ -z "${ATDD_PROJECT:-}" ]]; then
  __atdd_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  __atdd_mf="${__atdd_root:+${__atdd_root}/.atdd/manifest.json}"
  if [[ -n "${__atdd_mf:-}" && -f "${__atdd_mf}" ]]; then
    ATDD_PROJECT="$(jq -r '.project_slug // "default"' "${__atdd_mf}" 2>/dev/null || echo default)"
  else
    ATDD_PROJECT="default"
  fi
  export ATDD_PROJECT
  unset __atdd_root __atdd_mf
fi
