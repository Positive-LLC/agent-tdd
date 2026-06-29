#!/usr/bin/env bash
# stack-preflight.sh — the MANDATORY-LSP gate for the atdd Stack (atdd-cli #32/#33).
#
# Wraps the advisory `lsp-surface.sh`: it runs it, re-emits its JSON, and then
# BLOCKS (exit 3) if any symbol-precise language this repo uses has NO working
# LSP. Rationale: `atdd stack verify` refuses to trust a #symbol anchor without a
# registered LSP (it reports `blocked`, never a silent "verified"), so a wave must
# not start Stack work on a symbol-precise repo until the LSP is provisioned.
#
# shell / markdown / config have no symbol LSP — lsp-surface.sh does not detect
# them, so they are never in `missing` and never gated (the plugin stays usable on
# shell+markdown repos, including agent-tdd itself).
#
# lsp-surface.sh stays ADVISORY and unchanged — this gate is the policy layer on
# top, so the gate logic itself lives in exactly one place.
#
# Usage / args: identical to lsp-surface.sh — `stack-preflight.sh [--repo <owner/repo>] [--path <dir>]`.
# stdout: the lsp-surface.sh JSON report (so the caller still gets repo/missing/…).
# exit:   0 = no symbol-precise gap (proceed) · 3 = BLOCKED (provision the LSP first)
#         · 2 = hard error from lsp-surface.sh (bad args / no jq / no git), propagated.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SURFACE="$HERE/lsp-surface.sh"
[[ -x "$SURFACE" ]] || { printf '[stack-preflight] ERROR: not found/executable: %s\n' "$SURFACE" >&2; exit 2; }

# Run the advisory surfacer. Its JSON → stdout (captured); its human summary → stderr (flows through).
REPORT="$("$SURFACE" "$@")"; rc=$?
if [[ $rc -ne 0 ]]; then
  # lsp-surface.sh hit a hard error (bad args / no jq / no git) — propagate as-is.
  exit "$rc"
fi

printf '%s\n' "$REPORT"   # re-emit the report so the caller still gets repo/repo_registered/missing/…

nmiss="$(jq -r '.missing | length' <<<"$REPORT" 2>/dev/null || echo 0)"
if [[ "${nmiss:-0}" -gt 0 ]]; then
  missing="$(jq -r '.missing | join(", ")' <<<"$REPORT")"
  repo="$(jq -r '.repo' <<<"$REPORT")"
  registered="$(jq -r '.repo_registered' <<<"$REPORT")"
  {
    echo "[stack-preflight] ───── LSP GATE: BLOCKED ──────────────────────────────────"
    echo "[stack-preflight] symbol-precise language(s) with NO working LSP: ${missing}"
    echo "[stack-preflight] LSP is MANDATORY for these (atdd #32): \`stack verify\` reports a"
    echo "[stack-preflight] #symbol anchor as 'blocked' (never 'verified') without one. Provision"
    echo "[stack-preflight] before any Stack work, then re-run this preflight until it passes:"
    [[ "$registered" == "false" ]] && \
    echo "[stack-preflight]   1) atdd repo register ${repo} <abs-repo-path>   (repo not registered yet)"
    echo "[stack-preflight]   2) ask the human which server to install → install it → then:"
    echo "[stack-preflight]      atdd lsp register --repo ${repo} --lang <lang> --bin <path>"
    echo "[stack-preflight] (shell/markdown/config are never gated — only symbol-precise languages.)"
    echo "[stack-preflight] ──────────────────────────────────────────────────────────────"
  } >&2
  exit 3
fi

echo "[stack-preflight] LSP gate OK — every detected symbol-precise language has a working LSP." >&2
exit 0
