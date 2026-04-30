#!/usr/bin/env bash
# notify-human.sh — surface a message to the human via tmux + OS notification.
#
# Usage:  notify-human.sh <message> [<root-id>] [<style>]
#
#   <message>   — short message (one line)
#   <root-id>   — optional; if provided, renames the dashboard window
#                 to include the message. The session is read from
#                 meta.json:root_tmux_session (captured at init-root time).
#   <style>     — optional; one of "info" (default) or "urgent". Urgent applies
#                 a red window style.
#
# Effects:
#   - tmux display-message in the dashboard session (transient banner).
#   - tmux rename-window if <root-id> provided.
#   - OS-level notification via notify-send (Linux) or osascript (macOS).
#
# Never injects keystrokes — only manipulates window metadata.

set -uo pipefail

[[ $# -ge 1 ]] || { echo "usage: $0 <message> [<root-id>] [<style>]" >&2; exit 1; }
MSG="$1"
ROOT_ID="${2:-}"
STYLE="${3:-info}"

# Resolve the dashboard session for this Root. We never assume `roots`; the
# session name is whatever the human launched Claude Code from, captured by
# init-root.sh and persisted in meta.json:root_tmux_session.
SESSION=""
if [[ -n "${ROOT_ID}" ]]; then
  REPO_ROOT="$(cd "$(git rev-parse --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd || true)"
  META="${REPO_ROOT:-}/.agent-tdd/${ROOT_ID}/meta.json"
  if [[ -f "${META}" ]]; then
    SESSION="$(grep -E '"root_tmux_session"' "${META}" | sed -E 's/.*"root_tmux_session"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
  fi
fi
# Fall back to the caller's current session if meta.json wasn't reachable.
if [[ -z "${SESSION}" ]] && [[ -n "${TMUX:-}" ]]; then
  SESSION="$(tmux display-message -p '#S' 2>/dev/null || true)"
fi

# Transient banner in the dashboard session (best-effort)
if [[ -n "${SESSION}" ]]; then
  tmux display-message -t "${SESSION}:" "${MSG}" 2>/dev/null || true
fi

# Rename dashboard window
if [[ -n "${ROOT_ID}" ]] && [[ -n "${SESSION}" ]]; then
  tmux rename-window -t "${SESSION}:${ROOT_ID}" "${ROOT_ID}: ${MSG}" 2>/dev/null || true
  if [[ "${STYLE}" == "urgent" ]]; then
    tmux set-window-option -t "${SESSION}:${ROOT_ID}" window-status-style 'bg=red,fg=white' 2>/dev/null || true
  fi
fi

# OS notification
if command -v notify-send >/dev/null 2>&1; then
  notify-send "Agent TDD" "${MSG}" 2>/dev/null || true
elif command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"${MSG//\"/\\\"}\" with title \"Agent TDD\"" 2>/dev/null || true
fi

exit 0
