# Phase C — work doc (the self-maintaining loop in the `agent-tdd` plugin)

**This is the LIVING work document for finishing Phase C.** Read it first — it tells a
fresh, low-context session the current state, what is done, what is left, and the
decisions already locked, so nobody has to re-derive any of it. **Keep it current:**
when you finish C2 or C3, flip its row in "Status at a glance" and add a Changelog line.

> History: this file began (2026-06-18) as a one-shot *kickoff* that told a fresh session
> to PLAN all of Phase C via `brainstorming → writing-plans` and stop before implementing.
> That intent was only partly followed — piece **C1 was planned AND built AND committed**
> (no single combined `PHASE_C.md` plan was ever produced; C1 got its own plan doc instead).
> So as of 2026-06-23 this file is repurposed into the work/tracker doc it should have been.

---

## Status at a glance (last updated 2026-06-23)

Phase C is the **last** phase of the `atdd` "Stack" project, and it is built **here** in
`agent-tdd` (shell + markdown). It has **three pieces**:

| # | Piece | State |
|---|---|---|
| **C1** | Bootstrap **lsp surfacing** (advisory) | ✅ **DONE** — built + reviewed on branch `v2`; **not yet smoke-tested in a real bootstrap** (agent/human provisioning half unproven — ROADMAP Smoke-Test Risk #9) |
| **C2** | **`stack init`** skeleton recipe | ❌ **Not started** — open design questions below |
| **C3** | Mandatory, thorough **end-of-task zoom-in** | ❌ **Not started** — open design questions below (the meatiest design call) |

**Net: 1 of 3 done.** C1 is built but not merged/pushed and not proven end-to-end.

---

## The big picture (zero-context primer)

Two sibling repos under `/home/m6/willy/`, both on branch **`v2`**:

- **`atdd-cli`** (Rust) — a local tool (daemon + SQLite + CLI) that replaced GitHub for
  work-items (Phase 1) and now also holds a queryable **architecture model**: a "Stack" of
  **Layers / Interfaces / Processes / Pipelines**. The model is **fact-checked against real
  code** by an **`lsp`** (a language server, e.g. rust-analyzer) the daemon drives. The whole
  value is the **determinism line**: the LLM declares meaning, the tool verifies against
  facts, **disagreement = signal**.
- **`agent-tdd`** (THIS repo; shell + markdown, runs on tmux) — the **plugin**: a wave-based,
  four-agent TDD orchestrator (Notes / Root / Test / Impl) that drives `atdd` via the CLI.
  **Phase C is built HERE.**

`atdd-cli` Phase 2 has two DONE phases (on `v2`, individually reviewed):
- **Phase A** — the stack model (`layer`/`interface`/`process`/`pipeline` verbs, `stack graph`,
  write-time cycle guard, `layer at` + work-item link bridge, file-exists `stack verify`).
- **Phase B** — the determinism line (`lsp` registry, `async-lsp` client + warm-server
  supervisor, anchor resolver moniker→name+kind+container fallback, semantic `stack verify` +
  `stack drift`, version-bump handling, readiness gate, structural false-drift guard — proven
  against real rust-analyzer; a false "deleted" signal is structurally impossible — worst case
  is an honest "unverifiable").

## The authoritative spec — READ IT before C2/C3

- **`../atdd-cli/PHASE_2.md` §8 (Phase C)** — the authoritative spec (C1/C2/C3, milestones,
  exit gate). §8 already marks **C1 DONE** and points back at this work doc.
- `../atdd-cli/STACK.md` — the model vocabulary (Layer / Interface / Process / Pipeline).
- `../atdd-cli/PHASE_2.md` §1–§5 — how the tool works.
- The `atdd` CLI is complete and self-documenting — **run `atdd --help` and `atdd <verb>
  --help`**. Phase-C verbs: `atdd layer add/edit/list/show/rm/at/link/unlink`, `atdd interface
  add/list/show/edit`, `atdd process add/group/list/show/edit`, `atdd pipeline add/list/show`,
  `atdd stack graph/verify/drift`, `atdd lsp register/list`. Everything is scoped by a global
  `atdd --project <slug>`.

---

## ✅ C1 — bootstrap lsp surfacing (DONE; what shipped)

**What it does.** At plugin bootstrap (where the tmux env check + `skills/ensure-atdd.sh`
already run), detect the repo's symbol-precise languages by file pattern, cross-check `atdd
lsp list`, and **surface (advisory — never blocks)** any detected language with no working
`lsp`. The agent then provisions: detect → ask the human which language server → install →
(`atdd repo register` if needed) → `atdd lsp register <path>`. **Registered == active** — a
registered `lsp` IS the coverage signal; there is no separate `require`/`check`.

**Where it lives (verified):**
- `skills/lsp-surface.sh` — a new **top-level shared recipe** (sibling of `ensure-atdd.sh`,
  NOT under a `recipes/` dir). Detects languages, reads each `atdd lsp list` row's `status`
  (`ok`/`missing`/`not_executable`), emits a gap JSON `{repo, repo_registered, detected,
  covered, missing}`. The repo slug is **never null** (`--repo` → git origin → manifest
  `home_repo` → atdd registry by path → `local/<folder>`); reports `repo_registered` so the
  agent runs `atdd repo register` first when false.
- Wired into **both** bootstrap layers (hybrid: recipe = deterministic floor, agent refines +
  provisions): Root `skills/atdd/SKILL.md` (bootstrap step 0); Notes `skills/atdd-plan/CORE.md`
  (§2) + `skills/atdd-fix/SKILL.md`.
- **Advisory — never blocks** (honors reversed D6, unlike the tmux check).

**Tested:** hermetic no-LLM gate in `skills/atdd-plan/recipes/tests/run.sh` — `== lsp-surface
==` (real `atdd`, temp `ATDD_HOME`, no language server) + a `== bootstrap wiring ==` grep gate.

**Artifacts:** plan `docs/superpowers/plans/2026-06-18-lsp-surfacing.md`; commits
`9d59aa0`..`244e2bf` (key fix `98ae377` = never-null slug + `repo_registered`).

**NOT yet verified (ROADMAP Smoke-Test Risk #9 — do this before declaring C1 truly closed):**
the **agent/human half** — pick a server, install, `atdd repo register`/`atdd lsp register`
under the right slug, confirm it's visible to `atdd stack verify`; the `local/<folder>` slug
fallback in the Root's no-origin/no-manifest case; the registry path-match (symlinked
`/tmp`); over-detection noise (no `node_modules`/`vendor`/`target` prune).

---

## ❌ C2 — `stack init` skeleton recipe (NOT started)

**Spec (PHASE_2.md §8 / milestone C2).** A cheap top-down first pass: read manifests / top
dirs / contracts, declare the coarse top **Layers** + the headline cross-repo **Interface**,
all marked `--confidence proposed`, leaning on lsp-proposed boxes where possible.

**Open design questions (resolve WITH the human before building):**
1. The **read-set** — what does it read (manifests? top-level dirs? declared contracts?), and
   what is the **lsp-proposed vs LLM-judged split** (how much the skeleton auto-proposes vs the
   agent judges)?
2. **When it runs** — project setup (once) vs first wave?

**Likely shape:** a new recipe `skills/atdd-plan/recipes/stack-init.sh`; hermetic gate asserts
a 2-Layer + 1-Interface `proposed` map on this 2-repo project.

## ❌ C3 — mandatory, thorough end-of-task zoom-in (NOT started; the hard one)

**Spec (PHASE_2.md §8 / milestone C3).** After a TDD agent finishes — Impl after
`record-green`, Root after `integrate`/`issue-done` — it MUST update the Stack for the boxes
it touched (`layer`/`interface`/`process` verbs + `layer link --issue`) and run `stack verify`,
at the moment its understanding is sharpest. The human chose a **thorough** map (not a light
touch), and it must be **un-skippable**.

**Open design questions (resolve WITH the human before building):**
1. **Where exactly it hooks in** — Impl after `record-green`? Root after `integrate`? both?
2. **How to make it un-skippable** — a coordination gate? a required terminal recipe step? a
   status-file check (no `.done` until the zoom-in verbs ran)?
3. **What "thorough" means per task** — which boxes an agent must declare — without
   over-taxing every task.

**Likely shape:** a recipe `skills/atdd-plan/recipes/stack-zoom.sh`; bake the step into the
role docs (`IMPL`, Root/`PROTOCOL.md`, `ORCHESTRATE.md`); coordination gate asserts the verbs
fire and `stack verify` is called.

---

## Locked decisions to honor (do NOT relitigate)

- **D6 (reversed):** registered == active — a registered `lsp` is the coverage signal (no
  separate `require`/`check`); bootstrap lsp surfacing is **advisory, never project-blocking**
  (unlike the tmux check).
- The end-of-task zoom-in (C3) is **mandatory + thorough**.
- **One Stack per project**; anchors keyed moniker → (name + kind + container) fallback; the
  CLI verb structure is **flat** (`atdd layer add`, not grouped) — keep it.
- **Plan altitude** = design-whitepaper + phased milestones (like `PHASE_2.md`); expand each
  milestone into bite-sized TDD tasks only at execution time.

## Where to build it + conventions / footguns

Explore the layout before touching it (`skills/` tree — esp. `skills/atdd-plan/recipes/` and
the entry skills; role docs `IMPL`/`TEST`/`ROOT`/`PROTOCOL`/`ORCHESTRATE`; where the bootstrap
env check + `skills/ensure-atdd.sh` live; the spawn scripts; how recipes are tested). Footguns:

- Recipes run **zero `gh`** in the inner flow; gate scripts set their own hermetic `ATDD_HOME`.
- **`env -u ATDD_PROJECT`** is a known footgun — a set `$ATDD_PROJECT` breaks the gates.
- Recipes must stay **idempotent + resumable** (`set -euo pipefail`; progress → stderr; only
  intentional return values → stdout). **Absolute paths everywhere.** Use `${CLAUDE_SKILL_DIR}`.
- **Tooling:** the `lsp`/`stack` verbs need an `atdd-cli` build **≥ commit `377a013`** (the
  `lsp list` `status` field + the `oracle`→`lsp` rename + the D6 reversal). Iterate against a
  local build with **`make use-dev-atdd`** (symlinks the installed `atdd` at
  `../atdd-cli/target/release/atdd`); `make use-release-atdd` restores; `make atdd-status` shows
  which is active. No release/snapshot needed (see this repo's `CLAUDE.md` "versioning").

## How to test Phase C without a live LLM

Extend the existing hermetic gate — `skills/atdd-plan/recipes/tests/run.sh` — the same pattern
C1 used (`== lsp-surface ==` + `== bootstrap wiring ==`). Drive the **real built `atdd`** under
a temp `ATDD_HOME`, no LLM. C2 → assert the `proposed` 2-Layer + 1-Interface map. C3 → assert
the zoom-in verbs fire and `stack verify` is called. (PHASE_2.md §9 calls this the Phase-C
"coordination gate".)

## Process for each remaining piece (C2, then C3)

Honor the original kickoff discipline, scoped per piece:
1. **`brainstorming`** the open design questions above **with the human** (do not pre-decide).
2. **`writing-plans`** — extend this doc (or a piece plan under `docs/superpowers/plans/`).
3. **Stop for human review** of the plan before implementing.
4. Implement TDD; review; then flip the piece's row in "Status at a glance" + add a Changelog
   line here, and update `ROADMAP.md` (Status / Future Work) + `../atdd-cli/PHASE_2.md` §8.

## Logistics

- Both repos on **`v2`**. Phase A + B (atdd-cli) and C1 (here) are committed **locally** — NOT
  pushed/merged. A `x.x.x-snapshot` prerelease channel exists but is **NOT yet cut**.
- **Do not push or cut releases.** Phase C work happens here on `v2` (or a sub-branch).

## Changelog

- **2026-06-23** — Repurposed this file from a one-shot kickoff into the living Phase C work
  doc. Recorded C1 DONE (built/reviewed, not smoke-tested), C2/C3 not started with their open
  design questions preserved. Cross-linked `ROADMAP.md` + `../atdd-cli/PHASE_2.md` §8.
- **2026-06-18** — Original kickoff authored to bootstrap a fresh Phase-C planning session.
