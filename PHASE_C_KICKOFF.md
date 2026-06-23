# Phase C Kickoff — plan the plugin-side self-maintaining loop

**You are a fresh session with no prior context. Read this whole file, then plan Phase C.**

## Your task
Use the **superpowers workflow** to PLAN Phase C of the `atdd` "Stack" project — do **not** implement yet. Start with the **brainstorming** skill (there are real open design questions below — resolve them *with the human*), then **writing-plans** to produce the plan. Match the altitude/shape of `../atdd-cli/PHASE_2.md`: a design-whitepaper + phased milestones, expanded into bite-sized TDD tasks only at execution time. Save the result as a plan doc (e.g. `PHASE_C.md` in this repo, or extend `../atdd-cli/PHASE_2.md` §8). Stop for human review of the plan before any implementation.

## The big picture (you have zero context — this is it)
Two sibling repos under `/home/m6/willy/`:
- **`atdd-cli`** (Rust): a local tool — a daemon + SQLite + a CLI — that (Phase 1) replaced GitHub for work-items, and (Phase 2) now also holds a queryable **architecture model**: a "Stack" of **Layers / Interfaces / Processes / Pipelines** (`../atdd-cli/STACK.md` is the model spec — it was `WHITEPAPER.md`). The model is **fact-checked against real code** by an **`lsp`** (a language server, e.g. rust-analyzer) that the daemon drives. The whole value is the *determinism line*: the LLM declares meaning, the tool verifies against facts, **disagreement = signal**.
- **`agent-tdd`** (THIS repo; shell + markdown, runs on tmux): the **plugin** — a wave-based, four-agent TDD orchestrator (Notes / Root / Test / Impl) that drives `atdd` via the CLI. **Phase C is built HERE.**

Phase 2 of `atdd` has two DONE phases (on `atdd-cli`'s `v2` branch, individually reviewed):
- **Phase A** — the stack model: `layer`/`interface`/`process`/`pipeline` verbs, `stack graph` (Mermaid + dashboard), a write-time cycle guard, `layer at` + a work-item link bridge, and a file-exists `stack verify`.
- **Phase B** — the determinism line: an `lsp` registry, an `async-lsp` client + a warm-server supervisor, the anchor resolver (moniker → name+kind+container fallback), `stack verify` (semantic) + `stack drift`, version-bump handling, a progress-aware readiness gate, and a **structural false-drift guard** — proven end-to-end against real rust-analyzer. A false "deleted" signal is structurally impossible (worst case is an honest "unverifiable").

**Phase C is the last phase: the self-maintaining loop in this plugin.**

## The Phase C spec — READ IT FIRST
Read **`../atdd-cli/PHASE_2.md` §8 (Phase C)** — the authoritative spec. Also skim `../atdd-cli/STACK.md` (model vocabulary) and `../atdd-cli/PHASE_2.md` §1–§5 (how the tool works). Phase C's three pieces:

1. **Bootstrap lsp surfacing** — at plugin bootstrap (where the `tmux` environment check + `skills/ensure-atdd.sh` already run), detect the repo's symbol-precise languages and cross-check `atdd lsp list`; if a detected language has no registered `lsp`, **surface the gap (advisory — never blocks)** and have the agent provision it: detect → ask the human which language server to install → install → `atdd lsp register <path>`. Registered == active: a registered `lsp` is the coverage signal — there is no separate `require`/`check`.
2. **Mandatory, thorough end-of-task zoom-in** — after a TDD agent finishes (e.g. after `record-green` for Impl / `integrate` for Root), it MUST update the stack model for the boxes it touched (`layer`/`interface`/`process` verbs + `layer link --issue`) and run `stack verify`, at the moment its understanding of that code is sharpest. The human chose a **thorough** zoom-in (a rich map), not a light touch — and it must be **un-skippable**.
3. **`stack init` skeleton** — a recipe for the cheap top-down first pass: read manifests / top dirs / contracts, declare the coarse top Layers + the headline cross-repo Interface, all marked `--confidence proposed`, leaning on lsp-proposed boxes where possible.

## The tool surface Phase C wires into (all built + fully documented)
The `atdd` CLI is complete and self-documenting — **run `atdd --help` and `atdd <verb> --help`** to learn it. Verbs Phase C uses: `atdd layer add/edit/list/show/rm/at/link/unlink`, `atdd interface add/list/show/edit`, `atdd process add/group/list/show/edit`, `atdd pipeline add/list/show`, `atdd stack graph/verify/drift`, `atdd lsp register/list`. Everything is scoped by a global `atdd --project <slug>`. Semantics: `stack verify` resolves anchors via the `lsp` (SameSpot → verified + silent refresh; moved/renamed/deleted → drift; **lsp-down/not-ready → "unverifiable", never a false "deleted"**); `stack drift` is a read-only listing of the non-clean boxes.

## Locked decisions to honor (do not relitigate)
- **D6 (reversed):** registered == active — a registered `lsp` is the coverage signal (no separate `require`/`check`), and bootstrap lsp surfacing is **advisory, never project-blocking** (unlike the `tmux` check).
- The end-of-task zoom-in is **mandatory + thorough**.
- One Stack per project; anchors keyed moniker → (name + kind + container) fallback; the CLI verb structure is **flat** (`atdd layer add`, not grouped) — keep it.
- Plan altitude = design-whitepaper + phased milestones (like `PHASE_2.md`); TDD tasks expanded at execution time.

## Where to build it — explore THIS repo first
Phase C is shell + markdown in `agent-tdd`. Before planning, explore the layout (use Explore/grep): the `skills/` tree (especially `skills/atdd-plan/recipes/` and the entry skills), the role docs (`IMPL` / `TEST` / `ROOT` / `ORCHESTRATE` / `PROTOCOL` — locate them), where the bootstrap environment check + `skills/ensure-atdd.sh` live, the agent-spawn scripts, and how recipes are tested. Conventions/footguns: recipes run **zero `gh`** in the inner flow; gate scripts set their own hermetic `ATDD_HOME`; **`env -u ATDD_PROJECT`** is a known footgun (a set `$ATDD_PROJECT` breaks gates); there is a **no-LLM coordination gate** pattern and recipe-level tests (`skills/atdd-plan/recipes/tests/`).

## Open design questions — brainstorm these WITH the human (that's why you brainstorm first)
1. Exactly **where the mandatory zoom-in hooks in** (Impl after `record-green`? Root after `integrate`? both?) and **how to make it un-skippable** (a coordination gate? a required terminal recipe step? a status-file check?).
2. The **lsp surfacing** concretely: which bootstrap script it lives in; how covered languages are detected (by file pattern, cross-checked against `atdd lsp list` — registered == active, so there is no `require`); the **provision UX** (how the agent detects a missing LSP, asks the human, installs, and `lsp register`s it).
3. The **`stack init` read-set** (what it reads; lsp-proposed vs LLM-judged split) and **when it runs** (project setup vs first wave).
4. **How to test Phase C without a live LLM** (extend the no-LLM coordination gate? a recipe-level gate like the atdd-plan recipe tests?).
5. What **"thorough"** means in practice per task (which boxes an agent declares) without over-taxing every task.

## State / logistics
- Both repos are on branch **`v2`**; Phase A + B and a `x.x.x-snapshot` release channel are committed locally (NOT pushed/merged). Phase C work happens here in `agent-tdd` on `v2` (or a sub-branch — your call at implementation time).
- A **`x.x.x-snapshot`** prerelease channel was just built so the plugin can be iterated against a built `atdd` binary — see this repo's `CLAUDE.md` "Plugin metadata & versioning". It is NOT yet cut.
- **Do not push or cut releases.** Do not implement during planning.

## Deliverable
A Phase-C implementation plan (design + phased milestones, the `PHASE_2.md` shape), produced via **brainstorming → writing-plans**, saved as a doc. Resolve the open questions with the human first, then write the plan, then **stop for the human to review it** before implementing.

---
*(This kickoff file was generated by the previous session to bootstrap a fresh, low-context Phase-C planning session. It can be deleted once the plan exists.)*
