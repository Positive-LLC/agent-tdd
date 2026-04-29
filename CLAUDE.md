# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **Claude Code plugin** — not application code. It ships shell scripts and markdown that orchestrate a wave-based human-agent TDD workflow. The plugin is invoked from another repo via `claude --plugin-dir /path/to/agent-tdd`, and inside that session the human types `/agent-tdd:atdd <spec>` to start the workflow.

There are **no build/lint/test commands**. Validation is:

- `bash -n skills/atdd/recipes/*.sh` — syntax-check shell scripts (the only "compile" step).
- Manual end-to-end smoke tests in a throwaway repo (see ROADMAP.md "Smoke-Test Risks").

## Source-of-truth hierarchy

When the three documents disagree, this is the precedence:

1. **PROTOCOL.md** wins for operational behavior (what Root actually does).
2. **WHITEPAPER.md** is the immutable v1 design rationale — do not edit it for status updates or new decisions.
3. **ROADMAP.md** is the living tracker — current phase, smoke-test risks, deferrals, future work go here.

Before changing anything non-trivial: read ROADMAP.md for current state, then PROTOCOL.md for the contract you're touching. The whitepaper explains *why* a rule exists; the protocol is what Root reads at runtime.

## Architecture (the parts you can't get from `ls`)

The orchestrator (Root) runs as a Claude Code session in a tmux window. From `roots:root-<id>`, it spawns child agents (test/impl/rebase) into a separate `ws-root-<id>` tmux session. The human only watches `roots`.

Three properties shape every file in `skills/atdd/`:

1. **Spawned agents don't inherit the plugin.** Child agents (test, impl, rebase) are launched as fresh `claude`/`claude -p` sessions with no plugin registry. Their entire initial context is `roles/<ROLE>_AGENT_ROLE.md` concatenated with a per-issue task block. That is why the role markdowns are long and fully self-contained — they are *the contract*, not documentation about the contract.

2. **The conversation is ephemeral, the disk is durable.** Root may be auto-compacted during multi-hour workflows. Every decision must be externalized to `.agent-tdd/<root-id>/` (state dir, gitignored) and to GitHub labels. SKILL.md and PROTOCOL.md both contain explicit "re-read at every phase boundary" instructions because Root cannot trust its conversation memory.

3. **Single user-facing skill, human-only.** `skills/atdd/SKILL.md` has `disable-model-invocation: true` and `user-invocable: true`. The plugin has exactly one entry point (`/agent-tdd:atdd`) — never add more skills as parallel entry points; the wave-state model assumes one orchestrator per task.

### Coordination model

- **Child → Root**: atomic status files (`.done`/`.failed`/`.aborted`/`.crashed`/`.paused`) under `.agent-tdd/<root-id>/wave-<N>/status/`. Root waits via a single `wave-watcher.sh` issued **once per wave with `run_in_background=true`** — this keeps Root idle (zero turns, zero tokens) until the watcher exits on terminal-threshold or first pause. Background Bash does not inherit the foreground 10-min cap.
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
- Stuck-agent heartbeat threshold: 30 min

## Editing rules specific to this repo

- **WHITEPAPER.md is immutable v1 design.** Status changes, new risks, and resolved smoke-test issues belong in ROADMAP.md, not the whitepaper.
- **Role markdowns are agent prompts.** Edits to `roles/*.md` change the runtime behavior of spawned agents directly. They are not documentation. Test changes by reading them as if you were the agent receiving them cold.
- **Recipe scripts must remain idempotent and resumable** where reasonable — Root may re-invoke them after a crash. Each script begins with `set -euo pipefail` and routes progress to stderr; only intentional return values go to stdout (callers parse it).
- **Path discipline**: every recipe and prompt uses absolute paths. Worktrees see their own working tree, not the main repo's, and `.agent-tdd/<root-id>/` only exists in the main repo's working tree.
- **`${CLAUDE_SKILL_DIR}`** is the canonical reference to this skill's directory. Use it in PROTOCOL.md, role markdowns, and any new skill content — never hard-code paths.

## Plugin metadata

- `version` lives in `.claude-plugin/plugin.json`. Bump it when shipping behavior changes; the recent commit log uses `feat(atdd): ... (vX.Y.Z)` style.

## Common gotchas

- **Don't use `find /`** or scan filesystem-wide; this is a small repo, search from `.`.
- **Don't add a second user-facing skill** without first reading the "single user-facing skill" entry in `~/.claude/projects/-home-m6-willy-agent-tdd/memory/MEMORY.md` — the orchestrator wave model assumes one entry point per task.
- **Don't introduce timeouts in `wave-watcher.sh`.** It is intentionally untimed; pause-on-paused-file + terminal-count-threshold are the only exits. Adding a timeout breaks the indefinite-pause guarantee.
- **Impl agents launch with `--permission-mode auto`**, not `--dangerously-skip-permissions`. Project-level `.claude/settings.json` `permissions.ask` rules can otherwise intercept (see ROADMAP.md "Future Work" — `git push` blocked despite bypass flag).
