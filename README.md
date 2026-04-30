# agent-tdd

A Claude Code plugin for human-agent co-authored TDD. You spec the test cases out loud; an orchestrator agent writes red tests, implements them, opens PRs, and merges waves of work in parallel.

You only ever talk to one agent. It runs the show.

---

## Prerequisites

- **Claude Code** installed and authenticated.
- **tmux** ≥ 3.0.
- **`gh`** (GitHub CLI), authenticated for the target repo.
- **git** ≥ 2.5 (worktree support).
- A repo whose CI is reachable via `gh pr checks --watch`.

## Install

Inside Claude Code:

```
/plugin marketplace add hn12404988/emacs_setup
/plugin install agent-tdd@willie-plugins
```

## Use

1. In any tmux window, launch Claude Code.
2. Invoke the workflow:
   ```
   /agent-tdd:atdd <describe new feature or bug to the agent>
   ```
3. The agent discusses the spec with you (Wave 0). When you're aligned, say **"go"**.
4. From there, the agent is in autopilot. The window title updates with live status, and you'll only be pinged when human input is genuinely needed.

## Safety notes

- Impl agents run with `--permission-mode bypassPermissions` for non-interactive autonomy. Use only in trusted local repos.
- The workflow uses GitHub API heavily. Watch your 5000/hr authenticated rate limit on long workflows.
- Each parallel agent uses its own `git worktree`. For very large repos, N parallel agents ≈ N× working-tree disk.
- If the orchestrator process dies mid-workflow, you'll need to re-launch it manually — there is no automatic crash recovery in v1.

## Learn more

- **Design rationale** → [WHITEPAPER.md](WHITEPAPER.md)
- **Operational spec** → [skills/atdd/PROTOCOL.md](skills/atdd/PROTOCOL.md)
- **Status, known risks, future work** → [ROADMAP.md](ROADMAP.md)
