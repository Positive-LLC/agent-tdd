# lib.sh — tiny test harness for the atdd-plan recipes. Sourced by run.sh.
# No framework: a temp git repo + manifest, a mock `gh` on PATH, and grep-based
# assertions against the recorded gh call log.

TESTS_RUN=0
TESTS_FAIL=0
THIS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RECIPES_DIR="$(cd -- "${THIS_DIR}/.." && pwd)"
MOCK_BIN="${THIS_DIR}/bin"

pass() { TESTS_RUN=$((TESTS_RUN+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() {
  TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAIL=$((TESTS_FAIL+1))
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '         %s\n' "$2"
}

# Create a throwaway git repo with a standard manifest; mock gh on PATH.
setup_repo() {
  WORK="$(mktemp -d)"
  GH_LOG="${WORK}/gh.log"; : > "$GH_LOG"
  MOCK_FIXTURES="${WORK}/fixtures"; mkdir -p "$MOCK_FIXTURES"
  unset MOCK_FAIL_GLOB
  export GH_LOG MOCK_FIXTURES
  git -C "$WORK" init -q
  git -C "$WORK" config user.email t@example.com
  git -C "$WORK" config user.name test
  mkdir -p "${WORK}/.agent-tdd"
  cat > "${WORK}/.agent-tdd/manifest.json" <<'JSON'
{
  "project": { "url": "https://github.com/orgs/acme/projects/7", "number": 7, "id": "PVT_x", "title": "ACME", "owner": "acme" },
  "home_repo": "acme/home",
  "notebook_issue": { "url": "https://github.com/acme/home/issues/1", "number": 1 },
  "labels": { "notebook": "atdd:notebook", "root": "atdd:root", "sub": "atdd:sub", "ready": "atdd:ready" }
}
JSON
  export PATH="${MOCK_BIN}:${PATH}"
}
teardown_repo() { [[ -n "${WORK:-}" ]] && rm -rf "$WORK"; }
reset_mock() { : > "$GH_LOG"; rm -f "${MOCK_FIXTURES:?}"/*; }

# fixture <METHOD> <endpoint>     (JSON body on stdin)  -> canned response
fixture()      { cat > "${MOCK_FIXTURES}/$(printf '%s__%s' "$1" "$2" | tr '/:?&=' '_____').json"; }
# fixture_fail <METHOD> <endpoint>                      -> that call exits 1
fixture_fail() { : > "${MOCK_FIXTURES}/$(printf '%s__%s' "$1" "$2" | tr '/:?&=' '_____').fail"; }

# run <recipe.sh> [args...]   — runs inside the repo; sets RC and OUT.
# Honors STDIN_DATA (piped to the recipe) if set.
RC=0; OUT=""
run() {
  local recipe="$1"; shift
  if [[ -n "${STDIN_DATA:-}" ]]; then
    OUT="$( cd "$WORK" && printf '%s' "$STDIN_DATA" | "${RECIPES_DIR}/${recipe}" "$@" 2>"${WORK}/err" )" && RC=0 || RC=$?
  else
    OUT="$( cd "$WORK" && "${RECIPES_DIR}/${recipe}" "$@" 2>"${WORK}/err" )" && RC=0 || RC=$?
  fi
}

assert_ok()        { [[ "$RC" -eq 0 ]] && pass "$1" || fail "$1" "expected exit 0, got ${RC}: $(cat "${WORK}/err" 2>/dev/null | tail -1)"; }
assert_fail()      { [[ "$RC" -ne 0 ]] && pass "$1" || fail "$1" "expected nonzero exit, got 0"; }
assert_out()       { [[ "$OUT" == "$2" ]] && pass "$1" || fail "$1" "stdout='${OUT}' expected='$2'"; }
assert_called()    { grep -qF -- "$2" "$GH_LOG" && pass "$1" || fail "$1" "gh log missing: $2"; }
assert_not_called(){ ! grep -qF -- "$2" "$GH_LOG" && pass "$1" || fail "$1" "gh log unexpectedly contains: $2"; }

summary() {
  echo
  if [[ "$TESTS_FAIL" -eq 0 ]]; then
    printf '\033[32mALL PASS\033[0m — %d assertions\n' "$TESTS_RUN"; return 0
  else
    printf '\033[31m%d/%d FAILED\033[0m\n' "$TESTS_FAIL" "$TESTS_RUN"; return 1
  fi
}
