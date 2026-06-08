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
run test/impl agents. Each child agent is a **separate `codex` process**
launched into its own tmux window by the spawn recipes. Test **and** impl agents
run the bare `codex` binary **interactively** — the role + task prompt is pasted
into the pane via tmux buffer (`recipes/spawn-test-agent.sh`,
`recipes/spawn-impl-agent.sh`; the impl session is supervised by
`recipes/launch-impl-agent.sh`). Coordination is through atomic status files on
disk, not through the harness's agent slots. So there is **no `multi_agent`
feature requirement** for the wave model — the Root agent orchestrates through
the shell and tmux.

Only the **rebase agent** (PROTOCOL §3.7 rung 2, spawned by Root directly) still
uses the non-interactive child form:

```bash
codex exec "<prompt>" --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check
```

`--dangerously-bypass-approvals-and-sandbox` is the Codex analog of Claude's
`--permission-mode bypassPermissions` / OpenCode's `--dangerously-skip-permissions`.
It is appropriate here because Agent TDD already runs the children inside an
isolated git worktree under the human's local repo. The interactive test/impl
sessions launch bare (no flags) — Codex's interactive approval posture under
tmux driving is unverified; see ROADMAP Smoke-Test Risks #6 and #7.

## Environment the Root needs

Two variables must be visible to the Root's shell commands:

- `AGENT_TDD_CLI=codex` — selects the `codex` interactive binary for test/impl
  agents (and the `codex exec` form for rebase agents) in the spawn recipes.
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

`--git-common-dir` always points at `<main-repo>/.git`, so `.atdd/<root-id>/`
lookups succeed even from inside a linked worktree.
