# agent-tdd

A plugin for human-agent co-authored TDD. You spec the test cases out loud; an orchestrator agent writes red tests, implements them, opens PRs, and merges waves of work in parallel.

You only ever talk to one agent. It runs the show.

One skills source (`./skills/`) runs on three coding-agent hosts — **Claude Code**, **OpenCode**, and **Codex** — with a small per-host manifest. There is no build step (the pattern is borrowed from [obra/superpowers](https://github.com/obra/superpowers)).

---

## Host support

| Host | Manifest | Invoke as | Status |
|------|----------|-----------|--------|
| Claude Code | `.claude-plugin/plugin.json` | `/agent-tdd:atdd` | Stable |
| OpenCode | `package.json` → `index.js` (auto-generates `.opencode/commands/`) | `/atdd` | Supported |
| Codex | `.codex-plugin/plugin.json` (+ marketplace) | `$atdd` | **Experimental** (see ROADMAP) |

The child test/impl agents run **interactive** host-CLI sessions in their own tmux windows, selected per host via `AGENT_TDD_CLI` (`claude` / `opencode` / `codex`); only the one-shot rebase agent is headless (`claude -p` / `opencode run` / `codex exec`).

## Prerequisites

- One of: **Claude Code**, **OpenCode**, or **Codex**, installed and authenticated.
- **tmux** ≥ 3.0.
- **`gh`** (GitHub CLI), authenticated for the target repo.
- **git** ≥ 2.5 (worktree support).
- A repo whose CI is reachable via `gh pr checks --watch`.

## Install

### Claude Code

```
/plugin marketplace add hn12404988/emacs_setup
/plugin install agent-tdd@willie-plugins
```

### OpenCode

Install the npm package as a plugin, then start OpenCode in your project. The plugin self-installs: on first load it copies `skills/` into `.opencode/skills/`, generates a `/atdd*` command per entry skill into `.opencode/commands/`, and sets `CLAUDE_SKILL_DIR` + `AGENT_TDD_CLI=opencode`.

```jsonc
// opencode.json
{ "plugin": ["@positivegrid/agent-tdd"] }
```

### Codex (experimental)

Add the shipped marketplace and install the plugin:

```
# point Codex at the repo's .codex-plugin/marketplace.json (adjust the path),
# then in Codex:
/plugins        # find "agent-tdd" → Install
```

Codex has no per-session env hook, so the `atdd` skill's **Step 0** resolves `CLAUDE_SKILL_DIR` and exports `AGENT_TDD_CLI=codex` on first run. If the probe can't find the install path, the agent will ask you for it. See `skills/atdd/references/codex-tools.md`.

## Use

1. In any tmux window, launch your host CLI (`claude` / `opencode` / `codex`).
2. Invoke the workflow (use the form for your host):
   ```
   /agent-tdd:atdd <describe new feature or bug>   # Claude Code
   /atdd <describe new feature or bug>              # OpenCode
   $atdd <describe new feature or bug>              # Codex
   ```
3. The agent discusses the spec with you (Wave 0). When you're aligned, say **"go"**.
4. From there, the agent is in autopilot. The window title updates with live status, and you'll only be pinged when human input is genuinely needed.

## Safety notes

- Impl agents run an interactive `claude --permission-mode bypassPermissions` session (the OpenCode/Codex interactive permission posture is pending smoke verification — see ROADMAP). Use only in trusted local repos.
- The workflow uses GitHub API heavily. Watch your 5000/hr authenticated rate limit on long workflows.
- Each parallel agent uses its own `git worktree`. For very large repos, N parallel agents ≈ N× working-tree disk.
- If the orchestrator process dies mid-workflow, you'll need to re-launch it manually — there is no automatic crash recovery in v1.

## Learn more

- **Design rationale** → [WHITEPAPER.md](WHITEPAPER.md)
- **Operational spec** → [skills/atdd/PROTOCOL.md](skills/atdd/PROTOCOL.md)
- **Status, known risks, future work** → [ROADMAP.md](ROADMAP.md)
