# agent-tdd

A Claude Code plugin for human-agent co-authored TDD. You spec the test cases out loud; an orchestrator agent handles the rest — writing red tests, implementing them, opening PRs, and merging waves of work in parallel.

You only ever talk to one agent. It runs the show.

---

## Prerequisites

- **Claude Code** installed and authenticated.
- **tmux** ≥ 3.0.
- **`gh`** (GitHub CLI), authenticated for the target repo.
- **git** ≥ 2.5 (worktree support).
- **`notify-send`** (Linux) or `osascript` (macOS) for OS-level notifications. Optional.
- A repo whose CI is reachable via `gh pr checks --watch`.

## Install

### Local (single session)

```bash
claude --plugin-dir /path/to/agent-tdd
```

### Persistent

Inside Claude Code:

```
/plugin install /path/to/agent-tdd
```

(See [Claude Code plugin docs](https://code.claude.com/docs/en/plugins) for marketplace-based installation.)

## Quick start

1. Start a tmux session called `roots` and open a window inside it:
   ```bash
   tmux new-session -d -s roots
   tmux new-window -t roots: -n root-1
   tmux attach -t roots:root-1
   ```
2. Launch Claude Code with the plugin loaded in that window:
   ```bash
   claude --plugin-dir /path/to/agent-tdd
   ```
3. Invoke the workflow:
   ```
   /agent-tdd:atdd Add JWT-based authentication to /api/login
   ```
4. The agent will discuss the spec with you (Wave 0). When you're aligned, say **"go"**.
5. From this point, the agent is in autopilot. Watch the dashboard window's title for live status. The agent only pings you when it genuinely needs human input — `notify-send` will pop up and the window title will turn red.

## What you'll see

The `roots` session is your dashboard. The agent's own workspace lives in a separate `ws-root-1` session (noisy — you don't usually need to watch it). The dashboard window title updates as the workflow progresses:

```
root-1: wave-1 (3 active)
root-1: wave-1 ⏸ paused (#5) — human input needed
root-1: wave-1 merging…
root-1: wave-1 done
root-1: ALL DONE ✅
```

## Safety notes

- Impl agents run with `--dangerously-skip-permissions` for non-interactive autonomy. Use only in trusted local repos. Do **not** run against repos whose build steps would expose secrets.
- The workflow uses GitHub API heavily (issue creation, label updates, CI polling). Watch your 5000/hr authenticated rate limit on long workflows.
- Each parallel agent is a separate Claude session. Highly parallel waves on small accounts may rate-limit.
- Each parallel agent uses its own `git worktree`. For very large repos, N parallel agents ≈ N× working-tree disk.
- If the orchestrator process dies mid-workflow, you'll need to re-launch it manually — there is no automatic crash recovery in v1.

## Learn more

- **Design rationale** → [WHITEPAPER.md](WHITEPAPER.md)
- **Operational spec** (what the agent actually does) → [skills/atdd/PROTOCOL.md](skills/atdd/PROTOCOL.md)
- **Status, known risks, future work** → [ROADMAP.md](ROADMAP.md)
