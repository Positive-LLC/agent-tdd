#!/usr/bin/env bash
# run-in-background-regression.sh — regression gate for Positive-LLC/agent-tdd#12.
#
# Contract under test: PROTOCOL.md §3.2 step 9 and §6.1 must describe a single
# `Bash(run_in_background=true)` call that runs the watcher directly — not the
# two-step "nohup daemon + sleep-poll result file" pattern. The watcher scripts
# themselves are unchanged; only the protocol description changes.
#
# Hermetic: pure `grep` + `sed` over a checked-in file. No `atdd` binary, no
# daemon, no network. Locates the skills tree relative to THIS script, so the
# working directory does not matter.
#
# Run:  bash skills/atdd-plan/recipes/tests/run-in-background-regression.sh
# Exit: 0 = every behavior present (GREEN); 1 = at least one gap (RED).

set -uo pipefail

THIS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# tests/ -> recipes/ -> atdd-plan/ -> skills/
SKILLS_DIR="$(cd -- "${THIS_DIR}/../../.." && pwd)"
PROTOCOL="${SKILLS_DIR}/atdd/PROTOCOL.md"

TESTS_RUN=0
TESTS_FAIL=0
pass() { TESTS_RUN=$((TESTS_RUN+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() {
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1))
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '%s\n' "$2"
  return 0
}

if [[ ! -f "$PROTOCOL" ]]; then
  fail "PROTOCOL.md not found at $PROTOCOL"
  printf '\n\033[31m%d/%d FAILED\033[0m\n' "$TESTS_FAIL" "$TESTS_RUN"
  exit 1
fi

# Extract the two sections under test.
# §3.2 step 9: from "9. **Issue the background event-watcher**" up to (not including) "10. **Update"
SEC_3_2_STEP9="$(sed -n '/^9\. \*\*Issue the background event-watcher\*\*/,/^10\. \*\*Update your dashboard window name\*\*/{ /^10\. /!p; }' "$PROTOCOL")"

# §6.1: from "### 6.1 Agent → Root: status files + nohup daemon event-watcher" up to (not including) "### 6.2"
SEC_6_1="$(sed -n '/^### 6\.1 Agent → Root.*nohup daemon event-watcher/,/^### 6\.2 Root → Agent/{ /^### 6\.2/!p; }' "$PROTOCOL")"

echo "== run_in_background regression (issue #12): PROTOCOL.md §3.2 step 9 and §6.1 =="

# ── §3.2 step 9 assertions ──
SECTION="§3.2 step 9 (wave-watcher daemon+wait)"

# (A) New pattern present: must reference Bash(run_in_background=true)
if grep -qF 'run_in_background=true' <<<"$SEC_3_2_STEP9"; then
  pass "$SECTION: references run_in_background=true"
else
  fail "$SECTION: references run_in_background=true" \
    "  expected: Bash(run_in_background=true) call in §3.2 step 9"
fi

# (B) Old pattern absent: must NOT contain nohup
if grep -qF 'nohup' <<<"$SEC_3_2_STEP9"; then
  fail "$SECTION: no nohup daemon launch" \
    "  found 'nohup' in §3.2 step 9 — old two-step pattern still present"
else
  pass "$SECTION: no nohup daemon launch"
fi

# (C) Old pattern absent: must NOT contain the sleep-poll loop.
# grep -z enables multiline matching so we can catch the for/seq/sleep pattern
# spanning multiple lines.
if grep -qz 'for i in.*seq.*sleep' <<<"$SEC_3_2_STEP9"; then
  fail "$SECTION: no sleep-poll loop" \
    "  found 'for i in ... seq ... sleep' in §3.2 step 9 — old wait-loop still present"
else
  pass "$SECTION: no sleep-poll loop"
fi

# (D) Watcher script still referenced (unchanged)
if grep -qF 'wave-watcher.sh' <<<"$SEC_3_2_STEP9"; then
  pass "$SECTION: references wave-watcher.sh (watcher script unchanged)"
else
  fail "$SECTION: references wave-watcher.sh" \
    "  wave-watcher.sh must still be referenced — the watcher script is unchanged"
fi

# (E) New pattern: agent goes idle (zero tokens) until EVENT line
if grep -qF 'EVENT' <<<"$SEC_3_2_STEP9"; then
  pass "$SECTION: mentions EVENT line (watcher output contract)"
else
  fail "$SECTION: mentions EVENT line" \
    "  expected: description of EVENT= output from watcher"
fi

# ── §6.1 assertions ──
SECTION="§6.1 (Agent → Root: event-watcher)"

# (A) New pattern present
if grep -qF 'run_in_background=true' <<<"$SEC_6_1"; then
  pass "$SECTION: references run_in_background=true"
else
  fail "$SECTION: references run_in_background=true" \
    "  expected: Bash(run_in_background=true) call in §6.1"
fi

# (B) Old pattern absent: must NOT contain nohup
if grep -qF 'nohup' <<<"$SEC_6_1"; then
  fail "$SECTION: no nohup daemon launch" \
    "  found 'nohup' in §6.1 — old two-step pattern still present"
else
  pass "$SECTION: no nohup daemon launch"
fi

# (C) Old pattern absent: must NOT contain the sleep-poll loop.
# grep -z enables multiline matching so we can catch the for/seq/sleep pattern.
if grep -qz 'for i in.*seq.*sleep' <<<"$SEC_6_1"; then
  fail "$SECTION: no sleep-poll loop" \
    "  found 'for i in ... seq ... sleep' in §6.1 — old wait-loop still present"
else
  pass "$SECTION: no sleep-poll loop"
fi

# (D) Watcher script still referenced
if grep -qF 'wave-watcher.sh' <<<"$SEC_6_1"; then
  pass "$SECTION: references wave-watcher.sh (watcher script unchanged)"
else
  fail "$SECTION: references wave-watcher.sh" \
    "  wave-watcher.sh must still be referenced — the watcher script is unchanged"
fi

# (E) Design rationale updated: no longer claims "no host-CLI-specific features"
# The new design uses run_in_background which IS a host-CLI feature.
# The old text says "cross-platform, in-house (no host-CLI-specific features)" —
# after the change this justification should be removed or reworded.
if grep -qF 'no host-CLI-specific features' <<<"$SEC_3_2_STEP9"; then
  fail "§3.2 step 9: no longer claims 'no host-CLI-specific features'" \
    "  found 'no host-CLI-specific features' — the new pattern uses run_in_background=true which IS host-CLI-specific"
else
  pass "§3.2 step 9: no longer claims 'no host-CLI-specific features'"
fi

# (F) The §6.1 design rationale: must NOT claim "no run_in_background" (with or without backticks)
# since the new design explicitly uses it.
if grep -qE 'no [`]*run_in_background' <<<"$SEC_6_1"; then
  fail "§6.1: no longer claims 'no run_in_background'" \
    "  found 'no ... run_in_background' — the new design explicitly uses run_in_background=true"
else
  pass "§6.1: no longer claims 'no run_in_background'"
fi

if grep -qF 'no host-CLI-specific features' <<<"$SEC_6_1"; then
  fail "§6.1: no longer claims 'no host-CLI-specific features'" \
    "  found 'no host-CLI-specific features' in §6.1 — the new pattern uses run_in_background=true which IS host-CLI-specific"
else
  pass "§6.1: no longer claims 'no host-CLI-specific features'"
fi

# Summary
echo
if [[ "$TESTS_FAIL" -eq 0 ]]; then
  printf '\033[32mALL PASS\033[0m — %d assertions\n' "$TESTS_RUN"; exit 0
else
  printf '\033[31m%d/%d FAILED\033[0m\n' "$TESTS_FAIL" "$TESTS_RUN"; exit 1
fi
