#!/usr/bin/env bash
# notify-human.sh — surface a message to the human via tmux + OS notification.
#
# Usage:  notify-human.sh <message> [<root-id>] [<style>]
#
#   <message>   — short message (one line)
#   <root-id>   — optional; if provided, renames the dashboard window
#                 (roots:<root-id>) to include the message.
#   <style>     — optional; one of "info" (default) or "urgent". Urgent applies
#                 a red window style.
#
# Effects:
#   - tmux display-message in the `roots` session (transient banner).
#   - tmux rename-window if <root-id> provided.
#   - OS-level notification via notify-send (Linux) or osascript (macOS).
#
# Never injects keystrokes — only manipulates window metadata.

set -uo pipefail

[[ $# -ge 1 ]] || { echo "usage: $0 <message> [<root-id>] [<style>]" >&2; exit 1; }
MSG="$1"
ROOT_ID="${2:-}"
STYLE="${3:-info}"

# Transient banner in the roots session (best-effort)
tmux display-message -t roots: "${MSG}" 2>/dev/null || true

# Rename dashboard window
if [[ -n "${ROOT_ID}" ]]; then
  tmux rename-window -t "roots:${ROOT_ID}" "${ROOT_ID}: ${MSG}" 2>/dev/null || true
  if [[ "${STYLE}" == "urgent" ]]; then
    tmux set-window-option -t "roots:${ROOT_ID}" window-status-style 'bg=red,fg=white' 2>/dev/null || true
  fi
fi

# OS notification
if command -v notify-send >/dev/null 2>&1; then
  notify-send "Agent TDD" "${MSG}" 2>/dev/null || true
elif command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"${MSG//\"/\\\"}\" with title \"Agent TDD\"" 2>/dev/null || true
fi

exit 0
