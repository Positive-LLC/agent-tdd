import { existsSync, mkdirSync, readFileSync, writeFileSync, readdirSync, rmSync } from "node:fs"
import { join, dirname } from "node:path"
import { fileURLToPath } from "node:url"

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)

const SKILL_SRC = join(__dirname, "skills")

function readFrontmatter(file) {
  const text = readFileSync(file, "utf8")
  const m = text.match(/^---\n([\s\S]*?)\n---/)
  if (!m) return {}
  const fm = {}
  for (const line of m[1].split("\n")) {
    const kv = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/)
    if (kv) fm[kv[1]] = kv[2].trim()
  }
  return fm
}

function discoverEntrySkills() {
  const entries = []
  for (const dir of readdirSync(SKILL_SRC, { withFileTypes: true })) {
    if (!dir.isDirectory()) continue
    const skillFile = join(SKILL_SRC, dir.name, "SKILL.md")
    if (!existsSync(skillFile)) continue
    const fm = readFrontmatter(skillFile)
    if (fm["user-invocable"] !== "true") continue
    entries.push({
      name: fm.name || dir.name,
      description: fm.description || "Agent TDD command",
      takesArgs: !!fm["argument-hint"] && !/no arguments/i.test(fm["argument-hint"]),
    })
  }
  return entries
}

function ensureCommands(targetDir) {
  if (!existsSync(targetDir)) mkdirSync(targetDir, { recursive: true })

  const currentSkills = discoverEntrySkills()
  const currentNames = new Set(currentSkills.map(s => `${s.name}.md`))

  for (const entry of readdirSync(targetDir, { withFileTypes: true })) {
    if (!entry.isFile() || !entry.name.endsWith(".md")) continue
    if (currentNames.has(entry.name)) continue
    const content = readFileSync(join(targetDir, entry.name), "utf8")
    if (content.includes("Agent TDD workflow")) {
      rmSync(join(targetDir, entry.name))
    }
  }

  for (const skill of currentSkills) {
    const cmdFile = join(targetDir, `${skill.name}.md`)
    const argHint = skill.takesArgs ? " $ARGUMENTS" : ""
    const description = skill.description.replace(/\s+/g, " ").trim()
    writeFileSync(cmdFile, `---
description: ${description}
agent: build
subtask: true
---
The human has initiated the Agent TDD workflow.

First, load the skill: use the skill tool with name "${skill.name}". Follow SKILL.md exactly.

The human's specification:${argHint}
`)
  }
}

export const AgentTDDPlugin = async ({ directory }) => {
  const commandsDest = join(directory, ".opencode", "commands")
  ensureCommands(commandsDest)

  const atddDir = join(SKILL_SRC, "atdd")

  return {
    config: async (config) => {
      config.skills = config.skills || {}
      config.skills.paths = config.skills.paths || []
      if (!config.skills.paths.includes(SKILL_SRC)) {
        config.skills.paths.push(SKILL_SRC)
      }
    },

    "shell.env": async (_input, output) => {
      output.env.CLAUDE_SKILL_DIR = output.env.CLAUDE_SKILL_DIR || atddDir
      output.env.AGENT_TDD_CLI = output.env.AGENT_TDD_CLI || "opencode"
    }
  }
}
