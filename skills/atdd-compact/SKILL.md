---
name: atdd-compact
description: Hand the in-flight Agent TDD workflow off to a fresh agent session by checkpointing state to the local atdd store (issues + handoff brief) and spawning a new tmux window that resumes via `/atdd resume root-<id>`. Use when the current Root's conversation has bloated mid-workflow but the wave isn't done.
disable-model-invocation: true
user-invocable: true
allow-implicit-invocation: false
allowed-tools: Bash Read Write Edit Grep Glob
argument-hint: (no arguments)
---

# Compact handoff (current-Root utility)

You are the in-flight Root for some `root-<id>`. The human invoked `/atdd-compact` because your conversation has grown large but the wave-based workflow is not done. Your job here is **one-shot**: externalize everything the next Root needs and spawn it in a new tmux window. After this skill runs, you become inert — the new agent session takes over as Root for the same `root-<id>`.

This is **not** a parallel orchestrator. The new window re-enters `/atdd` in resume mode on the same `root-<id>`, reads its state dir, and continues from where you left off.

---

## Hard invariants

1. **You are still the autopilot Root until you finish step 6.** Do not converse with the human about the workflow's substance — just execute the handoff procedure.
2. **The mindset is gap-free.** The next Root must be able to continue with *zero* loss of context. Anything live only in your conversation memory must be written into the handoff brief in step 2.
3. **One root-id, one Root in flight.** After you archive your window in step 6, only the new window's Root is active. If verification in step 5 fails, you do **not** archive — both windows stay alive and you surface diagnostics to the human.
4. **Children keep running through the handoff.** Test/impl agents in `ws-root-<id>` write status files atomically; they don't care which Root reads them. The new Root will re-issue `wave-watcher.sh` on resume — your old background watcher (if any) becomes a dangling no-op (harmless; both watch the same status dir).

---

## Preflight guard

If `meta.json` does not exist (or `current_wave == 0`), refuse:

```
The compact handoff is only for in-flight workflows past Wave 0. There is no durable
state yet for me to hand off. Either complete Wave 0 (let `init-root.sh` run) or use
/clear to reset this session.
```

Otherwise proceed.

---

## Step 0 — ensure the `atdd` binary

The checkpoint + resume recipes use the local `atdd` CLI. Ensure it's installed: run
`bash ${CLAUDE_SKILL_DIR}/../ensure-atdd.sh` (see `${CLAUDE_SKILL_DIR}/../INIT_SETUP.md`).
Do not proceed until `atdd ping` works.

## Step 1 — gather the truth

Resolve these once at the top:

```bash
REPO_ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
# Identify your own root-id by matching your tmux window id against meta.json files:
MY_WIN_ID="$(tmux display-message -p -t "$TMUX_PANE" '#{window_id}')"
ROOT_ID=""
for meta in "${REPO_ROOT}/.atdd/"root-*/meta.json; do
  if grep -q "\"root_tmux_window_id\": \"${MY_WIN_ID}\"" "$meta"; then
    ROOT_ID="$(jq -r '.root_id' "$meta")"
    break
  fi
done
[[ -n "$ROOT_ID" ]] || { echo "could not identify your root-id from window ${MY_WIN_ID}"; exit 1; }
STATE_DIR="${REPO_ROOT}/.atdd/${ROOT_ID}"
WAVE="$(jq -r '.current_wave' "${STATE_DIR}/meta.json")"
```

Then read, in order:

1. `${STATE_DIR}/meta.json` (root_id, task, base, gh_account, current_wave, root_worktree, root_tmux_session, root_tmux_window_id).
2. `${STATE_DIR}/wave-${WAVE}/manifest.json` (wave issues + expected_terminal_count).
3. `ls -la ${STATE_DIR}/wave-${WAVE}/status/` (terminal/paused state).
4. Active wave issues: `atdd issue list --label agent-tdd:active-wave-${WAVE} --label agent-tdd:root-${ROOT_ID} --json number,title,state,labels`.
5. For each active wave issue `<X>`, read its work-item's branch/green/merged fields: `atdd issue view <X>` (the `issue-${X}-impl` branch, whether it is green, and whether it has merged into integration). Some issues will have no branch yet (test agent still running, or impl pre-branch). There are **no PRs in flight** in the inner flow.
6. Current rebase escalations (any issues labeled `agent-tdd:rebase-blocked` or `agent-tdd:rebase-regression`).

Re-read `${CLAUDE_SKILL_DIR}/../atdd/PROTOCOL.md` so the resume vocabulary is fresh in your context — you'll cite section numbers in the brief.

---

## Step 2 — draft the handoff brief

Read the template at `${CLAUDE_SKILL_DIR}/../atdd-compact/templates/checkpoint-comment.md`. Fill **every** section. The "Conversation gap-fill" and "Next concrete action" sections are the load-bearing ones — be specific.

Template sections you must fill:

- **Identity** — root-id, task, state-dir abs path, root worktree, base, gh_account, current wave.
- **Phase** — your current phase preamble (the `[wave-N: ...]` line you'd be writing right now), last gate passed (`wave-init` / `gate-1` / `gate-2`), manifest path.
- **Per-issue state** — one row per wave issue: status file or `(no terminal yet)`, agent live? (PID alive in `pgrep -af "issue-${X}"`), branch + green + merged state, last expected transition, blockers.
- **Pending decisions** — bullets. What needs Root judgment to advance? Examples: "rebase ladder rung 2 in flight on issue #42 — rebase agent spawned 12m ago in `ws-root-${ROOT_ID}:rebase-42`"; "issue #7 abort retries used 1/1 — second abort would escalate per §3.5"; "issue #11 paused-and-answered, watcher needs re-issuing".
- **Next concrete action** — literal step from PROTOCOL with section number. Example: "PROTOCOL.md §3.5 step 3 — drive Gate 2: merge the green `issue-42-impl`, `issue-45-impl` branches into integration (`atdd`). On conflict follow §3.7 ladder."
- **Conversation gap-fill** — anything live in your conversation that is **not** durable on disk. Recent human directives (slash-commanded? freeform?), decisions made in the last few turns, work-in-progress reasoning. **If everything were also on disk you wouldn't need this skill — so this section will rarely be empty.**
- **Pointers** — relevant PROTOCOL section anchors (§6.1, §3.5, §3.7), log bundle path, decisions log path.

Write the filled brief to `/tmp/atdd-handoff-${ROOT_ID}-${WAVE}.md` (use the `Write` tool — do **not** include the template's instructional comments; just the rendered brief).

---

## Step 3 — persist and post

```bash
bash ${CLAUDE_SKILL_DIR}/../atdd-compact/recipes/write-checkpoint.sh "${ROOT_ID}" /tmp/atdd-handoff-${ROOT_ID}-${WAVE}.md
```

The recipe:

- Copies the brief to `${STATE_DIR}/wave-${WAVE}/handoff.md` (durable, ungated by the store).
- Comments the brief on every active wave issue (in the store).

It prints a summary of where it posted to stderr; capture-pane that to verify.

---

## Step 4 — spawn the resume window

```bash
NEW_WIN_ID="$(bash ${CLAUDE_SKILL_DIR}/../atdd-compact/recipes/spawn-resume-window.sh "${ROOT_ID}")"
```

The recipe:

- Reads `root_tmux_session` and `repo_root` from `meta.json`.
- Creates a new window in the dashboard session, named `${ROOT_ID}-resume` (or `-resume-2`, `-resume-3` etc. if collision), with cwd `${repo_root}`.
- Launches the agent CLI in it.
- Waits up to 30s for the interactive prompt to appear.
- Sends the resume slash command + Enter via `tmux send-keys` (`/atdd resume ${ROOT_ID}` under OpenCode; `/agent-tdd:atdd resume ${ROOT_ID}` under Claude Code — the recipe picks the right form from `AGENT_TDD_CLI`).
- Prints the new window's stable window ID (e.g. `@12`) on stdout.

If the recipe fails (non-zero exit), abort the handoff — do **not** proceed to step 5/6. Surface the recipe's stderr to the human.

---

## Step 5 — verify the handoff (you read the new pane)

Wait 60 seconds (one Bash call):

```bash
sleep 60
```

Then capture the new window's pane:

```bash
tmux capture-pane -p -t "${NEW_WIN_ID}" -S -300
```

Read the captured prose with your own eyes. **You are the only one who can judge this** — the prior context lives in your conversation; the human can't sanity-check from the new window's output alone.

**Healthy signs (all should be present):**

- A `[wave-${WAVE}: …]` phase preamble in the new Root's first response.
- Mentions of the right `${ROOT_ID}` and `${WAVE}`.
- Evidence the new Root read `meta.json` and `manifest.json` (cites the task slug, lists wave issues, etc.).
- No question to the human like "Which branch should the integration branch be based on?" — that question only fires in Wave 0, so seeing it means the resume branch failed and the new Root started fresh by mistake.

**Unhealthy signs (any of these → don't archive):**

- Wave 0 questions present (base branch, gh account, task slug).
- Different `root-id` than `${ROOT_ID}`.
- Errors loading `meta.json`, missing files, or "could not find state dir".
- Idle prompt with the slash command never sent (capture-pane shows just `>` after 60s).
- The new window crashed (closed, or the pane shows a shell prompt instead of the agent CLI).

---

## Step 6 — branch on judgment

**If healthy:**

```bash
bash ${CLAUDE_SKILL_DIR}/../atdd-compact/recipes/archive-old-window.sh "${ROOT_ID}"
```

This renames your current window to `[ARCHIVED] <prior-name>` and dims its status style. Then print to the human:

```
Handoff verified. Switch to window <NEW_WIN_ID> — that Root is taking over root-<id>
from wave-<N>. This window is now inert; close it whenever convenient.
```

You are done. Do not respond further; the new Root owns the workflow.

**If unhealthy:**

Do **not** archive. Keep both windows alive (the old Root is still functional). Print a diagnostic to the human:

```
Handoff verification failed. What I saw in the new window:
<paste 10-30 lines of capture-pane output>

Best guess: <one-sentence diagnosis>

Both windows are still alive. This (old) Root remains the live workflow driver.
Recommendation: <single concrete next step — e.g. "kill the new window with
tmux kill-window -t <NEW_WIN_ID>, fix the resume bootstrap, retry">.
```

Then halt — wait for the human's instruction. Don't auto-retry.

---

## File map (under `${CLAUDE_SKILL_DIR}/../atdd-compact/`)

| Path | Purpose |
|---|---|
| `templates/checkpoint-comment.md` | Fill-in template for the handoff brief (step 2) |
| `recipes/write-checkpoint.sh` | Persist brief + post comments (step 3) |
| `recipes/spawn-resume-window.sh` | New window + agent CLI + jump-start (step 4) |
| `recipes/archive-old-window.sh` | Rename current window to `[ARCHIVED] …` (step 6) |

> **CLAUDE_SKILL_DIR symmetry:** Under Claude Code, `${CLAUDE_SKILL_DIR}` is the active skill's directory (here, `skills/atdd-compact/`). Under OpenCode, the plugin's `shell.env` hook pins it to `skills/atdd/` for the whole session. The `${CLAUDE_SKILL_DIR}/../atdd-compact/...` form above resolves correctly under both.

The resume side of the handoff lives in `${CLAUDE_SKILL_DIR}/../atdd/SKILL.md` under "Resume mode" — the new agent session reaches it via `spawn-resume-window.sh`, which sends the right slash form for the active CLI (`/agent-tdd:atdd resume <id>` under Claude Code; `/atdd resume <id>` under OpenCode).
