#!/usr/bin/env bash
# drop-feedback.sh — drop one alpha-feedback note about the atdd-cli tool.
#
# atdd-cli is in early ALPHA. When any of the four Stack-using agents (Test, Impl,
# Root, Notes) hits friction — a confusing verb, an error, a missing flag, a place
# the model can't express the architecture, a doc gap — it drops a short note here
# so the human can skim them all later. This is a SIDE channel: it must never get
# in the way of the agent's real TDD task (see STACK_USAGE.md "🚧 ALPHA" box).
#
# One file PER NOTE (not one per repo): four agents work the same repo concurrently
# across many waves, so a shared per-repo file would clobber. The filename carries
# the project slug + role + a UTC timestamp + a random suffix so drops never collide.
# (The atdd-cli repo's own STACK_USAGE.md §5 documents a separate, heavier per-repo
# alpha-test report — that is for dedicated alpha-test sessions, not for these agents.)
#
# Usage:
#   drop-feedback.sh --summary "<one line>" [--role <r>]        # one-liner
#   printf '<rich detail>\n' | drop-feedback.sh --summary "…"   # + body from STDIN
#
#   --summary   REQUIRED one-line gist (becomes the report's headline).
#   --role      the dropping agent (test|impl|root|notes). Defaults to $ATDD_ROLE,
#               which only Test/Impl set — so Root/Notes pass --role explicitly.
#   STDIN       optional rich body (exact command + output, what you expected, etc.);
#               read only when stdin is not a TTY, so a no-pipe call never hangs.
#
# Destination: $ATDD_FEEDBACK_DIR if set, else the in-house default below. The override
# exists for the hermetic test (and trivial future flexibility); the default is the path
# the human skims. If the dir can't be created (e.g. a shipped install on another machine)
# this is a clean no-op — never an error, never junk.
#
# Atomic write (.tmp then mv), matching every other file write in this repo.
# Progress to stderr; only the final note path goes to stdout.
# exit: 0 = note written OR graceful no-op · 2 = bad args (missing --summary).

set -uo pipefail   # not -e: a feedback drop must never abort the agent's real task

log() { printf '[drop-feedback] %s\n' "$*" >&2; }
die() { printf '[drop-feedback] ERROR: %s\n' "$*" >&2; exit 2; }

SUMMARY=""; ROLE="${ATDD_ROLE:-unknown}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --summary) SUMMARY="${2:-}"; shift 2 ;;
    --role)    ROLE="${2:-}";    shift 2 ;;
    *) die "unknown arg: $1 (usage: drop-feedback.sh --summary \"<one line>\" [--role <r>])" ;;
  esac
done
# Validate BEFORE touching stdin, so a bad-args call exits fast and never blocks on cat.
[[ -n "$SUMMARY" ]] || die "--summary \"<one line>\" is required"

# Optional rich body from stdin (only when piped — never block waiting on a TTY).
BODY=""
if [[ ! -t 0 ]]; then BODY="$(cat)"; fi

FEEDBACK_DIR="${ATDD_FEEDBACK_DIR:-/home/m6/willy/atdd-cli/feedback}"
mkdir -p "$FEEDBACK_DIR" 2>/dev/null \
  || { log "cannot write ${FEEDBACK_DIR} — feedback drop skipped (no-op)"; exit 0; }

# Metadata, all best-effort and non-fatal.
SLUG="${ATDD_PROJECT:-unknown}"; SLUG="${SLUG//\//-}"     # project slug may contain '/'
SAFE_ROLE="${ROLE//\//-}"
TS="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
REPO="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo unknown)" 2>/dev/null || echo unknown)"
VER="unknown"
if command -v atdd >/dev/null 2>&1; then VER="$(atdd --version 2>/dev/null | awk '{print $NF}')"; VER="${VER:-unknown}"; fi

FILE="${FEEDBACK_DIR}/${SLUG}__${SAFE_ROLE}__${TS}__$$-${RANDOM}.md"
TMP="${FILE}.tmp.$$"

{
  printf '# atdd-cli alpha feedback\n\n'
  printf -- '- when: %s\n' "$TS"
  printf -- '- agent role: %s\n' "$SAFE_ROLE"
  printf -- '- project: %s · repo: %s\n' "$SLUG" "$REPO"
  printf -- '- atdd version: %s\n\n' "$VER"
  printf '## summary\n%s\n\n' "$SUMMARY"
  printf '## detail\n%s\n' "${BODY:-(none)}"
} > "$TMP" 2>/dev/null || { log "failed to render note; skipped"; rm -f "$TMP" 2>/dev/null; exit 0; }

mv "$TMP" "$FILE" 2>/dev/null || { log "failed to commit note; skipped"; rm -f "$TMP" 2>/dev/null; exit 0; }

log "feedback noted -> ${FILE}"
printf '%s\n' "$FILE"
exit 0
