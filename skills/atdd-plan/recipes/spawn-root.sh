#!/usr/bin/env bash
# spawn-root.sh — spawn one orchestrated Root Agent for one ready SubIssue.
#
# The Notes-Agent-orchestration analogue of spawn-test-agent.sh. Differences from
# the test/impl spawn (all deliberate, see ORCHESTRATE.md §3):
#   - The child window opens in the ORCHESTRATOR's OWN tmux session (the human can
#     tab to watch any Root), created with `-d` so it never steals the human's
#     focus from the orchestrator window.
#   - The child runs through launch-root.sh (the Root supervisor), launched with a
#     per-Root env prefix written to <sub-dir>/launch.sh (forensic + avoids
#     send-keys quoting fragility on a long line).
#   - A globally-unique workspace session name (ws-<notes-id>-<sub-slug>) is passed
#     so two cohort Roots in different repos (both claiming root-1) don't collide on
#     `ws-root-1`.
#   - Delivery is NOT a pasted role markdown but a SHORT bootstrap that points the
#     Root at the real atdd-from-issue/SKILL.md (read from disk via CLAUDE_SKILL_DIR —
#     no plugin registry, the proven test/impl delivery path). The Root fetches its
#     own Wave-0 seed via fetch-issue-seed.sh, so nothing large is pasted.
#
# Usage:
#   spawn-root.sh <notes-id> <rootissue-ref> <sub-ref> <repo-path> \
#                 <plugin-root> <orch-session> <base> <gh-account> <slug>
#
#   <rootissue-ref>  owner/repo#<N> of the parent RootIssue (names the cohort dir)
#   <sub-ref>        owner/repo#<N> of the ready SubIssue this Root runs
#   <repo-path>      absolute path to the local clone of the SubIssue's target repo
#   <plugin-root>    dir holding .claude-plugin/plugin.json (= ${CLAUDE_SKILL_DIR}/../..)
#   <orch-session>   the orchestrator's own tmux session (meta.json:notes_tmux_session)
#   <base>           base branch (human-confirmed at the go-gate, per repo)
#   <gh-account>     gh account for this repo
#   <slug>           Root task slug (^[a-z0-9-]+$)
#
# Prints the child window id (@NN) on stdout. Progress to stderr.

set -euo pipefail

AGENT_TDD_CLI="${AGENT_TDD_CLI:-claude}"

log() { printf '[spawn-root] %s\n' "$*" >&2; }
die() { printf '[spawn-root] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 9 ]] || die "usage: $0 <notes-id> <rootissue-ref> <sub-ref> <repo-path> <plugin-root> <orch-session> <base> <gh-account> <slug>"
NOTES_ID="$1"; RI_REF="$2"; SUB_REF="$3"; REPO_PATH="$4"; PLUGIN_ROOT="$5"
ORCH_SESSION="$6"; BASE="$7"; GH_ACCOUNT="$8"; SLUG="$9"

command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
command -v tmux >/dev/null 2>&1 || die "tmux not found on PATH"
[[ -n "${TMUX:-}" ]] || die "spawn-root.sh must run inside tmux"

# --- derive identifiers ---
# sub-slug = repo name component + '-' + issue number, non-[a-z0-9-] squashed.
SUB_REPO="${SUB_REF%%#*}"                       # owner/repo
SUB_NUM="${SUB_REF##*#}"                         # N
RI_NUM="${RI_REF##*#}"                           # parent RootIssue number
REPO_NAME="${SUB_REPO##*/}"                      # repo
SUB_SLUG="$(printf '%s-%s' "${REPO_NAME}" "${SUB_NUM}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -E 's/-+/-/g; s/^-|-$//g')"
[[ -n "${SUB_SLUG}" ]] || die "could not derive a sub-slug from ${SUB_REF}"
[[ "${SLUG}" =~ ^[a-z0-9-]+$ ]] || die "slug must match ^[a-z0-9-]+\$ (got: ${SLUG})"

# --- orchestrator state dir (the INVOKING repo's working tree) ---
ORCH_REPO_ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)" \
  || die "spawn-root.sh must run from inside the orchestrator's git repo"
NOTES_DIR="${ORCH_REPO_ROOT}/.agent-tdd/${NOTES_ID}"
[[ -d "${NOTES_DIR}" ]] || die "no orchestration state dir at ${NOTES_DIR} (run orch-init.sh first)"
COHORT_DIR="${NOTES_DIR}/cohort-${RI_NUM}"
SUB_DIR="${COHORT_DIR}/${SUB_SLUG}"
LOG_DIR="${SUB_DIR}/log"
SIGNAL_PATH="${SUB_DIR}/root-signal.json"
WS_SESSION="ws-${NOTES_ID}-${SUB_SLUG}"
WINDOW="root-${SUB_SLUG}"
TARGET="${ORCH_SESSION}:${WINDOW}"
COHORT_JSON="${COHORT_DIR}/cohort.json"

# --- sanity: the clone is a usable git repo (orchestrator already pre-validates
#     cleanliness + base existence upstream; this is a defensive backstop) ---
git -C "${REPO_PATH}" rev-parse --git-dir >/dev/null 2>&1 \
  || die "repo-path is not a git repo: ${REPO_PATH}"

# --- idempotency: refuse a duplicate window for this SubIssue ---
if tmux list-windows -t "${ORCH_SESSION}" -F '#W' 2>/dev/null | grep -qx "${WINDOW}"; then
  die "window ${TARGET} already exists; a Root for ${SUB_REF} is already spawned"
fi

mkdir -p "${LOG_DIR}" "${COHORT_DIR}"

# Cohort wall-clock anchor (first member spawned). The orchestrator's per-cohort
# ceiling (meta.json:cohort_wallclock_cap_sec) is measured from this — see
# ORCHESTRATE.md §4.2. Idempotent: written once per cohort.
[[ -f "${COHORT_DIR}/started_at" ]] || date -u +%Y-%m-%dT%H:%M:%SZ > "${COHORT_DIR}/started_at"

# NOTE on gh identity: v1 uses ONE gh account for the whole orchestration run
# (orch-init.sh takes a single <gh-account>; the orchestrator asserts every
# cohort SubIssue resolves to it). Because all Roots switch to the SAME account,
# the global `gh auth switch` race documented in PROTOCOL.md §2.4 is benign here
# (concurrent switches all set the same active account). Per-repo distinct
# accounts are a deferred enhancement (would need GH_CONFIG_DIR isolation
# propagated to every grandchild gh process). See ROADMAP / ORCHESTRATE.md.

# --- registry entry BEFORE the spawn side-effect (crash-recoverable record) ---
upsert_member() {
  local state="$1" window_id="$2"
  local tmp="${COHORT_JSON}.tmp.$$"
  local base_doc='{}'
  if [[ -f "${COHORT_JSON}" ]]; then base_doc="$(cat "${COHORT_JSON}")"; fi
  jq -n \
    --argjson base "${base_doc}" \
    --arg ri "${RI_REF}" --arg nid "${NOTES_ID}" \
    --arg sref "${SUB_REF}" --arg sslug "${SUB_SLUG}" --arg srepo "${SUB_REPO}" \
    --arg rpath "${REPO_PATH}" --arg sig "${SIGNAL_PATH}" \
    --arg ws "${WS_SESSION}" --arg win "${TARGET}" --arg wid "${window_id}" \
    --arg st "${state}" '
    ($base // {}) as $b
    | {
        rootissue: $ri,
        notes_id:  $nid,
        members:   (($b.members // {}) + {
          ($sref): {
            sub_slug:        $sslug,
            repo:            $srepo,
            repo_path:       $rpath,
            signal_path:     $sig,
            ws_session:      $ws,
            window:          $win,
            window_id:       (if $wid == "" then null else $wid end),
            state:           $st,
            last_consumed_seq: (($b.members // {})[$sref].last_consumed_seq // 0)
          }
        })
      }
  ' > "${tmp}"
  mv "${tmp}" "${COHORT_JSON}"
}
upsert_member "spawning" ""
log "registry entry written (spawning) for ${SUB_REF}"

# --- open the Root window in the orchestrator's own session (detached: never
#     steal the human's focus from the orchestrator window) ---
log "opening window ${TARGET} at ${REPO_PATH}"
tmux new-window -d -t "${ORCH_SESSION}:" -n "${WINDOW}" -c "${REPO_PATH}"
WINDOW_ID="$(tmux display-message -p -t "${TARGET}" '#{window_id}' 2>/dev/null || true)"
[[ -n "${WINDOW_ID}" ]] || die "could not capture window id for ${TARGET}"
upsert_member "launching" "${WINDOW_ID}"
log "window id ${WINDOW_ID} captured"

# --- capture pane to disk before launch (forensics; pane scrollback is volatile) ---
tmux pipe-pane -t "${TARGET}" "cat >> '${LOG_DIR}/tmux.pane'"

# --- write the per-Root launch wrapper (env prefix on disk; avoids send-keys
#     quoting fragility on a long line) ---
SKILL_DIR_FROM="${PLUGIN_ROOT}/skills/atdd-from-issue"   # so ../atdd* resolves
LAUNCH_SH="${SUB_DIR}/launch.sh"
cat > "${LAUNCH_SH}" <<EOF
#!/usr/bin/env bash
# Auto-generated by spawn-root.sh for ${SUB_REF}. Sets the orchestration env,
# then exec's the Root supervisor (exec keeps the supervisor's crash trap as the
# pane's foreground process).
export AGENT_TDD_ORCHESTRATED=1
export AGENT_TDD_NOTES_ID='${NOTES_ID}'
export AGENT_TDD_SUB_REF='${SUB_REF}'
export AGENT_TDD_BASE='${BASE}'
export AGENT_TDD_GH_ACCOUNT='${GH_ACCOUNT}'
export AGENT_TDD_SLUG='${SLUG}'
export AGENT_TDD_WS_SESSION='${WS_SESSION}'
export AGENT_TDD_SIGNAL_PATH='${SIGNAL_PATH}'
export CLAUDE_SKILL_DIR='${SKILL_DIR_FROM}'
export AGENT_TDD_CLI='${AGENT_TDD_CLI}'
exec bash '${PLUGIN_ROOT}/skills/atdd-plan/recipes/launch-root.sh' '${LOG_DIR}'
EOF
chmod +x "${LAUNCH_SH}"

# --- launch the supervisor in the window ---
tmux send-keys -t "${TARGET}" "bash '${LAUNCH_SH}'" Enter

# --- wait for the CLI prompt (same poll as spawn-test-agent.sh) ---
log "waiting for ${AGENT_TDD_CLI} prompt in ${TARGET}"
for _ in $(seq 1 60); do
  if tmux capture-pane -p -t "${TARGET}" 2>/dev/null | tail -5 | grep -qE '^[> ]'; then
    break
  fi
  sleep 1
done

# --- build the SHORT bootstrap prompt (points the Root at the real wrapper md) ---
PROMPT_FILE="${SUB_DIR}/bootstrap.txt"
cat > "${PROMPT_FILE}" <<EOF
You are an orchestrated Root Agent for one Agent TDD SubIssue.

Read \${CLAUDE_SKILL_DIR}/../atdd-from-issue/SKILL.md and operate per its
"Orchestrated mode" branch (its §0), then continue exactly as that wrapper and
\${CLAUDE_SKILL_DIR}/../atdd/PROTOCOL.md direct.

SUB_REF=${SUB_REF}

You are running under the Notes-Agent orchestrator (AGENT_TDD_ORCHESTRATED=1 is
set in your environment): your "human" is the orchestrator, not a person. Take
base / GitHub account (final-PR only) / task slug from your environment
(AGENT_TDD_BASE, AGENT_TDD_GH_ACCOUNT, AGENT_TDD_SLUG); skip the human Wave-0 questions and the
"go" wait; use AGENT_TDD_WS_SESSION as your workspace tmux session; and surface
every escalation by running \${CLAUDE_SKILL_DIR}/../atdd/recipes/write-signal.sh
(never address a person directly). At final integration (§8) write the
awaiting-merge-confirm signal and stop — the orchestrator performs the
merge-to-base after the real human confirms.

Begin now.
EOF

# --- paste it via tmux buffer (bracketed paste; the prompt is multi-line) ---
BUF="atdd-spawn-root-${SUB_SLUG}"
tmux load-buffer -b "${BUF}" "${PROMPT_FILE}"
tmux paste-buffer -p -t "${TARGET}" -b "${BUF}"
tmux delete-buffer -b "${BUF}" 2>/dev/null || true
sleep 0.3
tmux send-keys -t "${TARGET}" Enter

upsert_member "running" "${WINDOW_ID}"
log "Root for ${SUB_REF} dispatched (window ${WINDOW_ID}, ws ${WS_SESSION})"

printf '%s\n' "${WINDOW_ID}"
