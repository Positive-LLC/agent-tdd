#!/usr/bin/env bash
# orchestrate-run-in-background.sh — verify ORCHESTRATE.md uses Bash(run_in_background=true)
# instead of sleep polling for watcher wait loops (§3.2 step 4a+4b) and prompt-ready
# poll (§4.1).
#
# Run:  bash skills/atdd-plan/recipes/tests/orchestrate-run-in-background.sh
# Exit: 0 = all green; 1 = ≥1 failure.

set -uo pipefail

THIS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$(cd -- "${THIS_DIR}/../../.." && pwd)"
ORCHESTRATE="${SKILLS_DIR}/atdd-plan/ORCHESTRATE.md"

TESTS_RUN=0; TESTS_FAIL=0
pass() { TESTS_RUN=$((TESTS_RUN+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() {
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1))
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '         %s\n' "$2"
}

[[ -f "$ORCHESTRATE" ]] || { echo "ORCHESTRATE.md not found at $ORCHESTRATE"; exit 1; }

# Extract the section between two regex markers (inclusive of the first line
# matching the start pattern).
extract_section() {
  local start="$1" end="$2"
  awk "/${start}/{p=1} p; /${end}/{exit}" "$ORCHESTRATE"
}

# ────────────────────────────────────────────────────────────────────────
echo "== §3.2 step 4a+4b: watcher wait loop uses run_in_background=true =="

WATCHER_SECTION="$(extract_section 'Step 4a' 'Step 5\|^5\.')"

# Positive: run_in_background=true must appear in the watcher section
if echo "$WATCHER_SECTION" | grep -q 'run_in_background=true'; then
  pass "§3.2 step 4: run_in_background=true present in watcher wait section"
else
  fail "§3.2 step 4: run_in_background=true present in watcher wait section" \
       "expected 'run_in_background=true' in §3.2 step 4a/4b; not found"
fi

# Negative: no sleep-based polling loop in the watcher section
# The old pattern was: for i in $(seq ...); do ... sleep 10; done
if echo "$WATCHER_SECTION" | grep -P 'for\s+\w+\s+in\s+\$\(\s*seq\b' | grep -q 'sleep'; then
  fail "§3.2 step 4: no sleep-based polling loop in watcher section" \
       "found 'for ... in \$(seq ...)' with 'sleep' — should use run_in_background=true"
else
  pass "§3.2 step 4: no sleep-based polling loop in watcher section"
fi

# Negative: the word "sleep" should not appear inside a code-fenced block
# in the watcher section (step 4b's old pattern)
if echo "$WATCHER_SECTION" | sed -n '/```bash/,/```/p' | grep -q '\bsleep\b'; then
  fail "§3.2 step 4: no sleep command inside watcher code block" \
       "found 'sleep' inside a bash code block in step 4 — should use run_in_background=true"
else
  pass "§3.2 step 4: no sleep command inside watcher code block"
fi

# ────────────────────────────────────────────────────────────────────────
echo "== §4.1: prompt-ready poll uses run_in_background=true =="

POLL_SECTION="$(extract_section 'poll for its prompt' 'tmux send-keys')"

# Positive: run_in_background=true must appear in the prompt section
if echo "$POLL_SECTION" | grep -q 'run_in_background=true'; then
  pass "§4.1: run_in_background=true present in prompt-ready poll section"
else
  fail "§4.1: run_in_background=true present in prompt-ready poll section" \
       "expected 'run_in_background=true' in §4.1; not found"
fi

# Negative: no sleep-based polling loop in the prompt section
# The old pattern was: for _ in $(seq 1 30); do ... sleep 1; done
if echo "$POLL_SECTION" | grep -P 'for\s+\w+\s+in\s+\$\(\s*seq\b' | grep -q 'sleep'; then
  fail "§4.1: no sleep-based polling loop in prompt-ready section" \
       "found 'for ... in \$(seq ...)' with 'sleep' — should use run_in_background=true"
else
  pass "§4.1: no sleep-based polling loop in prompt-ready section"
fi

# Negative: the word "sleep" should not appear inside a code-fenced block
# in the prompt section
if echo "$POLL_SECTION" | sed -n '/```bash/,/```/p' | grep -q '\bsleep\b'; then
  fail "§4.1: no sleep command inside prompt-ready code block" \
       "found 'sleep' inside a bash code block in §4.1 — should use run_in_background=true"
else
  pass "§4.1: no sleep command inside prompt-ready code block"
fi

# ────────────────────────────────────────────────────────────────────────
echo
if [[ "$TESTS_FAIL" -eq 0 ]]; then
  printf '\033[32mALL PASS\033[0m — %d assertions\n' "$TESTS_RUN"
  exit 0
else
  printf '\033[31m%d/%d FAILED\033[0m\n' "$TESTS_FAIL" "$TESTS_RUN"
  exit 1
fi
