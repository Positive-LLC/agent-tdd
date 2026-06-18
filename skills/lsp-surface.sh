#!/usr/bin/env bash
# lsp-surface.sh — surface any language used in this repo that lacks a working
# LSP in the atdd stack registry. ADVISORY: a coverage gap never fails (exit 0).
#
# Both the Root Agent (skills/atdd/SKILL.md) and the Notes Agent
# (skills/atdd-plan/CORE.md) run this at bootstrap, right after ensure-atdd.sh.
# It is the DETERMINISTIC half of "bootstrap LSP surfacing" (Phase C):
#   1. detect the symbol-precise languages used in the repo (manifests + files),
#   2. cross-check `atdd lsp list` (status=="ok" == a working binary),
#   3. emit the gap as JSON on stdout; a human-readable summary on stderr.
# The AGENT does the rest (ask the human, install, `atdd lsp register`).
#
# Usage:
#   lsp-surface.sh [--repo <owner/repo>] [--path <dir>]
#     --repo  atdd repo slug to scope the registry to. Default: derived from the
#             git origin (github), else the nearest .atdd/manifest.json home_repo.
#     --path  repo working tree to scan. Default: the git toplevel of cwd.
#
# stdout: {"repo":<slug|null>,"path":<dir>,"detected":[..],"covered":[..],"missing":[..]}
# exit:   0 always (advisory). Hard errors (bad args / no git / no jq) exit 2.
set -euo pipefail

log() { printf '[lsp-surface] %s\n' "$*" >&2; }
die() { printf '[lsp-surface] ERROR: %s\n' "$*" >&2; exit 2; }

command -v jq  >/dev/null 2>&1 || die "jq not found on PATH"
command -v git >/dev/null 2>&1 || die "git not found on PATH"

REPO_SLUG=""; SCAN_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO_SLUG="${2:-}"; shift 2 ;;
    --path) SCAN_DIR="${2:-}"; shift 2 ;;
    *) die "unknown arg: $1 (usage: lsp-surface.sh [--repo owner/repo] [--path dir])" ;;
  esac
done

# scan dir = explicit --path, else the git toplevel of cwd
if [[ -z "$SCAN_DIR" ]]; then
  SCAN_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die "not inside a git repo and no --path given"
fi
[[ -d "$SCAN_DIR" ]] || die "scan path does not exist: $SCAN_DIR"

# derive the repo slug if not given: git origin (github) -> manifest home_repo
origin_nwo() {
  local url; url="$(git -C "$SCAN_DIR" remote get-url origin 2>/dev/null)" || return 1
  url="${url%.git}"
  case "$url" in
    *github.com:*) printf '%s\n' "${url##*github.com:}" ;;
    *github.com/*) printf '%s\n' "${url##*github.com/}" ;;
    *) return 1 ;;
  esac
}
[[ -n "$REPO_SLUG" ]] || REPO_SLUG="$(origin_nwo || true)"
if [[ -z "$REPO_SLUG" && -f "${SCAN_DIR}/.atdd/manifest.json" ]]; then
  REPO_SLUG="$(jq -r '.home_repo // empty' "${SCAN_DIR}/.atdd/manifest.json" 2>/dev/null || true)"
fi

# detect symbol-precise languages: a manifest-file signal OR a source-extension
# signal. Shell/markdown are intentionally absent (file-granularity downgrade).
_has_file() { [[ -e "${SCAN_DIR}/$1" ]]; }
_has_ext()  { find "$SCAN_DIR" -path "${SCAN_DIR}/.git" -prune -o -type f -name "$1" -print -quit 2>/dev/null | grep -q .; }
detect_langs() {
  local found=()
  if _has_file Cargo.toml      || _has_ext '*.rs';                 then found+=(rust); fi
  if _has_file pyproject.toml  || _has_file setup.py || _has_ext '*.py'; then found+=(python); fi
  if _has_file tsconfig.json   || _has_ext '*.ts'    || _has_ext '*.tsx'; then found+=(typescript); fi
  if _has_file package.json    || _has_ext '*.js'    || _has_ext '*.jsx'; then found+=(javascript); fi
  if _has_file go.mod          || _has_ext '*.go';                 then found+=(go); fi
  printf '%s\n' "${found[@]:-}"
}
mapfile -t DETECTED < <(detect_langs | sed '/^$/d' | sort -u)

# covered langs = status=="ok" registry rows for this repo (empty if list fails)
COVERED_JSON='[]'
if [[ -n "$REPO_SLUG" ]]; then
  if LIST="$(atdd lsp list --repo "$REPO_SLUG" 2>/dev/null)"; then
    COVERED_JSON="$(jq -c '[.lsps[]? | select(.status=="ok") | .lang]' <<<"$LIST" 2>/dev/null || echo '[]')"
  else
    log "could not list lsps for ${REPO_SLUG} (repo not registered to the project yet?) — treating all detected langs as uncovered"
  fi
else
  log "repo slug unknown (no github origin, no manifest home_repo) — registry not scoped; treating all detected langs as uncovered"
fi

# missing = detected - covered; emit the report
DETECTED_JSON="$(printf '%s\n' "${DETECTED[@]:-}" | sed '/^$/d' | jq -R . | jq -sc .)"
REPORT="$(jq -nc \
  --argjson detected "$DETECTED_JSON" \
  --argjson covered  "$COVERED_JSON" \
  --arg     repo     "${REPO_SLUG:-}" \
  --arg     path     "$SCAN_DIR" '
  ($detected - $covered) as $missing
  | { repo: ($repo | if . == "" then null else . end),
      path: $path, detected: $detected, covered: $covered, missing: $missing }')"
printf '%s\n' "$REPORT"

# human summary on stderr; advisory exit 0 regardless of the gap
if [[ "$(jq -r '.missing | length' <<<"$REPORT")" -gt 0 ]]; then
  log "MISSING LSP for: $(jq -r '.missing | join(", ")' <<<"$REPORT") (repo ${REPO_SLUG:-<unknown>})"
  log "advisory only — provisioning is the agent's job: ask the human -> install -> atdd lsp register"
else
  log "all detected languages have a working LSP (or no symbol-precise language detected)"
fi
exit 0
