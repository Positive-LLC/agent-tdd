#!/usr/bin/env bash
# ref-qualification.sh — regression gate for Positive-LLC/agent-tdd#9.
#
# Contract under test: every `atdd` verb call in the spawned-agent role
# markdowns and the spawn recipes must pass a *qualified* full issue ref
# `${REF}` (owner/repo#N), never a bare `${ISSUE_NUM}`. The spawn recipes must
# construct `REF` and thread it to the agent they launch (into the Per-Issue
# Task block AND the pane env as `ATDD_ISSUE_REF`); `launch-impl-agent.sh` must
# pass that env through.
#
# Why bare `${ISSUE_NUM}` is a bug: the `atdd` CLI rejects a bare number
# (`bad ref '9' (expected owner/repo#number)`), so an agent that copied a role
# doc verbatim would fail its first `atdd issue view`. This gate stops the
# refs from regressing to the bare form.
#
# The two `<owner/repo>#${ISSUE_NUM}` template lines (TEST_AGENT_ROLE.md and
# IMPL_AGENT_ROLE.md `layer link` examples) already spell out the full-ref
# shape inline and are intentionally left alone — they are excluded here by
# their `<owner/repo>` marker.
#
# Hermetic: pure `grep` over checked-in files. No `atdd` binary, no daemon, no
# network. Locates the skills tree relative to THIS script, so the working
# directory does not matter.
#
# Run:  bash skills/atdd-plan/recipes/tests/ref-qualification.sh
# Exit: 0 = every behavior present (GREEN); 1 = at least one gap (RED).

set -uo pipefail

THIS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# tests/ -> recipes/ -> atdd-plan/ -> skills/
SKILLS_DIR="$(cd -- "${THIS_DIR}/../../.." && pwd)"
ROLES_DIR="${SKILLS_DIR}/atdd/roles"
RECIPES_DIR="${SKILLS_DIR}/atdd/recipes"

TESTS_RUN=0
TESTS_FAIL=0
pass() { TESTS_RUN=$((TESTS_RUN+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() {
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1))
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '%s\n' "$2"
  return 0
}

ROLES=(TEST_AGENT_ROLE.md IMPL_AGENT_ROLE.md REBASE_AGENT_ROLE.md)

# Bare `atdd … ${ISSUE_NUM}` call sites, minus the already-qualified
# <owner/repo># template lines. Fixed-string matching throughout: `${ISSUE_NUM}`
# contains `$`, which grep would otherwise read as an end-of-line anchor.
bare_calls() { grep -F 'atdd ' "$1" 2>/dev/null | grep -F '${ISSUE_NUM}' | grep -vF 'owner/repo>'; }
# `atdd … ${REF}` call sites (the migration target).
ref_calls()  { grep -F 'atdd ' "$1" 2>/dev/null | grep -F '${REF}'; }

echo "== ref-qualification (issue #9): atdd calls use \${REF}, not bare \${ISSUE_NUM} =="

# (A) No bare `atdd … ${ISSUE_NUM}` call sites survive in any role markdown.
#     This is the core behavior: all 12 in-scope sites migrated.
for r in "${ROLES[@]}"; do
  f="${ROLES_DIR}/${r}"
  hits="$(bare_calls "$f")"
  if [[ -z "$hits" ]]; then
    pass "${r}: no bare 'atdd … \${ISSUE_NUM}' call sites"
  else
    fail "${r}: bare 'atdd … \${ISSUE_NUM}' call sites remain" "$(printf '%s\n' "$hits" | sed 's/^/           | /')"
  fi
done

# (B) The migrated calls actually reference ${REF} (guards against a degenerate
#     "just delete the argument" edit that would pass (A) but break the calls).
for r in "${ROLES[@]}"; do
  f="${ROLES_DIR}/${r}"
  if [[ -n "$(ref_calls "$f")" ]]; then
    pass "${r}: has at least one 'atdd … \${REF}' call"
  else
    fail "${r}: no 'atdd … \${REF}' call — migration target variable missing"
  fi
done

# (C) ${REF} is documented as owner/repo#N in each role's variable docs.
for r in "${ROLES[@]}"; do
  f="${ROLES_DIR}/${r}"
  if grep -Eq '`REF`.*owner/repo' "$f"; then
    pass "${r}: documents \`REF\` (owner/repo#N) in variable docs"
  else
    fail "${r}: variable docs do not document \`REF\` as owner/repo#N"
  fi
done

# (D) The spawn recipes construct REF from the repo + issue number and thread it
#     to the agent they launch — both into the Per-Issue Task block (so the
#     role's ${REF} resolves) and into the pane env as ATDD_ISSUE_REF.
for s in spawn-test-agent spawn-impl-agent; do
  f="${RECIPES_DIR}/${s}.sh"
  grep -Eq 'REF=.*#.*ISSUE_NUM' "$f" \
    && pass "${s}.sh: constructs REF (…#\${ISSUE_NUM})" \
    || fail "${s}.sh: no 'REF=\"…#\${ISSUE_NUM}\"' construction"
  grep -Fq 'echo "REF=' "$f" \
    && pass "${s}.sh: emits REF into the Per-Issue Task block" \
    || fail "${s}.sh: Per-Issue Task block never sets REF (role's \${REF} would be undefined)"
  grep -Fq 'ATDD_ISSUE_REF' "$f" \
    && pass "${s}.sh: exports ATDD_ISSUE_REF into the agent env" \
    || fail "${s}.sh: does not export ATDD_ISSUE_REF"
done

# (E) launch-impl-agent.sh passes the full ref through as ATDD_ISSUE_REF.
f="${RECIPES_DIR}/launch-impl-agent.sh"
grep -Fq 'ATDD_ISSUE_REF' "$f" \
  && pass "launch-impl-agent.sh: threads ATDD_ISSUE_REF" \
  || fail "launch-impl-agent.sh: does not thread ATDD_ISSUE_REF"

echo
if [[ "$TESTS_FAIL" -eq 0 ]]; then
  printf '\033[32mALL PASS\033[0m — %d checks\n' "$TESTS_RUN"
  exit 0
else
  printf '\033[31m%d/%d FAILED\033[0m\n' "$TESTS_FAIL" "$TESTS_RUN"
  exit 1
fi
