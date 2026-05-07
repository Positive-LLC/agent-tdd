# Plan: Hybrid Claude Code + OpenCode Plugin Support

## Overview

Make `agent-tdd` work as both a Claude Code plugin (existing) and an OpenCode plugin (new), using the same `skills/` content. The user chooses the CLI engine via `AGENT_TDD_CLI`, and the OpenCode plugin self-installs skills + commands on first load.

## User experience

### Claude Code (unchanged)
```bash
cd my-project
claude --plugin-dir /path/to/agent-tdd
/agent-tdd:atdd Add user authentication
```

### OpenCode (new)
```bash
cd my-project
opencode plugin agent-tdd     # one-time install from npm
opencode
/atdd Add user authentication
```

---

## Phase 1: Environment-aware variable layer

### 1.1 `AGENT_TDD_CLI` env var
- **Default:** `claude`
- **Values:** `claude` | `opencode`
- **Used in:** 3 recipe scripts that invoke the CLI
- **Purpose:** Controls which binary is spawned for child agents

### 1.2 `AGENT_TDD_DIR` env var
- **Purpose:** Replaces `${CLAUDE_SKILL_DIR}` (Claude Code-only variable)
- **Set by:** Shell wrapper / opencode `shell.env` hook
- **Used in:** SKILL.md, PROTOCOL.md, 3 role markdowns, atdd-compact SKILL.md, checkpoint-comment.md
- **Fallback logic (in recipes):**
  ```bash
  : ${AGENT_TDD_DIR:="${CLAUDE_SKILL_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"}
  ```

### 1.3 Flag mapping
In `launch-impl-agent.sh`:

| Flag | Claude Code | OpenCode |
|------|-------------|----------|
| Skip permissions | `--permission-mode bypassPermissions` | `--dangerously-skip-permissions` |
| Non-interactive | `claude -p "..."` | `opencode run "..."` |

---

## Phase 2: Recipe script changes

### 2.1 `skills/atdd/recipes/launch-impl-agent.sh`
- Log filenames: `claude.stdout` → `agent.stdout` (tool-agnostic)
- CLI invocation parameterized via `AGENT_TDD_CLI`
- Flag mapping based on `AGENT_TDD_CLI`
- Error messages genericized

### 2.2 `skills/atdd/recipes/spawn-test-agent.sh`
- `tmux send-keys 'claude'` → `"${AGENT_TDD_CLI}"`
- Log messages updated

### 2.3 `skills/atdd-compact/recipes/spawn-resume-window.sh`
- `tmux send-keys 'claude'` → `"${AGENT_TDD_CLI}"`
- Log messages updated

---

## Phase 3: Markdown file changes

All `${CLAUDE_SKILL_DIR}/` references → `${AGENT_TDD_DIR}/` in:
- `skills/atdd/SKILL.md` (~25 occurrences)
- `skills/atdd/PROTOCOL.md` (~20 occurrences + health checks)
- `skills/atdd/roles/IMPL_AGENT_ROLE.md` (prose updates)
- `skills/atdd/roles/TEST_AGENT_ROLE.md` (prose updates)
- `skills/atdd/roles/REBASE_AGENT_ROLE.md` (prose updates)
- `skills/atdd-compact/SKILL.md`
- `skills/atdd-compact/templates/checkpoint-comment.md`
- `skills/atdd-demo/SKILL.md`

### PROTOCOL.md health checks
- `pgrep -af "claude -p"` → use `CLI_CMD` variable
- Prose references to "claude -p" → generic "non-interactive agent"

### SKILL.md prose
- "launch claude" → "launch agent CLI"

---

## Phase 4: OpenCode plugin + npm packaging (new files)

### 4.1 `package.json` — npm package config
### 4.2 `index.js` — OpenCode plugin entry (self-installing bootstrap)
### 4.3 `.claude/skills/` → `../skills/` symlink (for opencode discovery in this repo)

---

## Phase 5: Verification

### Syntax checks
```bash
bash -n skills/atdd/recipes/*.sh
bash -n skills/atdd-compact/recipes/*.sh
```

### Stale reference scan
```bash
rg '\$\{CLAUDE_SKILL_DIR\}' skills/ --include '*.md' --include '*.sh'
```

---

## Files NOT changed

| File | Reason |
|------|--------|
| `.claude-plugin/plugin.json` | Works for both tools |
| `.claude/settings.local.json` | Claude Code only |
| `CLAUDE.md` | Dev doc, no runtime impact |
| `WHITEPAPER.md` | Immutable v1 design doc |
| `ROADMAP.md` | Updated separately |
| `templates/ISSUE_TEMPLATE.md` | No tool-specific references |
| `init-root.sh`, `terminate-root.sh`, `wave-watcher.sh`, `wave-end-cleanup.sh`, `notify-human.sh`, `spawn-impl-agent.sh` | No CLI invocations |

---

## Rollback safety

- Claude Code users: set `AGENT_TDD_CLI=claude` (or leave unset — defaults to `claude`)
- All `${AGENT_TDD_DIR}` refs fall back to `${CLAUDE_SKILL_DIR}` at recipe level
- `.claude-plugin/plugin.json` unchanged — Claude Code plugin still loads identically
