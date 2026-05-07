#!/usr/bin/env bash
# archive-old-window.sh — rename the current Root's tmux window to mark it
# inert after a successful compact handoff.
#
# Usage:  archive-old-window.sh <root-id>
#
# Reads root_tmux_window_id from meta.json (the same stable @-id used
# everywhere else for window targeting — see PROTOCOL.md §2.1 for why we
# never target by <session>:<name>). Renames the window from whatever its
# current name is (e.g. "root-3: wave-2 (3 active)") to
# "[ARCHIVED] <prior-name>" and applies a dim status style.
#
# This is the LAST step of /atdd-compact. After this runs, the current agent
# process is still alive but no longer the live workflow driver — the new
# resume window is.
#
# Idempotent: re-running adds another "[ARCHIVED]" prefix only if the
# current name doesn't already start with "[ARCHIVED]".

set -uo pipefail

log() { printf '[archive-old-window] %s\n' "$*" >&2; }
die() { printf '[archive-old-window] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 1 ]] || die "usage: $0 <root-id>"
ROOT_ID="$1"
[[ "$ROOT_ID" =~ ^root-[a-z0-9-]+$ ]] || die "bad root-id: ${ROOT_ID}"

command -v tmux >/dev/null 2>&1 || die "tmux not found on PATH"
command -v jq   >/dev/null 2>&1 || die "jq not found on PATH"

REPO_ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)" \
  || die "not inside a git repo"
META="${REPO_ROOT}/.agent-tdd/${ROOT_ID}/meta.json"
[[ -f "$META" ]] || die "meta.json not found at ${META}"

WINDOW_ID="$(jq -r '.root_tmux_window_id // empty' "$META")"
[[ -n "$WINDOW_ID" ]] || die "root_tmux_window_id not set in ${META}"

# Read current window name (whatever Root last renamed it to during status updates)
PRIOR_NAME="$(tmux display-message -p -t "${WINDOW_ID}" '#W' 2>/dev/null || true)"
[[ -n "$PRIOR_NAME" ]] || die "could not read window name for ${WINDOW_ID} — was the window killed?"

if [[ "$PRIOR_NAME" == \[ARCHIVED\]* ]]; then
  log "window ${WINDOW_ID} already archived (name='${PRIOR_NAME}'); no-op"
  exit 0
fi

NEW_NAME="[ARCHIVED] ${PRIOR_NAME}"
log "renaming ${WINDOW_ID}: '${PRIOR_NAME}' → '${NEW_NAME}'"
tmux rename-window -t "${WINDOW_ID}" "${NEW_NAME}" \
  || die "tmux rename-window failed"

# Dim style so the archived window visually recedes in the status bar.
# bg=brightblack,fg=white reads as a faded grey on most themes.
tmux set-window-option -t "${WINDOW_ID}" window-status-style 'bg=brightblack,fg=white' 2>/dev/null \
  || log "warning: could not set window-status-style (continuing)"

log "archived ${WINDOW_ID}"
exit 0
