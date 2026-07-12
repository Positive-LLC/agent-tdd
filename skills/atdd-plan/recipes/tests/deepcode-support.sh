#!/usr/bin/env bash
# deepcode-support.sh — regression gate for deepcode CLI support.
#
# Verifies the deepcode launch branches and documentation added across
# spawn/launch recipes and SKILL.md. Hermetic: pure grep over checked-in
# files. No atdd binary, no daemon, no network. Locates skills tree relative
# to THIS script, so the working directory does not matter.
#
# Run:  bash skills/atdd-plan/recipes/tests/deepcode-support.sh
# Exit: 0 = every behavior present (GREEN); 1 = at least one gap (RED).

set -uo pipefail

THIS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# tests/ -> recipes/ -> atdd-plan/ -> skills/
SKILLS_DIR="$(cd -- "${THIS_DIR}/../../.." && pwd)"
RECIPES_DIR="${SKILLS_DIR}/atdd/recipes"
PLAN_RECIPES_DIR="${SKILLS_DIR}/atdd-plan/recipes"
COMPACT_RECIPES_DIR="${SKILLS_DIR}/atdd-compact/recipes"
PLUGIN_ROOT="$(cd -- "${SKILLS_DIR}/.." && pwd)"

TESTS_RUN=0
TESTS_FAIL=0
pass() { TESTS_RUN=$((TESTS_RUN+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() {
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1))
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '%s\n' "$2"
  return 0
}

echo "== deepcode-support: recipe launch branches =="

# --- Syntax checks ---
for f in \
  "${RECIPES_DIR}/spawn-test-agent.sh" \
  "${RECIPES_DIR}/launch-impl-agent.sh" \
  "${PLAN_RECIPES_DIR}/launch-root.sh" \
  "${COMPACT_RECIPES_DIR}/spawn-resume-window.sh"
do
  if bash -n "$f" 2>/dev/null; then
    pass "syntax $(basename "$f")"
  else
    fail "syntax $(basename "$f")"
  fi
done

# --- Deepcode launch branch in each spawn/launch recipe ---

# spawn-test-agent.sh: must have deepcode elif + tmux send-keys deepcode
grep -Fq 'elif [[ "${AGENT_TDD_CLI}" == "deepcode" ]]; then' \
  "${RECIPES_DIR}/spawn-test-agent.sh" \
  && pass "spawn-test-agent.sh: has deepcode elif branch" \
  || fail "spawn-test-agent.sh: missing deepcode elif branch"

grep -Fq 'deepcode" Enter' \
  "${RECIPES_DIR}/spawn-test-agent.sh" \
  && pass "spawn-test-agent.sh: launches deepcode binary" \
  || fail "spawn-test-agent.sh: missing deepcode launch command"

# launch-impl-agent.sh: must have deepcode elif + deepcode binary call
grep -Fq 'elif [[ "${AGENT_TDD_CLI}" == "deepcode" ]]; then' \
  "${RECIPES_DIR}/launch-impl-agent.sh" \
  && pass "launch-impl-agent.sh: has deepcode elif branch" \
  || fail "launch-impl-agent.sh: missing deepcode elif branch"

# launch-impl-agent.sh: must deepcode binary call inside the branch
grep -A1 'deepcode.*then' "${RECIPES_DIR}/launch-impl-agent.sh" | tail -1 | grep -Fq 'deepcode' \
  && pass "launch-impl-agent.sh: calls deepcode binary" \
  || fail "launch-impl-agent.sh: missing deepcode binary call"

# launch-root.sh: must have deepcode elif + deepcode binary call
grep -Fq 'elif [[ "${AGENT_TDD_CLI}" == "deepcode" ]]; then' \
  "${PLAN_RECIPES_DIR}/launch-root.sh" \
  && pass "launch-root.sh: has deepcode elif branch" \
  || fail "launch-root.sh: missing deepcode elif branch"

# spawn-resume-window.sh: must have deepcode elif + /atdd resume slash
grep -Fq 'elif [[ "${AGENT_TDD_CLI}" == "deepcode" ]]; then' \
  "${COMPACT_RECIPES_DIR}/spawn-resume-window.sh" \
  && pass "spawn-resume-window.sh: has deepcode elif branch" \
  || fail "spawn-resume-window.sh: missing deepcode elif branch"

grep -Fq 'SLASH="/atdd resume ${ROOT_ID}"' \
  <(sed -n '/deepcode.*then/,/else/p' "${COMPACT_RECIPES_DIR}/spawn-resume-window.sh") \
  && pass "spawn-resume-window.sh: deepcode uses /atdd resume slash" \
  || fail "spawn-resume-window.sh: deepcode branch missing /atdd resume"

echo "== deepcode-support: SKILL.md documentation =="

# atdd/SKILL.md: invocation sentence mentions Deep Code
grep -Fq 'Deep Code invokes it as' \
  "${SKILLS_DIR}/atdd/SKILL.md" \
  && pass "atdd/SKILL.md: invocation sentence mentions Deep Code" \
  || fail "atdd/SKILL.md: invocation sentence missing Deep Code"

# atdd/SKILL.md: bootstrap step 0 mentions Deep Code settings.json
grep -Fq 'Deep Code sets' \
  "${SKILLS_DIR}/atdd/SKILL.md" \
  && pass "atdd/SKILL.md: bootstrap mentions Deep Code env setup" \
  || fail "atdd/SKILL.md: bootstrap missing Deep Code"

# atdd/SKILL.md: wave-watcher doc mentions Deep Code
grep -Fq 'Deep Code uses `run_in_background=true`' \
  "${SKILLS_DIR}/atdd/SKILL.md" \
  && pass "atdd/SKILL.md: wave-watcher doc mentions Deep Code" \
  || fail "atdd/SKILL.md: wave-watcher doc missing Deep Code"

echo "== deepcode-support: recipe comments mention deepcode =="

# Each recipe file's header comment should list deepcode as an alt CLI
for f in \
  "${RECIPES_DIR}/spawn-test-agent.sh" \
  "${RECIPES_DIR}/launch-impl-agent.sh" \
  "${PLAN_RECIPES_DIR}/launch-root.sh" \
  "${COMPACT_RECIPES_DIR}/spawn-resume-window.sh"
do
  grep -Fq 'deepcode' "$f" \
    && pass "$(basename "$f"): mentions deepcode in comments" \
    || fail "$(basename "$f"): missing deepcode in comments"
done

echo "== deepcode-support: index.js =="

grep -Fq 'deepcode' "${PLUGIN_ROOT}/index.js" \
  && pass "index.js: mentions deepcode as alt CLI value" \
  || fail "index.js: missing deepcode mention"

echo "== deepcode-support: per-CLI comment blocks mention deepcode =="

# Each recipe's per-CLI comment block should have a deepcode line
grep -Fq '# deepcode:' "${RECIPES_DIR}/spawn-test-agent.sh" \
  && pass "spawn-test-agent.sh: has # deepcode: comment" \
  || fail "spawn-test-agent.sh: missing # deepcode: comment"

grep -Fq '#   - deepcode:' "${RECIPES_DIR}/launch-impl-agent.sh" \
  && pass "launch-impl-agent.sh: has #   - deepcode: comment" \
  || fail "launch-impl-agent.sh: missing #   - deepcode: comment"

grep -Fq '#   - deepcode:' "${PLAN_RECIPES_DIR}/launch-root.sh" \
  && pass "launch-root.sh: has #   - deepcode: comment" \
  || fail "launch-root.sh: missing #   - deepcode: comment"

echo
if [[ "$TESTS_FAIL" -eq 0 ]]; then
  printf '\033[32mALL PASS\033[0m — %d checks\n' "$TESTS_RUN"
  exit 0
else
  printf '\033[31m%d/%d FAILED\033[0m\n' "$TESTS_FAIL" "$TESTS_RUN"
  exit 1
fi
