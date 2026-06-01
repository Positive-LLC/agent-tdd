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

// Minimal YAML-frontmatter reader for our SKILL.md files (single-line `key: value`
// pairs between the leading `---` fences). Good enough for the keys we read here:
// name, description, user-invocable, argument-hint. Returns {} if no frontmatter.
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

// Discover every user-invocable entry skill under skills/ by reading each
// SKILL.md's frontmatter. This replaces a hard-coded list so new entry skills
// (e.g. atdd-fix, atdd-from-issue) are picked up automatically and retired ones
// (atdd-demo) drop out on their own. atdd-plan is a shared library with no
// SKILL.md, so it is naturally skipped.
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
      // "(no arguments)" hint → command takes no $ARGUMENTS tail.
      takesArgs: !!fm["argument-hint"] && !/no arguments/i.test(fm["argument-hint"]),
    })
  }
  return entries
}

function ensureCommands(targetDir) {
  if (!existsSync(targetDir)) mkdirSync(targetDir, { recursive: true })

  for (const skill of discoverEntrySkills()) {
    const cmdFile = join(targetDir, `${skill.name}.md`)
    if (existsSync(cmdFile)) continue
    const argHint = skill.takesArgs ? " $ARGUMENTS" : ""
    // OpenCode descriptions are a single line; collapse any whitespace and trim.
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
