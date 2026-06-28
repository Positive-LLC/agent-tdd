# Phase C — work doc (the self-maintaining Stack in the `agent-tdd` plugin)

**This is the working document for finishing Phase C.** Read it first — it states the current
design, what is built, what is left, and the decisions in force. Keep it current: when a piece
lands, update its row and its section.

## The vision

ATDD's Stack is **invisible — it lives "under the hood."** As a human builds software with the
coding agent, the Stack (Layers / Interfaces / Processes / Pipelines) **builds itself in the
background**, automatically. There is **no user-side initialization** — no setup step the human
runs first. The map is a **by-product of doing the work**.

The heart of Phase C is **the sharpest moment**: an agent understands a piece of code best at
the instant it finishes it, so that is when it records + verifies the boxes it touched —
automatically, as a mandatory end-of-task step. The sum of those tiny, peak-accuracy updates
**is** the self-maintaining map. (`../atdd-cli/PHASE_2.md` §8: *"The map maintains itself."*)

## Status at a glance

Phase C is the **last** phase of the `atdd` "Stack" project, built **here** in `agent-tdd`
(shell + markdown). Two pieces:

| # | Piece | State |
|---|---|---|
| **C1** | Bootstrap **LSP surfacing** (advisory, automatic) | ✅ Built + reviewed on `v2`. Not yet smoke-tested in a real bootstrap — the agent/human provisioning half is unproven (ROADMAP Smoke-Test Risk #9). |
| **C2** | Mandatory, thorough **end-of-task zoom-in** (the sharpest moment) | ⬜ Not started — **the core of Phase C**. |

## The big picture (zero-context primer)

Two sibling repos under `/home/m6/willy/`, both on branch **`v2`**:

- **`atdd-cli`** (Rust) — a local tool (daemon + SQLite + CLI) that holds the work-items and a
  queryable **architecture model**: a "Stack" of **Layers / Interfaces / Processes / Pipelines**,
  fact-checked against real code by an **`lsp`** (a language server, e.g. rust-analyzer) the
  daemon drives. The whole value is the **determinism line**: the LLM declares meaning, the tool
  verifies against facts, **disagreement = signal**.
- **`agent-tdd`** (THIS repo; shell + markdown, runs on tmux) — the **plugin**: a wave-based,
  four-agent TDD orchestrator (Notes / Root / Test / Impl) that drives `atdd` via the CLI.
  **Phase C is built HERE.**

The **LSP is global and cross-cutting**: one facility verifies every code-backed Layer and
Interface, at every level. It is not a layer. The meaning-vs-fact boundary is the determinism
line (`../atdd-cli/STACK.md` §6–§7).

`atdd-cli` carries three built phases on `v2`:
- **Phase A** — the stack model (`layer`/`interface`/`process`/`pipeline` verbs,
  write-time cycle guard, `layer at` + work-item link bridge, file-exists `stack verify`).
- **Phase B** — the determinism line (`lsp` registry, `async-lsp` client + warm-server
  supervisor, anchor resolver moniker→name+kind+container fallback, semantic `stack verify` +
  `stack drift`, version-bump handling, readiness gate, structural false-drift guard). A false
  "deleted" signal is structurally impossible — the worst case is an honest "unverifiable".
- **Phase D** — read-side navigation: `stack roots` (top Layers) + `stack zoom <id>` (one
  node's **1-level** layer / interface / process slice; every stub carries `confidence` +
  `drift` and re-addressable `id`, never linked issues). The old whole-stack `stack graph`
  CLI echo is **removed** — agents navigate bite-by-bite and can never pull the whole graph;
  the dashboard keeps the bird's-eye in-process. (`../atdd-cli/PHASE_2.md` "Phase D".) This is
  the **consumption path** the C2 end-of-task zoom-in feeds and that a reader walks instead of
  re-reading the code.

## The authoritative spec — READ IT before C2

- **`../atdd-cli/PHASE_2.md` §8 (Phase C)** — the authoritative spec (C1/C2, milestones, exit
  gate); it points back at this work doc.
- `../atdd-cli/STACK.md` — the model vocabulary (Layer / Interface / Process / Pipeline) and the
  global, cross-cutting verification model (§6–§7).
- `../atdd-cli/PHASE_2.md` §1–§5 — how the tool works.
- The `atdd` CLI is self-documenting — **run `atdd --help` and `atdd <verb> --help`**. C2 verbs:
  `atdd layer add/edit/list/show/at/link`, `atdd interface add/list/show/edit`, `atdd process
  add/group/list/show/edit`, `atdd stack verify/drift`, `atdd lsp register/list`. Everything is
  scoped by a global `atdd --project <slug>`.

## C1 — bootstrap LSP surfacing

**What it does.** At plugin bootstrap (where the tmux env check + `skills/ensure-atdd.sh` run),
detect the repo's symbol-precise languages by file pattern, cross-check `atdd lsp list`, and
**surface (advisory — never blocks)** any detected language with no working `lsp`. The agent
then provisions: detect → ask the human which language server → install → (`atdd repo register`
if needed) → `atdd lsp register <path>`. **Registered == active** — a registered `lsp` IS the
coverage signal; there is no separate `require`/`check`.

**Where it lives:**
- `skills/lsp-surface.sh` — a **top-level shared recipe** (sibling of `ensure-atdd.sh`, NOT under
  a `recipes/` dir). Detects languages, reads each `atdd lsp list` row's `status`
  (`ok`/`missing`/`not_executable`), emits a gap JSON `{repo, repo_registered, detected, covered,
  missing}`. The repo slug is **never null** (`--repo` → git origin → manifest `home_repo` →
  atdd registry by path → `local/<folder>`); reports `repo_registered` so the agent runs `atdd
  repo register` first when false.
- Wired into **both** bootstrap layers (hybrid: recipe = deterministic floor, agent refines +
  provisions): Root `skills/atdd/SKILL.md` (bootstrap step 0); Notes `skills/atdd-plan/CORE.md`
  (§2) + `skills/atdd-fix/SKILL.md`.
- **Advisory — never blocks** (D6: registered == active).

**Tested:** hermetic no-LLM gate in `skills/atdd-plan/recipes/tests/run.sh` (`== lsp-surface ==`
with a real `atdd` under a temp `ATDD_HOME`, no language server + a `== bootstrap wiring ==`
grep gate). Design reasoning: `docs/superpowers/plans/2026-06-18-lsp-surfacing.md`.

**Not yet verified (ROADMAP Smoke-Test Risk #9):** the agent/human half — pick a server,
install, `atdd repo register`/`atdd lsp register` under the right slug, confirm it's visible to
`atdd stack verify`; the `local/<folder>` slug fallback in the Root's no-origin/no-manifest case;
the registry path-match (symlinked `/tmp`); over-detection noise (no `node_modules`/`vendor`/
`target` prune).

## C2 — mandatory, thorough end-of-task zoom-in (the core)

**This is the self-maintaining loop — the whole point of Phase C.** It is the mechanism that
exploits **the sharpest moment**.

**Spec (PHASE_2.md §8 / milestone C2).** After a TDD agent finishes — Impl after `record-green`,
Root after `integrate`/`issue-done` — it MUST update the Stack for the boxes it touched
(`layer`/`interface`/`process` verbs + `layer link --issue`) and run `stack verify`, at the
moment its understanding is sharpest. The map is **thorough** (a rich map, not a light touch),
and the step is **un-skippable**. The map grows purely from these updates.

**Open design questions (resolve WITH the human before building):**
1. **Where exactly it hooks in** — Impl after `record-green`? Root after `integrate`? both?
2. **How to make it un-skippable** — a coordination gate? a required terminal recipe step? a
   status-file check (no `.done` until the zoom-in verbs ran)?
3. **What "thorough" means per task** — which boxes an agent must declare — without over-taxing
   every task.

**Likely shape:** a recipe `skills/atdd-plan/recipes/stack-zoom.sh`; bake the step into the role
docs (`IMPL`, Root/`PROTOCOL.md`, `ORCHESTRATE.md`); the no-LLM coordination gate asserts the
verbs fire and `stack verify` is called.

## Locked decisions to honor

- **No user-side initialization.** The Stack is invisible / under-the-hood and self-maintains
  from the sharpest-moment zoom-ins. The human never runs a setup or init pass.
- **The LSP is global + cross-cutting.** One facility verifies every code-backed box at every
  level. It is not a layer. (`../atdd-cli/STACK.md` §7.)
- The end-of-task zoom-in (C2) is **mandatory, thorough, and un-skippable**.
- **D6:** registered == active — a registered `lsp` is the coverage signal (no separate
  `require`/`check`); bootstrap lsp surfacing is **advisory, never project-blocking**.
- **One Stack per project**; anchors keyed moniker → (name + kind + container) fallback; the CLI
  verb structure is **flat** (`atdd layer add`, not grouped).
- **Plan altitude** = design-whitepaper + phased milestones (like `PHASE_2.md`); expand each
  milestone into bite-sized TDD tasks only at execution time.

## Where to build it + conventions / footguns

Explore the layout before touching it (`skills/` tree — esp. `skills/atdd-plan/recipes/` and the
entry skills; role docs `IMPL`/`TEST`/`ROOT`/`PROTOCOL`/`ORCHESTRATE`; where the bootstrap env
check + `skills/ensure-atdd.sh` live; the spawn scripts; how recipes are tested). Footguns:

- Recipes run **zero `gh`** in the inner flow; gate scripts set their own hermetic `ATDD_HOME`.
- **`env -u ATDD_PROJECT`** is a known footgun — a set `$ATDD_PROJECT` breaks the gates.
- Recipes must stay **idempotent + resumable** (`set -euo pipefail`; progress → stderr; only
  intentional return values → stdout). **Absolute paths everywhere.** Use `${CLAUDE_SKILL_DIR}`.
- **Tooling:** the `lsp`/`stack` verbs need a v2 `atdd-cli` build. Iterate against a local build
  with **`make use-dev-atdd`** (symlinks the installed `atdd` at `../atdd-cli/target/release/atdd`);
  `make use-release-atdd` restores; `make atdd-status` shows which is active (see this repo's
  `CLAUDE.md` "versioning").

## How to test Phase C without a live LLM

Extend the hermetic gate — `skills/atdd-plan/recipes/tests/run.sh` — same pattern as C1
(`== lsp-surface ==` + `== bootstrap wiring ==`). Drive the **real built `atdd`** under a temp
`ATDD_HOME`, no LLM. For C2: assert the zoom-in verbs fire and `stack verify` is called on the
touched boxes. (PHASE_2.md §9 calls this the Phase-C "coordination gate".)

## Process for C2

1. **`brainstorming`** the open design questions above **with the human** (do not pre-decide).
2. **`writing-plans`** — extend this doc (or a piece plan under `docs/superpowers/plans/`).
3. **Stop for human review** of the plan before implementing.
4. Implement TDD; review; then update C2's row + section here, and `ROADMAP.md` +
   `../atdd-cli/PHASE_2.md` §8.

## Logistics

- Both repos on **`v2`**. Phase A + B (atdd-cli) and C1 (here) are committed and pushed on `v2`,
  not merged to `main`.
- **Do not cut releases or merge to `main`.** Phase C work happens here on `v2` (or a sub-branch).
