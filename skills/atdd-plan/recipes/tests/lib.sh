# lib.sh — test harness for the atdd-plan recipes (Phase 1: atdd-backed).
# No framework: a temp git repo + manifest, an isolated atdd store (ATDD_HOME),
# the built `atdd` binary + a poison `gh` on PATH, and assertions against the
# store via `atdd`. A planning recipe that still shells out to `gh` hits the
# poison and fails — so this harness doubles as the recipe-level no-gh guard.

ORIG_PATH="$PATH"
TESTS_RUN=0
TESTS_FAIL=0
THIS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RECIPES_DIR="$(cd -- "${THIS_DIR}/.." && pwd)"
# atdd binary: env override, else the sibling atdd-cli repo's debug build.
ATDD_BIN="${ATDD_BIN:-$(cd -- "${THIS_DIR}/../../../../.." && pwd)/atdd-cli/target/debug/atdd}"
# The recipes' per-command version guard (_ensure-version.sh) would try to
# network-heal a locally built binary whose version differs from skills/VERSION.
# Tests use the binary as-is and must never hit the network — opt out.
export ATDD_SKIP_VERSION_CHECK=1

pass() { TESTS_RUN=$((TESTS_RUN+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() {
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1))
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '         %s\n' "$2"
}

setup_repo() {
  [[ -x "$ATDD_BIN" ]] || { echo "atdd binary not found/executable: $ATDD_BIN (build atdd-cli first)"; exit 1; }
  WORK="$(mktemp -d)"
  export ATDD_HOME="${WORK}/atdd-home"
  BIN="${WORK}/bin"; mkdir -p "$BIN"
  ln -sf "$ATDD_BIN" "${BIN}/atdd"
  export GH_POISON_LOG="${WORK}/gh-poison.log"; : > "$GH_POISON_LOG"
  cat > "${BIN}/gh" <<'POISON'
#!/usr/bin/env bash
printf 'POISON: gh called in inner flow: %s\n' "$*" >> "${GH_POISON_LOG:-/dev/stderr}"
exit 1
POISON
  chmod +x "${BIN}/gh"
  export PATH="${BIN}:${ORIG_PATH}"
  git -C "$WORK" init -q
  git -C "$WORK" config user.email t@example.com
  git -C "$WORK" config user.name test
  mkdir -p "${WORK}/.atdd"
  ( cd "$WORK" && "${RECIPES_DIR}/manifest-ensure.sh" acme/home >/dev/null ) \
    || { echo "FATAL: manifest bootstrap failed"; exit 1; }
}
teardown_repo() {
  "$ATDD_BIN" daemon stop >/dev/null 2>&1 || true
  export PATH="$ORIG_PATH"
  [[ -n "${WORK:-}" ]] && rm -rf "$WORK"
}

# run <recipe.sh> [args...] — runs inside the repo; sets RC and OUT. Honors STDIN_DATA.
RC=0; OUT=""
run() {
  local recipe="$1"; shift
  if [[ -n "${STDIN_DATA:-}" ]]; then
    OUT="$( cd "$WORK" && printf '%s' "$STDIN_DATA" | "${RECIPES_DIR}/${recipe}" "$@" 2>"${WORK}/err" )" && RC=0 || RC=$?
  else
    OUT="$( cd "$WORK" && "${RECIPES_DIR}/${recipe}" "$@" 2>"${WORK}/err" )" && RC=0 || RC=$?
  fi
}
# atdd <args> — run the CLI directly (for seeding + assertions), inside the repo.
atdd() { ( cd "$WORK" && "$ATDD_BIN" "$@" ); }

assert_ok()   { [[ "$RC" -eq 0 ]] && pass "$1" || fail "$1" "expected exit 0, got ${RC}: $(tail -1 "${WORK}/err" 2>/dev/null)"; }
assert_fail() { [[ "$RC" -ne 0 ]] && pass "$1" || fail "$1" "expected nonzero exit, got 0"; }
assert_rc()   { [[ "$RC" -eq "$2" ]] && pass "$1" || fail "$1" "expected exit $2, got ${RC}"; }
assert_out()  { [[ "$OUT" == "$2" ]] && pass "$1" || fail "$1" "stdout='${OUT}' expected='$2'"; }
# jchk <desc> <jq-filter> <json>
jchk() { if jq -e "$2" >/dev/null 2>&1 <<<"$3"; then pass "$1"; else fail "$1" "json=$3"; fi; }
gh_clean() { if [[ ! -s "$GH_POISON_LOG" ]]; then pass "no gh in the inner flow"; else fail "gh leaked" "$(cat "$GH_POISON_LOG")"; fi; }

summary() {
  echo
  if [[ "$TESTS_FAIL" -eq 0 ]]; then
    printf '\033[32mALL PASS\033[0m — %d assertions\n' "$TESTS_RUN"; return 0
  else
    printf '\033[31m%d/%d FAILED\033[0m\n' "$TESTS_FAIL" "$TESTS_RUN"; return 1
  fi
}
