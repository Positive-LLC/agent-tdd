# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **Claude Code plugin** — not application code. It ships shell scripts and markdown that orchestrate a wave-based human-agent TDD workflow. The plugin is invoked from another repo via `claude --plugin-dir /path/to/agent-tdd`. As of v0.10.0 the plugin is **two layers**:

- **Root Agent layer** (`skills/atdd/`): the wave orchestrator. Entry points `/agent-tdd:atdd` (free-form spec), `/agent-tdd:atdd-from-issue` (consume a planned SubIssue), plus the demo / compact wrappers.
- **Notes Agent layer** (`skills/atdd-plan/` shared library + `skills/atdd-fix/` entry): the planning agent that produces well-specced GitHub artifacts for the Root Agent layer to consume.

There are **no build/lint/test commands**. Validation is:

- `bash -n skills/atdd/recipes/*.sh skills/atdd-plan/recipes/*.sh skills/atdd-from-issue/recipes/*.sh` — syntax-check shell scripts (the only "compile" step).
- Manual end-to-end smoke tests in a throwaway repo (see ROADMAP.md "Smoke-Test Risks").

## Source-of-truth hierarchy

When documents disagree, this is the precedence:

1. **PROTOCOL.md** (`skills/atdd/PROTOCOL.md`) wins for **Root Agent** operational behavior. **CORE.md** (`skills/atdd-plan/CORE.md`) wins for **Notes Agent** operational behavior. Each is the runtime contract its respective agent reads.
2. **WHITEPAPER.md** is the design rationale for *both* layers (v2 since v0.10.0; v1 covered only the Root Agent). Edit it only at major-version bumps — never for status updates or transient decisions.
3. **ROADMAP.md** is the living tracker — current phase, smoke-test risks, deferrals, future work go here.

Before changing anything non-trivial: read ROADMAP.md for current state, then the relevant operations doc (PROTOCOL.md for Root Agent work, CORE.md for Notes Agent work) for the contract you're touching. The whitepaper explains *why* a rule exists; the operations docs are what agents read at runtime.

## Architecture (the parts you can't get from `ls`)

The orchestrator (Root) runs as a Claude Code session in a tmux window. From `roots:root-<id>`, it spawns child agents (test/impl/rebase) into a separate `ws-root-<id>` tmux session. The human only watches `roots`.

Three properties shape every file in `skills/atdd/`:

1. **Spawned agents don't inherit the plugin.** Child agents (test, impl, rebase) are launched as fresh `claude`/`claude -p` sessions with no plugin registry. Their entire initial context is `roles/<ROLE>_AGENT_ROLE.md` concatenated with a per-issue task block. That is why the role markdowns are long and fully self-contained — they are *the contract*, not documentation about the contract.

2. **The conversation is ephemeral, the disk is durable.** Root may be auto-compacted during multi-hour workflows. Every decision must be externalized to `.agent-tdd/<root-id>/` (state dir, gitignored) and to GitHub labels. SKILL.md and PROTOCOL.md both contain explicit "re-read at every phase boundary" instructions because Root cannot trust its conversation memory.

3. **One orchestrator per task per layer; entry-point skills are human-only.** All user-invocable skills have `disable-model-invocation: true` and `user-invocable: true`. As of v0.10.0 the plugin has five entry points across two layers:

   - **Root Agent layer:** `/agent-tdd:atdd` (real workflow); `/agent-tdd:atdd-compact` (session-handoff utility — checkpoints in-flight state and re-enters `/atdd` in resume mode in a fresh tmux window); `/agent-tdd:atdd-from-issue` (thin wrapper that pre-fills `$ARGUMENTS` from a planned SubIssue + its parent RootIssue, then delegates to `/atdd`).
   - **Notes Agent layer:** `/agent-tdd:fix` (planning entry for bug fixes; reads `skills/atdd-plan/CORE.md`). `atdd-feature` is deferred. `skills/atdd-plan/` itself is a shared library, not a user entry point.

   Never add a *parallel orchestrator at the same layer* — the wave-state model assumes one Root per task, and the planning model assumes one Notes Agent per project. Thin wrappers over the Root Agent (like `atdd-from-issue`), one-shot utilities that re-enter `/atdd` (like `atdd-compact`), and additional Notes-Agent entry points that share `atdd-plan/CORE.md` with a different lens (`feature` vs `fix`) are all fine when independently meaningful to invoke.

### Coordination model

- **Child → Root**: atomic status files (`.done`/`.failed`/`.aborted`/`.crashed`/`.paused`) under `.agent-tdd/<root-id>/wave-<N>/status/`. Root waits via a single `wave-watcher.sh` issued **once per wait with `run_in_background=true`** — this keeps Root idle (zero turns, zero tokens) until the watcher exits on terminal-threshold, first pause, or **30-min hard ceiling** (30 min wall-clock from invocation start — the safety net for silently dead child agents; on timeout Root runs a per-issue health checklist and may self-extend at most once per issue per wave before mandatory human escalation, see PROTOCOL §6.1). Background Bash does not inherit the foreground 10-min cap.
- **Root → Child**: `tmux send-keys` into the child's window.
- **Root → Human**: `tmux rename-window` + `notify-send`/`osascript`. Children **never** talk to the human directly.

### Wave gates

A wave does not advance until both:
- **Gate 1 (`agent-terminal`)**: every issue in the wave has a terminal status file. `.paused` is not terminal.
- **Gate 2 (`wave-merged`)**: all `.done` PRs are merged into the Root branch via the rebase-failure ladder (PROTOCOL §3.7, four rungs from "trivial auto-rebase" up to "human-required semantic conflict").

Wave N+1 fires only after Gate 2.

### Locked numerics (don't change without updating WHITEPAPER + PROTOCOL together)

- `max_waves` default: 10 (`meta.json`)
- `wave_size_cap` default: 5 parallel agents per wave
- Aborted-issue retry budget: hard-coded 1 per issue per wave
- Status-watcher poll interval: 10 s
- Wave-watcher hard ceiling: 30 min per invocation (wall-clock from invocation start → `EVENT=timeout`; not cumulative across the wave). On timeout, Root runs the §6.1 health checklist and may self-extend at most **once per issue per wave** if all signals green; otherwise escalates to human. Override the ceiling only via `WAVE_WATCHER_TIMEOUT_SEC` for tests.

## Editing rules specific to this repo

- **WHITEPAPER.md is the design rationale for both layers** (v2 since v0.10.0; v1 covered only the Root Agent). Edit it only at major-version bumps. Status changes, new risks, and resolved smoke-test issues belong in ROADMAP.md, not the whitepaper.
- **Role markdowns are agent prompts.** Edits to `roles/*.md` change the runtime behavior of spawned agents directly. They are not documentation. Test changes by reading them as if you were the agent receiving them cold.
- **Recipe scripts must remain idempotent and resumable** where reasonable — Root may re-invoke them after a crash. Each script begins with `set -euo pipefail` and routes progress to stderr; only intentional return values go to stdout (callers parse it).
- **Path discipline**: every recipe and prompt uses absolute paths. Worktrees see their own working tree, not the main repo's, and `.agent-tdd/<root-id>/` only exists in the main repo's working tree.
- **`${CLAUDE_SKILL_DIR}`** is the canonical reference to this skill's directory. Use it in PROTOCOL.md, role markdowns, and any new skill content — never hard-code paths.

## Plugin metadata

- `version` lives in `.claude-plugin/plugin.json`. Bump it when shipping behavior changes; the recent commit log uses `feat(atdd): ... (vX.Y.Z)` style.

## Common gotchas

- **Don't use `find /`** or scan filesystem-wide; this is a small repo, search from `.`.
- **Don't add a *parallel orchestrator at the same layer* entry point.** The wave-state model assumes one Root per task. Thin wrappers that delegate to atdd's PROTOCOL.md (the way `atdd-from-issue` does) and one-shot utilities that re-enter `/atdd` in resume mode (the way `atdd-compact` does) are fine; new Root Agent orchestrators are not. The Notes Agent (v0.10.0+) is **not** a parallel orchestrator — it is a different layer that hands off to the Root Agent layer via GitHub. Read the "single user-facing skill" entry in `~/.claude/projects/-home-m6-willy-agent-tdd/memory/MEMORY.md` for the full reasoning before adding any user-invocable skill.
- **`wave-watcher.sh` has a 30-min hard ceiling per invocation** (since v0.6.0; behavior refined in v0.6.1). Three exits: `EVENT=terminal` (Gate 1 reached), `EVENT=paused` (any `.paused` file appeared), `EVENT=timeout` (30 min wall-clock from invocation start without a terminal/paused event — note: the deadline is set once at start, NOT a "no event for 30 min" sliding window despite earlier doc claims). On `EVENT=timeout`, Root runs a per-issue health checklist (wrapper PID alive, worker `claude -p` PID alive, worker CPU advancing over a 30s sample, no failure marker); if all four signals green AND `<state-dir>/wave-<N>/extensions/issue-<X>` does not yet exist, Root silently re-issues the watcher (touching the marker to consume the one-time self-extension). Otherwise Root escalates per §1.5 P6 with a diagnostic table. The ceiling is per-invocation (across re-issues each gets a fresh budget); the self-extension cap is per-issue-per-wave, capping Root at 60 min wall-clock before mandatory human escalation. The earlier "indefinite-pause guarantee" was replaced because the watcher was hanging forever on dead agents (test/impl agents that crashed without writing a status file).
- **Impl agents launch with `--permission-mode auto`**, not `--dangerously-skip-permissions`. Project-level `.claude/settings.json` `permissions.ask` rules can otherwise intercept (see ROADMAP.md "Future Work" — `git push` blocked despite bypass flag).
- **Dashboard window is targeted by tmux window ID, not by `<session>:root-<id>`** (since v0.7.0). `init-root.sh` captures `#{window_id}` and persists it as `meta.json:root_tmux_window_id`; every `rename-window` / `set-window-option` in `notify-human.sh` and PROTOCOL.md uses that ID. Reason: tmux's `-t` resolution checks window-INDEX before name (man tmux: target-window), so a numeric window name (or a name Root has already overwritten with status text) silently became "the window currently at that index" — and indexes drift under `renumber-windows on` or when other windows are killed. Window IDs (`@N`) are stable for the window's lifetime. Do not reintroduce session-prefixed window targets.
