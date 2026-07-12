import { existsSync, mkdirSync, readFileSync, writeFileSync, readdirSync, rmSync, openSync } from "node:fs"
import { join, dirname } from "node:path"
import { fileURLToPath } from "node:url"
import { spawn } from "node:child_process"
import { tmpdir } from "node:os"
import { randomBytes } from "node:crypto"
import { tool } from "@opencode-ai/plugin"

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

export const AgentTDDPlugin = async ({ directory, client }) => {
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
      output.env.AGENT_TDD_CLI = output.env.AGENT_TDD_CLI || "opencode"  // alt: claude, codex, deepcode
    },

    tool: {
      bash_bg: tool({
        description: "Run a shell command in the background (detached). Returns immediately with a job ID and output file path. When the command exits, its stdout is automatically injected into this session, waking the agent — equivalent to Claude Code's Bash(run_in_background=true).",
        args: {
          command: tool.schema.string().describe("The shell command to run"),
          timeoutSec: tool.schema.number().optional().describe("Max seconds before SIGKILL (default: 1860 = 31 min)"),
        },
        async execute(args, ctx) {
          const jobId = randomBytes(4).toString("hex")
          const outFile = join(tmpdir(), `bash-bg-${jobId}.out`)
          const timeoutSec = args.timeoutSec || 1860
          const sessionId = ctx.sessionID

          const fd = openSync(outFile, "w")
          const child = spawn("bash", ["-c", args.command], {
            detached: true,
            stdio: ["ignore", fd, fd],
          })
          child.unref()

          const pid = child.pid
          const timer = setTimeout(() => {
            try { process.kill(-pid, "SIGKILL") } catch {}
          }, timeoutSec * 1000)

          child.on("exit", async (code) => {
            clearTimeout(timer)
            let output = ""
            try { output = readFileSync(outFile, "utf8") } catch {}
            try {
              await client.session.promptAsync({
                path: { id: sessionId },
                body: {
                  parts: [{ type: "text", text: `<background-result job="${jobId}" exit-code="${code}">\n${output}\n</background-result>` }],
                },
              })
            } catch {}
          })

          return `Background job started.\nJob ID: ${jobId}\nPID: ${pid}\nOutput file: ${outFile}\nTimeout: ${timeoutSec}s`
        },
      }),

      bash_bg_result: tool({
        description: "Read the output file of a completed background job (bash_bg).",
        args: {
          outputFile: tool.schema.string().describe("Path to the output file from bash_bg"),
        },
        async execute(args) {
          try {
            return readFileSync(args.outputFile, "utf8")
          } catch (e) {
            return `Error reading ${args.outputFile}: ${e.message}`
          }
        },
      }),
    },
  }
}
