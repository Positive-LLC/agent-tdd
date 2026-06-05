#!/usr/bin/env bash
# roots-watcher.sh — single-shot background event watcher for one cohort of Roots.
#
# The Notes-Agent-orchestration analogue of wave-watcher.sh. A cohort is the set
# of Roots spawned for the ready SubIssues of ONE RootIssue (one-RootIssue-at-a-
# time). Issued ONCE per wait, via Bash(run_in_background=true), so the
# orchestrator is idle (zero turns/tokens) until an event — identical economics to
# wave-watcher.sh. Re-issued after the orchestrator consumes an event.
#
# Usage:  roots-watcher.sh <cohort-json>
#
#   <cohort-json>  absolute path to cohort-<RI#>/cohort.json (written by
#                  spawn-root.sh). Records each member's absolute signal_path,
#                  window_id, and last_consumed_seq. The watcher reads paths
#                  VERBATIM — it never calls git/gh and is repo-agnostic, so one
#                  watcher polls Roots living in many different target repos.
#
# Cross-repo note: completion is NOT polled here. GitHub stays the source of
# truth for "work done"; the watcher reads ONLY local signal files + tmux window
# liveness (zero gh API calls — no rate-limit exposure). The orchestrator does the
# single gh merge-verify when it finalizes a Root.
#
# Events (emitted to stdout, highest-priority match first, then exit 0):
#   EVENT=root-event STATE=<s> SUB_REF=<r> SEQ=<n> SIGNAL_PATH=<p>
#       a member's signal seq advanced past its last_consumed_seq (a NEW state
#       event the orchestrator must dispatch on: paused-needs-proxy /
#       awaiting-merge-confirm / rebase-blocked / stuck / failed / crashed).
#   EVENT=root-dead SUB_REF=<r>
#       a member's tmux window is gone and its signal is not a clean/known
#       terminal — a Root that died without even a crash signal (spawn-failed or
#       killed). The orchestrator escalates with a recommendation.
#   EVENT=cohort-ready
#       every member is settled (awaiting-merge-confirm / failed / crashed) with
#       no unconsumed event → the orchestrator runs the consolidated per-(repo,base)
#       human approval and advances.
#   EVENT=timeout ELAPSED_SEC=<n>
#       per-invocation hard ceiling (default 3600s = 60 min) — the orchestrator
#       runs a per-Root health check (window alive? heartbeat_ts advancing?) and
#       self-extends once for a live, progressing Root or escalates.
#
# Override the ceiling via ROOTS_WATCHER_TIMEOUT_SEC (tests only).

set -uo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <cohort-json>" >&2; exit 1; }
COHORT_JSON="$1"
[[ -f "${COHORT_JSON}" ]] || { echo "EVENT=error"; echo "REASON=cohort-json-missing:${COHORT_JSON}"; exit 0; }

command -v jq >/dev/null 2>&1 || { echo "EVENT=error"; echo "REASON=jq-missing"; exit 0; }

TIMEOUT_SEC="${ROOTS_WATCHER_TIMEOUT_SEC:-3600}"
DEADLINE=$(( $(date +%s) + TIMEOUT_SEC ))
START=$(date +%s)

# Is a tmux window (by stable id) still alive? Enumerate all windows and match
# exactly — `tmux display-message -t <bad-id>` can fall back to the current
# window and falsely report a dead window as alive, so it is NOT a valid
# existence check. `list-windows -a` over a missing server simply yields nothing.
window_alive() {
  local wid="$1"
  [[ -n "${wid}" && "${wid}" != "null" ]] || return 1
  tmux list-windows -a -F '#{window_id}' 2>/dev/null | grep -qx "${wid}"
}

while true; do
  # Re-read cohort.json each tick (the orchestrator may have updated
  # last_consumed_seq between re-issues).
  members="$(jq -r '.members | to_entries[] | [.key, (.value.signal_path//""), (.value.window_id//""), (.value.last_consumed_seq//0)] | @tsv' "${COHORT_JSON}" 2>/dev/null || true)"

  all_settled=1
  any_member=0
  dead_sub=""
  ev_sub=""; ev_state=""; ev_seq=""; ev_sigpath=""

  while IFS=$'\t' read -r sub_ref sig_path win_id last_seq; do
    [[ -n "${sub_ref}" ]] || continue
    any_member=1
    [[ "${last_seq}" =~ ^[0-9]+$ ]] || last_seq=0

    state=""; seq=0
    if [[ -n "${sig_path}" && -f "${sig_path}" ]]; then
      state="$(jq -r '.state // empty' "${sig_path}" 2>/dev/null || echo "")"
      seq="$(jq -r '.seq // 0' "${sig_path}" 2>/dev/null || echo 0)"
      [[ "${seq}" =~ ^[0-9]+$ ]] || seq=0
    fi

    # New state event? (seq advanced past what the orchestrator consumed)
    if [[ -z "${ev_sub}" && "${seq}" -gt "${last_seq}" && -n "${state}" ]]; then
      ev_sub="${sub_ref}"; ev_state="${state}"; ev_seq="${seq}"; ev_sigpath="${sig_path}"
    fi

    # Settled? (terminal from the watcher's perspective)
    case "${state}" in
      awaiting-merge-confirm|failed|crashed) : ;;   # settled
      *)
        all_settled=0
        # Dead detection: window gone and not a settled/known-terminal state.
        if ! window_alive "${win_id}"; then
          case "${state}" in
            complete|awaiting-merge-confirm|failed|crashed) : ;;
            *) [[ -z "${dead_sub}" ]] && dead_sub="${sub_ref}" ;;
          esac
        fi
        ;;
    esac
  done <<< "${members}"

  # --- emit, highest priority first ---
  if [[ -n "${ev_sub}" ]]; then
    echo "EVENT=root-event"
    echo "STATE=${ev_state}"
    echo "SUB_REF=${ev_sub}"
    echo "SEQ=${ev_seq}"
    echo "SIGNAL_PATH=${ev_sigpath}"
    exit 0
  fi
  if [[ -n "${dead_sub}" ]]; then
    echo "EVENT=root-dead"
    echo "SUB_REF=${dead_sub}"
    exit 0
  fi
  if [[ "${any_member}" -eq 1 && "${all_settled}" -eq 1 ]]; then
    echo "EVENT=cohort-ready"
    exit 0
  fi
  if [[ "$(date +%s)" -ge "${DEADLINE}" ]]; then
    echo "EVENT=timeout"
    echo "ELAPSED_SEC=$(( $(date +%s) - START ))"
    exit 0
  fi
  sleep 10
done
