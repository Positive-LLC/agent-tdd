import { existsSync, mkdirSync, readFileSync, writeFileSync, readdirSync, chmodSync } from "node:fs"
import { join, dirname } from "node:path"
import { fileURLToPath } from "node:url"

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)

const SKILL_SRC = join(__dirname, "skills")

function copyDir(src, dest) {
  if (!existsSync(dest)) mkdirSync(dest, { recursive: true })
  for (const entry of readdirSync(src, { withFileTypes: true })) {
    const srcPath = join(src, entry.name)
    const destPath = join(dest, entry.name)
    if (entry.isDirectory()) {
      copyDir(srcPath, destPath)
    } else {
      writeFileSync(destPath, readFileSync(srcPath))
      if (entry.name.endsWith(".sh")) chmodSync(destPath, 0o755)
    }
  }
}

function ensureSkills(targetDir) {
  if (!existsSync(join(targetDir, "atdd", "SKILL.md"))) {
    copyDir(SKILL_SRC, targetDir)
  }
}

function ensureCommands(targetDir) {
  if (!existsSync(targetDir)) mkdirSync(targetDir, { recursive: true })

  for (const cmd of ["atdd", "atdd-demo", "atdd-compact"]) {
    const cmdFile = join(targetDir, `${cmd}.md`)
    if (!existsSync(cmdFile)) {
      const argHint = (cmd === "atdd-compact") ? "" : " $ARGUMENTS"
      const description = cmd === "atdd-compact"
        ? "Hand off an in-flight TDD workflow to a fresh agent session"
        : cmd === "atdd-demo"
          ? "Run a short TDD demo to see the wave-based workflow end-to-end"
          : "Run the Agent TDD wave-based workflow as Root"

      writeFileSync(cmdFile, `---
description: ${description}
agent: build
subtask: true
---
The human has initiated the Agent TDD workflow.

First, load the skill: use the skill tool with name "${cmd}". Follow SKILL.md exactly.

The human's specification:${argHint}
`)
    }
  }
}

export const AgentTDDPlugin = async ({ directory }) => {
  const opencodeDir = join(directory, ".opencode")
  const skillsDest = join(opencodeDir, "skills")
  const commandsDest = join(opencodeDir, "commands")

  ensureSkills(skillsDest)
  ensureCommands(commandsDest)

  // Point env at the source skill dir (npm-installed location). Recipes there
  // retain executable bits; the `.opencode/skills/` copy is for opencode's
  // command-discovery, not for execution.
  //
  // Note: CLAUDE_SKILL_DIR is pinned to the `atdd` skill dir for the whole
  // OpenCode session — Claude Code's harness sets it per-skill, but OpenCode
  // has no equivalent hook. The atdd-compact skill therefore references its
  // own files via the symmetric form `${CLAUDE_SKILL_DIR}/../atdd-compact/...`
  // so the same path resolves under both tools.
  const atddDir = join(SKILL_SRC, "atdd")

  return {
    "shell.env": async (_input, output) => {
      output.env.CLAUDE_SKILL_DIR = output.env.CLAUDE_SKILL_DIR || atddDir
      output.env.AGENT_TDD_CLI = output.env.AGENT_TDD_CLI || "opencode"
    }
  }
}
