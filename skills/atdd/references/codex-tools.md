# Codex Tool Mapping

The Agent TDD skills and role markdowns use Claude Code tool names. When you run
under Codex, use the platform equivalent:

| Skill / role references | Codex equivalent |
|-------------------------|------------------|
| `Read`, `Write`, `Edit` (files) | Use your native file tools |
| `Bash` (run commands) | Use your native shell tools |
| `Skill` tool (invoke a skill) | Skills load natively — just follow the instructions; explicit invoke is `$skill-name` |
| `TodoWrite` (task tracking) | `update_plan` |
| `Agent` / `Task` tool (in-session subagent) | Not used by the wave model — see below |

## Child agents are separate processes, not in-session subagents

Agent TDD does **not** use Codex's in-session `spawn_agent`/`wait_agent` tools to
run test/impl agents. Each child agent is a **separate, non-interactive `codex
exec` process** launched into its own tmux window by the spawn recipes
(`recipes/spawn-test-agent.sh`, `recipes/launch-impl-agent.sh`). Coordination is
through atomic status files on disk, not through the harness's agent slots. So
there is **no `multi_agent` feature requirement** for the wave model — the Root
agent orchestrates through the shell and tmux.

The non-interactive child command is:

```bash
codex exec "<prompt>" --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check
```

`--dangerously-bypass-approvals-and-sandbox` is the Codex analog of Claude's
`--permission-mode bypassPermissions` / OpenCode's `--dangerously-skip-permissions`.
It is appropriate here because Agent TDD already runs the children inside an
isolated git worktree under the human's local repo.

## Environment the Root needs

Two variables must be visible to the Root's shell commands:

- `AGENT_TDD_CLI=codex` — selects the `codex exec` child form and the `codex`
  interactive binary in the spawn recipes.
- `CLAUDE_SKILL_DIR` — absolute path of this `atdd` skill directory, used by
  the markdown to locate recipes and sibling skills (`${CLAUDE_SKILL_DIR}/../...`).

Claude Code sets `CLAUDE_SKILL_DIR` per-skill automatically; the OpenCode plugin
sets both via its `shell.env` hook. Codex has no equivalent session hook, so the
`atdd` SKILL.md performs a **Step 0** that exports both before the first recipe
call (and the children inherit them when launched with
`-c shell_environment_policy.inherit=all`). See the "Step 0" block in
`../SKILL.md`.

## Environment detection (worktrees)

The spawn recipes resolve the main repo from any worktree with read-only git:

```bash
GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" 2>/dev/null && pwd -P)
```

`--git-common-dir` always points at `<main-repo>/.git`, so `.agent-tdd/<root-id>/`
lookups succeed even from inside a linked worktree.
