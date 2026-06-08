#!/usr/bin/env bash
# no-gh-guard.sh — prove there is no `gh` in the inner flow (Phase 1 done-criteria).
#
# Rules:
#   * Recipe scripts (skills/**/recipes/*.sh) must NOT execute `gh` at all — any
#     non-comment `gh ` line is RED. (The recipes' test mock/poison `gh` under
#     tests/bin is excluded — it exists precisely to catch leaks.)
#   * Docs (skills/**/*.md) may mention `gh` ONLY for the single optional final
#     hand-off PR to base: `gh pr create` / `gh pr merge`. Any inner-flow verb
#     (`gh issue|api|project|auth|run`, `gh pr checks|comment|view`) is RED.
#
# Exit 0 (GREEN) if clean, 1 (RED) otherwise. Run from the repo root or anywhere.

set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SKILLS="${ROOT}/skills"
RED=0

note() { printf '  %s\n' "$*"; }

echo "== no-gh guard: recipe scripts (must execute zero gh) =="
while IFS= read -r -d '' f; do
  # skip the test harness (its poison gh + checks intentionally name gh)
  case "$f" in */tests/*) continue;; esac
  # non-comment lines that invoke gh
  hits="$(grep -nE '(^|[^A-Za-z._-])gh ' "$f" | grep -vE '^\s*[0-9]+:\s*#' || true)"
  if [[ -n "$hits" ]]; then
    RED=1; echo "RED $f"; sed 's/^/    /' <<<"$hits"
  fi
done < <(find "$SKILLS" -type f -name '*.sh' -print0)
[[ "$RED" -eq 0 ]] && note "clean: no recipe executes gh"

echo "== no-gh guard: docs (gh only for the final PR: gh pr create|merge) =="
FORBIDDEN='gh (issue|api|project|auth|run )|gh pr (checks|comment|view)'
while IFS= read -r -d '' f; do
  hits="$(grep -nE "${FORBIDDEN}" "$f" || true)"
  if [[ -n "$hits" ]]; then
    RED=1; echo "RED $f"; sed 's/^/    /' <<<"$hits"
  fi
done < <(find "$SKILLS" -type f -name '*.md' -print0)

echo
if [[ "$RED" -eq 0 ]]; then
  printf '\033[32mGREEN\033[0m — no gh in the inner flow\n'; exit 0
else
  printf '\033[31mRED\033[0m — inner-flow gh remains (see above)\n'; exit 1
fi
