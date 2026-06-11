# _ensure-version.sh — fast per-command guard: keep the on-disk `atdd` CLI in
# lockstep with this plugin's pinned version (skills/VERSION). Sourced by
# _project-env.sh, so it runs before any recipe shells out to `atdd`.
#
# On mismatch it self-heals: run ensure-atdd.sh (downloads + checksum-verifies the
# pinned version, installs to ~/.local/bin), then bounce the daemon so the next
# `atdd` call autostarts the new-version one (replacing the on-disk binary does
# NOT upgrade the already-running daemon).
#
# Cheap: runs once per process (ATDD_VERSION_CHECKED sentinel); the happy path is a
# single `atdd --version` string compare — no network. Opt out with
# ATDD_SKIP_VERSION_CHECK=1 (the recipe test harness sets this so tests never hit
# the network).
#
# Sourced under the caller's `set -euo pipefail`, so every line must be -e-safe:
# all failures are swallowed; a check that cannot run must never break a recipe.

if [[ -z "${ATDD_VERSION_CHECKED:-}" && -z "${ATDD_SKIP_VERSION_CHECK:-}" ]]; then
  export ATDD_VERSION_CHECKED=1
  # skills/ dir = two levels up from this recipes/ file (recipes -> atdd-plan -> skills).
  __atdd_skills="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd || true)"
  __atdd_want="$(tr -d '[:space:]' < "${__atdd_skills}/VERSION" 2>/dev/null || true)"
  if [[ -n "${__atdd_want}" ]] && command -v atdd >/dev/null 2>&1; then
    __atdd_cur="$(atdd --version 2>/dev/null | awk '{print $NF}')" || __atdd_cur=""
    if [[ -n "${__atdd_cur}" && "${__atdd_cur}" != "${__atdd_want}" ]]; then
      printf '[atdd] CLI %s != plugin %s — syncing…\n' "${__atdd_cur}" "${__atdd_want}" >&2
      bash "${__atdd_skills}/ensure-atdd.sh" || true   # installs ${__atdd_want}
      atdd daemon stop >/dev/null 2>&1 || true          # drop stale daemon; next call autostarts the new one
    fi
  fi
  unset __atdd_skills __atdd_want __atdd_cur
fi
