#!/usr/bin/env bash
# watcher-test.sh — hermetic behavioral tests for the cross-platform nohup daemon
# wait mechanism (wave-watcher.sh + roots-watcher.sh).
#
# Pure shell — zero atdd/gh/repo dependencies. Runs in a temp dir, completes in
# under 10 seconds. Covers: backward-compat stdout mode, atomic result-file mode,
# timeout behavior, the agent-side wait loop, and roots-watcher signal polling.
#
# Run:  bash skills/atdd-plan/recipes/tests/watcher-test.sh
# Exit: 0 = all green; 1 = ≥1 failure.

set -uo pipefail

THIS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$(cd -- "${THIS_DIR}/../../.." && pwd)"
WAVE_WATCHER="${SKILLS_DIR}/atdd/recipes/wave-watcher.sh"
ROOTS_WATCHER="${SKILLS_DIR}/atdd-plan/recipes/roots-watcher.sh"

TESTS_RUN=0; TESTS_FAIL=0
pass() { TESTS_RUN=$((TESTS_RUN+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() {
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1))
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '         %s\n' "$2"
}

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# The watchers recover REPO_ROOT via --git-common-dir, so we need a real git
# repo with a first commit (empty repo has no HEAD → rev-parse fails).
git init -q "$WORK"
git -C "$WORK" config user.email t@example.com
git -C "$WORK" config user.name test
git -C "$WORK" commit --allow-empty -m init -q

# Run watcher with $WORK as cwd (so git-common-dir resolves to the temp repo).
# Timeout default 2 s; caller overrides via WAVE_WATCHER_TIMEOUT_SEC env.
_run_wave()  { ( cd "$WORK" && WAVE_WATCHER_TIMEOUT_SEC="${WAVE_WATCHER_TIMEOUT_SEC:-2}" bash "$WAVE_WATCHER" "$@" ); }
_run_roots() { ( cd "$WORK" && ROOTS_WATCHER_TIMEOUT_SEC="${ROOTS_WATCHER_TIMEOUT_SEC:-2}" bash "$ROOTS_WATCHER" "$@" ); }

STATUS_DIR="${WORK}/.atdd/root-1/wave-1/status"
mkdir -p "${STATUS_DIR}"
RESULT="${WORK}/watcher-result.txt"

# ══════════════════════════════════════════════════════════════════
echo "== wave-watcher: 3-arg stdout (backward compat) =="

# timeout
WAVE_WATCHER_TIMEOUT_SEC=1 OUT="$(_run_wave root-1 1 1 2>/dev/null)" RC=$?
[[ "$RC" -eq 0 ]] && pass "3-arg timeout exits 0" \
  || fail "3-arg timeout exits 0" "exit=${RC}"
grep -q 'EVENT=timeout' <<<"$OUT" \
  && pass "3-arg timeout stdout: EVENT=timeout" \
  || fail "3-arg timeout stdout: EVENT=timeout" "got=$OUT"

# terminal
touch "${STATUS_DIR}/issue-1.done"
WAVE_WATCHER_TIMEOUT_SEC=1 OUT="$(_run_wave root-1 1 1 2>/dev/null)" RC=$?
[[ "$RC" -eq 0 ]] && pass "3-arg terminal exits 0" || fail "3-arg terminal exits 0" "exit=${RC}"
grep -q 'EVENT=terminal' <<<"$OUT" \
  && pass "3-arg terminal stdout: EVENT=terminal" \
  || fail "3-arg terminal stdout: EVENT=terminal" "got=$OUT"
grep -q 'TERMINAL_COUNT=1' <<<"$OUT" \
  && pass "3-arg terminal stdout: TERMINAL_COUNT=1" \
  || fail "3-arg terminal stdout: TERMINAL_COUNT=1" "got=$OUT"

# paused beats terminal (expected=2, one .done + one .paused → terminal_count=1 < 2)
rm -f "${STATUS_DIR}/issue-1.done"
touch "${STATUS_DIR}/issue-1.paused" "${STATUS_DIR}/issue-2.done"
WAVE_WATCHER_TIMEOUT_SEC=1 OUT="$(_run_wave root-1 1 2 2>/dev/null)" RC=$?
grep -q 'EVENT=paused' <<<"$OUT" \
  && pass "3-arg: paused beats terminal (EVENT=paused)" \
  || fail "3-arg: paused beats terminal" "got=$OUT"

# .crashed / .aborted / .failed all count as terminal
rm -f "${STATUS_DIR}"/*
touch "${STATUS_DIR}/issue-3.crashed" "${STATUS_DIR}/issue-4.aborted" "${STATUS_DIR}/issue-5.failed"
WAVE_WATCHER_TIMEOUT_SEC=1 OUT="$(_run_wave root-1 1 3 2>/dev/null)" RC=$?
grep -q 'EVENT=terminal' <<<"$OUT" \
  && pass "3-arg: .crashed+.aborted+.failed count as terminal" \
  || fail "3-arg: .crashed+.aborted+.failed" "got=$OUT"

# ══════════════════════════════════════════════════════════════════
echo "== wave-watcher: 4-arg atomic result-file mode =="

# terminal → result file appears atomically, no .tmp left behind
rm -f "${STATUS_DIR}"/* "${RESULT}" "${RESULT}.tmp"
touch "${STATUS_DIR}/issue-1.done"
WAVE_WATCHER_TIMEOUT_SEC=1 _run_wave root-1 1 1 "${RESULT}" 2>/dev/null; RC=$?
[[ "$RC" -eq 0 ]] && pass "4-arg terminal exits 0" \
  || fail "4-arg terminal exits 0" "exit=${RC}"
[[ -f "${RESULT}" ]] && pass "4-arg terminal: result file exists" \
  || fail "4-arg terminal: result file exists" "missing ${RESULT}"
[[ ! -f "${RESULT}.tmp" ]] && pass "4-arg terminal: no stale .tmp after completion" \
  || fail "4-arg terminal: no stale .tmp" "${RESULT}.tmp still present"
grep -q 'EVENT=terminal' "${RESULT}" \
  && pass "4-arg terminal: result contains EVENT=terminal" \
  || fail "4-arg terminal: missing EVENT=terminal" "got=$(cat "${RESULT}")"

# timeout → result file with EVENT=timeout
rm -f "${STATUS_DIR}"/* "${RESULT}" "${RESULT}.tmp"
WAVE_WATCHER_TIMEOUT_SEC=1 _run_wave root-1 1 1 "${RESULT}" 2>/dev/null
[[ -f "${RESULT}" ]] && pass "4-arg timeout: result file exists" \
  || fail "4-arg timeout: result file exists" "missing"
grep -q 'EVENT=timeout' "${RESULT}" \
  && pass "4-arg timeout: result contains EVENT=timeout" \
  || fail "4-arg timeout: EVENT=timeout" "got=$(cat "${RESULT}")"
grep -q 'TIMEOUT_SEC=' "${RESULT}" \
  && pass "4-arg timeout: TIMEOUT_SEC in result" \
  || fail "4-arg timeout: TIMEOUT_SEC" "got=$(cat "${RESULT}")"

# paused in 4-arg form
rm -f "${STATUS_DIR}"/* "${RESULT}" "${RESULT}.tmp"
touch "${STATUS_DIR}/issue-1.paused"
WAVE_WATCHER_TIMEOUT_SEC=1 _run_wave root-1 1 1 "${RESULT}" 2>/dev/null
grep -q 'EVENT=paused' "${RESULT}" \
  && pass "4-arg paused: result contains EVENT=paused" \
  || fail "4-arg paused: EVENT=paused" "got=$(cat "${RESULT}")"
grep -q 'FILE=' "${RESULT}" \
  && pass "4-arg paused: FILE= line present" \
  || fail "4-arg paused: FILE= line" "got=$(cat "${RESULT}")"

# ══════════════════════════════════════════════════════════════════
echo "== cross-platform agent wait loop (foreground Bash pattern) =="

# Test 1: result file already on disk → loop returns immediately.
rm -f "${STATUS_DIR}"/* "${RESULT}" "${RESULT}.tmp"
echo "EVENT=terminal" > "${RESULT}"
echo "TERMINAL_COUNT=3" >> "${RESULT}"
FOUND=0
for i in $(seq 1 3); do
  if [ -s "${RESULT}" ]; then FOUND=1; break; fi
  sleep 1
done
[[ "$FOUND" -eq 1 ]] \
  && pass "wait-loop: returns immediately when result file already on disk" \
  || fail "wait-loop: should return immediately"

# Test 2: no result file → loop exhausts budget → NOT_READY.
rm -f "${RESULT}" "${RESULT}.tmp"
NOT_READY=1
for i in $(seq 1 5); do
  if [ -s "${RESULT}" ]; then NOT_READY=0; break; fi
  sleep 1
done
[[ "$NOT_READY" -eq 1 ]] \
  && pass "wait-loop: NOT_READY after budget exhausted with no result file" \
  || fail "wait-loop: should be NOT_READY"

# Test 3: daemon (fg, 4-arg) produces result → wait finds it.
rm -f "${STATUS_DIR}"/* "${RESULT}" "${RESULT}.tmp"
touch "${STATUS_DIR}/issue-1.done"
( export WAVE_WATCHER_TIMEOUT_SEC=3; cd "$WORK" && exec bash "$WAVE_WATCHER" root-1 1 1 "$RESULT" ) &
DAEMON_PID=$!
wait "$DAEMON_PID"
[[ -f "${RESULT}" ]] \
  && pass "wait-loop: foreground daemon produced result file" \
  || fail "wait-loop: no result file after daemon (PID=$DAEMON_PID)"
grep -q 'EVENT=terminal' "${RESULT}" \
  && pass "wait-loop: result contains EVENT=terminal" \
  || fail "wait-loop: unexpected result" "got=$(cat "${RESULT}" 2>/dev/null)"

# ══════════════════════════════════════════════════════════════════
echo "== roots-watcher: 1-arg stdout (backward compat) =="

COHORT_DIR="${WORK}/cohort-test"
mkdir -p "${COHORT_DIR}/member-a"
COHORT_JSON="${COHORT_DIR}/cohort.json"
SIGNAL_A="${COHORT_DIR}/member-a/root-signal.json"

cat > "${SIGNAL_A}" <<'SIGEOF'
{"notes_id":"notes-1","sub_ref":"acme/repo#1","state":"running","seq":1,"heartbeat_ts":"2026-01-01T00:00:00Z"}
SIGEOF

cat > "${COHORT_JSON}" <<JSONEOF
{
  "rootissue": "acme/home#99",
  "notes_id": "notes-1",
  "members": {
    "acme/repo#1": {
      "sub_slug": "repo-1",
      "repo": "acme/repo",
      "repo_path": "/nonexistent",
      "signal_path": "COHORT_DIR_PLACEHOLDER/member-a/root-signal.json",
      "ws_session": "ws-notes-1",
      "window": "session:root-repo-1",
      "window_id": "@2",
      "state": "running",
      "last_consumed_seq": 1
    }
  }
}
JSONEOF
sed -i "s|COHORT_DIR_PLACEHOLDER|${COHORT_DIR}|g" "${COHORT_JSON}"

# No signal advance → timeout
ROOTS_WATCHER_TIMEOUT_SEC=1 OUT="$(_run_roots "${COHORT_JSON}" 2>/dev/null)" RC=$?
grep -q 'EVENT=timeout' <<<"$OUT" \
  && pass "roots-watcher 1-arg: EVENT=timeout on stdout (no signal advance)" \
  || fail "roots-watcher 1-arg: EVENT=timeout" "got=$OUT"

# Settled → cohort-ready
jq '.state="awaiting-merge-confirm" | .seq=2 | .heartbeat_ts="2026-01-01T00:01:00Z"' \
  "${SIGNAL_A}" > "${SIGNAL_A}.tmp" && mv "${SIGNAL_A}.tmp" "${SIGNAL_A}"
jq --arg s "acme/repo#1" --argjson n 2 '.members[$s].last_consumed_seq=$n' "${COHORT_JSON}" > "${COHORT_JSON}.tmp" && mv "${COHORT_JSON}.tmp" "${COHORT_JSON}"
ROOTS_WATCHER_TIMEOUT_SEC=1 OUT="$(_run_roots "${COHORT_JSON}" 2>/dev/null)" RC=$?
grep -q 'EVENT=cohort-ready' <<<"$OUT" \
  && pass "roots-watcher 1-arg: cohort-ready when all settled" \
  || fail "roots-watcher 1-arg: cohort-ready" "got=$OUT"

# ══════════════════════════════════════════════════════════════════
echo "== roots-watcher: 2-arg atomic result-file mode =="

rm -f "${RESULT}" "${RESULT}.tmp"
jq '.state="running" | .seq=3 | .heartbeat_ts="2026-01-01T00:02:00Z"' \
  "${SIGNAL_A}" > "${SIGNAL_A}.tmp" && mv "${SIGNAL_A}.tmp" "${SIGNAL_A}"
jq --arg s "acme/repo#1" --argjson n 3 '.members[$s].last_consumed_seq=$n' "${COHORT_JSON}" > "${COHORT_JSON}.tmp" && mv "${COHORT_JSON}.tmp" "${COHORT_JSON}"

ROOTS_WATCHER_TIMEOUT_SEC=1 _run_roots "${COHORT_JSON}" "${RESULT}" 2>/dev/null
[[ -f "${RESULT}" ]] && pass "roots-watcher 2-arg: result file exists" \
  || fail "roots-watcher 2-arg: result file missing"
[[ ! -f "${RESULT}.tmp" ]] && pass "roots-watcher 2-arg: no stale .tmp" \
  || fail "roots-watcher 2-arg: stale .tmp"
grep -q 'EVENT=timeout' "${RESULT}" \
  && pass "roots-watcher 2-arg: result contains EVENT=timeout" \
  || fail "roots-watcher 2-arg: missing EVENT=timeout" "got=$(cat "${RESULT}")"

# ══════════════════════════════════════════════════════════════════
echo "== edge cases =="

# Pre-existing result file overwritten atomically
rm -f "${STATUS_DIR}"/* "${RESULT}" "${RESULT}.tmp"
echo "stale data" > "${RESULT}"
touch "${STATUS_DIR}/issue-1.done"
WAVE_WATCHER_TIMEOUT_SEC=1 _run_wave root-1 1 1 "${RESULT}" 2>/dev/null
grep -q 'EVENT=terminal' "${RESULT}" \
  && pass "edge: pre-existing result file overwritten with fresh event" \
  || fail "edge: pre-existing result file" "got=$(cat "${RESULT}")"

# 3-arg form does not create result file
rm -f "${STATUS_DIR}"/* "${RESULT}" "${RESULT}.tmp"
touch "${STATUS_DIR}/issue-1.done"
WAVE_WATCHER_TIMEOUT_SEC=1 _run_wave root-1 1 1 2>/dev/null || true
[[ ! -f "${RESULT}" ]] && pass "edge: 3-arg form does not create result file" \
  || fail "edge: 3-arg created result file unexpectedly"

# ------------------------------------------------------------------
echo
if [[ "$TESTS_FAIL" -eq 0 ]]; then
  printf '\033[32mALL PASS\033[0m — %d assertions\n' "$TESTS_RUN"
  exit 0
else
  printf '\033[31m%d/%d FAILED\033[0m\n' "$TESTS_FAIL" "$TESTS_RUN"
  exit 1
fi
