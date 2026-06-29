#!/usr/bin/env bash
# stack-zoom-stop.sh — Claude Code `Stop` hook: the hard backstop that keeps a
# one-shot worker agent (Test / Impl) from ending until its end-of-task Stack
# zoom-in has run clean (the completion marker exists). Phase C / C2, Layer 3.
#
# Scope: ONLY the autonomous one-shot agents. The launcher exports, into the
# agent's `claude` process env:
#   ATDD_ROLE        test | impl   (set ONLY for those two; absent otherwise)
#   ATDD_ISSUE       <N>
#   ATDD_STATUS_DIR  <wave status dir>
# Any other session (the human's own, Root, Notes — which pause for the human and
# would mis-fire) has no ATDD_ROLE in {test,impl}, so this hook no-ops (exit 0).
#
# stdin:  the Stop hook JSON ({..,"stop_hook_active":bool}).
# stdout: on block, the decision JSON; otherwise nothing.
# exit:   always 0 (control is the JSON, never the exit code).
set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"

# Loop guard: if we are already the active blocking Stop hook, let the agent stop
# (the 8-block cap also backstops). Never lock an agent out.
if command -v jq >/dev/null 2>&1; then
  [[ "$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null)" == "true" ]] && exit 0
fi

case "${ATDD_ROLE:-}" in
  test|impl) ;;            # enforce for the one-shot workers
  *) exit 0 ;;             # any other context — no-op
esac

ISSUE="${ATDD_ISSUE:-}"; SDIR="${ATDD_STATUS_DIR:-}"
[[ -n "$ISSUE" && -n "$SDIR" ]] || exit 0          # missing context — no-op (never lock out)

MARKER="${SDIR}/issue-${ISSUE}.stack-zoom-${ATDD_ROLE}"
[[ -f "$MARKER" ]] && exit 0                        # zoom-in clean — allow stop

cat <<EOF
{"hookSpecificOutput":{"hookEventName":"Stop","decision":"block","reason":"End-of-task Stack zoom-in not done for issue ${ISSUE} (role ${ATDD_ROLE}). Per STACK_USAGE.md (the end-of-task zoom-in), update the Stack for the boxes you touched, then run skills/atdd/recipes/stack-zoom.sh (it runs \`atdd stack verify\` and writes the completion marker). You cannot finish until that recipe exits 0."}}
EOF
exit 0
