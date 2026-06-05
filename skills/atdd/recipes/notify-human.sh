#!/usr/bin/env bash
# notify-human.sh — surface a message to the human via tmux + OS notification.
#
# Usage:  notify-human.sh <message> [<root-id>] [<style>]
#
#   <message>   — short message (one line)
#   <root-id>   — optional; if provided, renames the dashboard window via the
#                 stable window ID stored in meta.json:root_tmux_window_id.
#                 The session is also read from meta.json (used only for the
#                 transient display-message banner).
#   <style>     — optional; one of "info" (default) or "urgent". Urgent applies
#                 a red window style.
#
# Effects:
#   - tmux display-message in the dashboard session (transient banner).
#   - tmux rename-window if <root-id> provided — targeted by window ID, never
#     by `<session>:<window-name>`. Window IDs (e.g. `@7`) are stable for the
#     window's lifetime, never collide, and never shift; targeting by name is
#     unsafe because tmux's resolution order tries window-INDEX before name
#     (man tmux: target-window), so a numeric default name silently turns into
#     "the window currently at that index."
#   - OS-level notification via notify-send (Linux) or osascript (macOS).
#
# Never injects keystrokes — only manipulates window metadata.

set -uo pipefail

[[ $# -ge 1 ]] || { echo "usage: $0 <message> [<root-id>] [<style>]" >&2; exit 1; }
MSG="$1"
ROOT_ID="${2:-}"
STYLE="${3:-info}"

# --- orchestration belt-and-suspenders -------------------------------------
# When an ORCHESTRATED Root reaches the human via this script, also drop a
# liveness/escalation signal so the Notes-Agent orchestrator's roots-watcher
# notices even an escalation path that PROTOCOL.md forgot to annotate with an
# explicit write-signal.sh call. This is gated on AGENT_TDD_ORCHESTRATED (set
# only in an orchestrated Root's env), so the orchestrator's OWN notify-human
# calls — which surface to the real human and never set that var — never write a
# Root signal. It is NON-CLOBBERING: it only fires when the current signal is
# `running`/absent, so a more specific escalation signal the Root just wrote
# (paused-needs-proxy / rebase-blocked / awaiting-merge-confirm) is preserved.
if [[ "${AGENT_TDD_ORCHESTRATED:-}" == "1" ]] && [[ -n "${AGENT_TDD_SIGNAL_PATH:-}" ]]; then
  _cur_state=""
  if [[ -f "${AGENT_TDD_SIGNAL_PATH}" ]] && command -v jq >/dev/null 2>&1; then
    _cur_state="$(jq -r '.state // empty' "${AGENT_TDD_SIGNAL_PATH}" 2>/dev/null || echo "")"
  fi
  if [[ -z "${_cur_state}" || "${_cur_state}" == "running" ]]; then
    bash "$(dirname "$0")/write-signal.sh" stuck \
      --detail "notify-human fallback: ${MSG}" \
      --recommendation "Root escalated via notify-human with no specific signal; inspect its window." \
      2>/dev/null || true
  fi
fi

# Resolve dashboard session (for banner) and window ID (for rename) from
# meta.json — captured once at init-root time, never re-derived.
SESSION=""
WINDOW_ID=""
if [[ -n "${ROOT_ID}" ]]; then
  REPO_ROOT="$(cd "$(git rev-parse --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd || true)"
  META="${REPO_ROOT:-}/.agent-tdd/${ROOT_ID}/meta.json"
  if [[ -f "${META}" ]]; then
    SESSION="$(grep -E '"root_tmux_session"' "${META}" | sed -E 's/.*"root_tmux_session"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
    WINDOW_ID="$(grep -E '"root_tmux_window_id"' "${META}" | sed -E 's/.*"root_tmux_window_id"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
  fi
fi
# Fall back to the caller's current session if meta.json wasn't reachable.
# (No fallback for window ID — without it we refuse to rename rather than
# risk targeting the wrong window.)
if [[ -z "${SESSION}" ]] && [[ -n "${TMUX:-}" ]] && [[ -n "${TMUX_PANE:-}" ]]; then
  SESSION="$(tmux display-message -p -t "${TMUX_PANE}" '#S' 2>/dev/null || true)"
fi

# Transient banner in the dashboard session (best-effort)
if [[ -n "${SESSION}" ]]; then
  tmux display-message -t "${SESSION}:" "${MSG}" 2>/dev/null || true
fi

# Rename dashboard window via window ID (stable, unambiguous)
if [[ -n "${ROOT_ID}" ]] && [[ -n "${WINDOW_ID}" ]]; then
  tmux rename-window -t "${WINDOW_ID}" "${ROOT_ID}: ${MSG}" 2>/dev/null || true
  if [[ "${STYLE}" == "urgent" ]]; then
    tmux set-window-option -t "${WINDOW_ID}" window-status-style 'bg=red,fg=white' 2>/dev/null || true
  fi
fi

# OS notification
if command -v notify-send >/dev/null 2>&1; then
  notify-send "Agent TDD" "${MSG}" 2>/dev/null || true
elif command -v osascript >/dev/null 2>&1; then
  osascript -e "display notification \"${MSG//\"/\\\"}\" with title \"Agent TDD\"" 2>/dev/null || true
fi

exit 0
