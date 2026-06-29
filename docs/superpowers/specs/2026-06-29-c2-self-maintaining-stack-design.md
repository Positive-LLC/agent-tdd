# C2 — the self-maintaining Stack (design spec)

> **Phase C, piece C2.** The mandatory, thorough, un-skippable end-of-task **zoom-in** that makes
> the atdd Stack maintain itself. Authoritative parent spec: `../atdd-cli/PHASE_2.md` §8; work doc:
> `PHASE_C_KICKOFF.md`; agent guide: `skills/STACK_USAGE.md`. Built **here** in `agent-tdd`
> (shell + markdown + one Claude Code hook) — **no `atdd-cli` product/schema changes expected** (at
> most a test-gate addition in `atdd-cli/tests/wave-coordination.sh`).
>
> **STATUS — design, awaiting human review (2026-06-29).** Not yet planned or built. After approval
> this becomes a `writing-plans` plan under `docs/superpowers/plans/`.

## Goal

The Stack (Layers / Interfaces / Processes / Pipelines) maintains itself as a **by-product of doing
the work** — no user-side init, no separate "go map the repo" pass. The mechanism is the **sharpest
moment**: an agent understands the code best the instant it finishes it, so that is when it records,
updates, and verifies the boxes it touched. The sum of those tiny peak-accuracy updates **is** the
living map.

## The reframe that drives this design

C2 is **not** "add an end-of-task write step to two agents." It is: **make all four agents
bidirectional Stack users.** Every agent — Notes / Root / Test / Impl — uses the Stack in two
directions:

- **READ (orient), continuously throughout the task.** The agent queries the Stack (`stack roots`,
  `stack zoom <id>`) to know *where the work it is doing sits in the model* — which layer, which
  side of which interface. Orientation, not a one-time step. The atdd read-side (Phase D) already
  supports this; C2's read work is **role-doc wiring**, not new tool features.
- **WRITE (create / update / maintain / repair), at the sharpest moment.** When the task finishes,
  the agent records the boxes it touched and runs `stack verify` on them. This is the
  self-maintaining half. It uses **existing** verbs (`layer|interface|process add/edit`,
  `layer link --issue`, `stack verify`) — no new tool features.

The **sharpest moment is per-agent** and must be defined separately, because each agent has a
different (and for Notes, fuzzy) lifecycle.

## The four agents

| Agent | Lifecycle | READ to orient (where) | Sharpest WRITE moment | What it writes |
|---|---|---|---|---|
| **Test** | one-shot, spawned per issue by Root | the "understand the codebase" step, before writing tests — zoom the layer the code-under-test sits in, so the test boundary matches the real interface | **right after it authors the red tests + records the test command** (`atdd test-issue done`), before it spawns Impl and self-closes | the **interface / behavioral contract it just pinned** — the boundary the tests exercise (an `interface`, and/or a `process`), anchored to the SUT |
| **Impl** | one-shot, spawned per issue | at start, before coding — zoom the target layer/interface to build against the declared shape | **right after `record-green`**, before it writes its terminal `.done` status | the **layer(s) / process(es) it created or changed**; runs `stack verify` on the touched boxes (LSP-backed for symbol-precise langs) |
| **Root** | per-task, clear-ish start/end (init-root → drive waves → integrate → terminate after human merge) | at init + per wave — read the subtree it owns (its RootIssue's layers) | **after `atdd integrate`** (per wave), before it marks the issue merged | runs **`stack verify` on the touched subtree** (the architecture analog of the union test re-run `integrate` already does) + reconciles any **cross-issue interface** that only became real at merge |
| **Notes** | long-lived loop, **no hard end** (returns to standby) | at investigation start — `stack roots` to place the plan in the existing architecture | **two** touches (see below) | (1) the *intended* shape as `proposed`; (2) verify it held |

### The Notes two-touch model (the hard case)

Notes is the only agent that exists **before the code does**, and it loops with no clean end. So it
gets **two** Stack touches, not one:

1. **Touch 1 — just before it decomposes a RootIssue into SubIssues** (its peak architectural-decision
   moment). It declares the **intended** architectural shape the RootIssue will change — the layers /
   interfaces it plans to add or move — as boxes with `--by llm --confidence proposed`. These are a
   **prediction**, anchored where it expects the code to land.
2. **Touch 2 — after the cohort's final merges, before it closes the RootIssue** (its validation
   moment). It runs `stack verify` on those boxes to check the prediction actually held, reconciles
   (promote `proposed` → `verified`, fix anchors, or record honest drift), then closes.

**The philosophy underneath:** *the plan declares the shape as a prediction; the workers (Test/Impl)
and the determinism line verify it against real code; disagreement is signal.* This is exactly
atdd's core stance — the LLM declares meaning, the tool checks it against facts (`../atdd-cli/STACK.md`
§6–§7). Notes predicts; the LSP and the workers confirm or refute.

## Enforcement architecture (the hybrid)

"Un-skippable" is enforced in **three layers**. It matters which layer is a Claude Code hook and
which is the plugin's own mechanism.

### Layer 1 — Markdown role-doc contracts (instructions)
Each agent's role doc gains the READ-to-orient step and the WRITE-at-sharpest-moment step. Tells the
agent *what* and *how*. Necessary but **not sufficient** alone (a misbehaving agent can ignore it).
Files: `skills/atdd/roles/IMPL_AGENT_ROLE.md`, `skills/atdd/roles/TEST_AGENT_ROLE.md`,
`skills/atdd/PROTOCOL.md` (Root), `skills/atdd-plan/CORE.md` + `ORCHESTRATE.md` (Notes), all pointing
at the single `skills/STACK_USAGE.md` guide (which gains an "end-of-task zoom-in" section).

### Layer 2 — A recipe + status-file gate (the deterministic floor — the plugin's OWN bash mechanism, NOT a Claude Code hook)
A new recipe **`skills/atdd/recipes/stack-zoom.sh`** (hybrid pattern, exactly like `lsp-surface.sh`):
the **recipe** carries the deterministic, testable part — it runs `atdd stack verify` on the
touched boxes, and on success writes a **completion marker** (e.g. `…/status/<issue>.stack-zoom` or a
field in the status JSON). The **agent** does the judgment part — deciding which boxes to declare and
running the `layer|interface|process add/edit` verbs — guided by Layer 1.
- The agent **must run `stack-zoom.sh` (exit 0) before writing its terminal status** (`.done` for
  Impl; the equivalent close step for Root/Notes; before spawn-impl/self-close for Test).
- The **no-LLM coordination gate** (`atdd-cli/tests/wave-coordination.sh` +
  `skills/atdd-plan/recipes/tests/run.sh`) asserts: the marker exists whenever the terminal status
  exists, and `stack verify` was invoked. This is the deterministic catch — works for **all four**
  agents, testable with no LLM.
- `stack-zoom.sh` exits **non-zero (BLOCKED)** if `stack verify` reports drift/blocked or the required
  declaration is absent — mirroring `stack-preflight.sh`'s exit-3 convention.

### Layer 3 — A Claude Code `Stop` hook (the hard backstop — a REAL Claude Code hook)
The plugin ships **`hooks/hooks.json`** with a `Stop` hook → a script that makes the agent's `claude`
process physically refuse to end until the zoom-in completion marker exists. Verified-viable facts:
- The agents launch **interactively** (`claude --permission-mode bypassPermissions` via `tmux
  send-keys`), **not** `-p`/headless — so `Stop` hooks **do** fire. (`-p` mode would suppress them.)
- A `Stop` hook returns `{"hookSpecificOutput":{"hookEventName":"Stop","decision":"block","reason":…}}`
  to re-enter the agent loop with the reason as an instruction; a `stop_hook_active` guard + the
  8-block cap (`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` to raise) prevent infinite loops.

**Scope of Layer 3 — Test and Impl ONLY.** Notes and Root **pause for the human** mid-task (Notes
asks you to confirm Input/Output; Root asks for merge confirmation). Their `Stop` fires on *every*
such pause, so a "block-until-written" hook would mis-fire. Test and Impl are **autonomous one-shot**
agents whose only natural `Stop` *is* task-end, so the hook is clean there.

**Two hook gotchas the script must handle:**
- A plugin `Stop` hook fires for **every** `claude` session with the plugin enabled (including your
  own orchestrating session). The script must **no-op (exit 0) unless it detects an agent-tdd worker
  context** — an env var (`ROOT_ID` / `WORKTREE_DIR` / a wave status dir) or a marker file. It must
  also detect *which* role it is and only enforce for Test/Impl.
- Honor `stop_hook_active` and the block cap so a genuinely stuck agent is never locked out.

### Who gets what

| Agent | Layer 1 (markdown) | Layer 2 (recipe + status gate) | Layer 3 (Stop hook) |
|---|---|---|---|
| Test | ✅ | ✅ | ✅ |
| Impl | ✅ | ✅ | ✅ |
| Root | ✅ | ✅ | ✖ (pauses for human) |
| Notes | ✅ | ✅ | ✖ (pauses for human, loops) |

**Enforcement strength is NOT uniform — be honest about this.** It is strongest for **Impl** (the
`.done` write the wave-watcher counts is a hard gate, plus the `Stop` hook) and **Test** (the
spawn-impl/self-close precondition, plus the hook). It is **per-wave** for **Root** (gated at each
`integrate`). It is **softest for Notes**: Notes is long-lived with the human in the loop and has no
terminal status file to count, so its two touches rest on Layer 1 + the recipe being run (no
wave-watcher-style hard gate, no hook). That is acceptable *because* the human is present for the
Notes loop — but the plan should not pretend Notes is gated as hard as Impl.

## What "thorough" means (the per-task contract — Q3)

A rich map, not a light touch — but **without over-taxing every task**:

- **Declare only the boxes you directly TOUCHED** — the layer / interface / process your diff
  created or changed. Do **not** re-declare the whole subtree, and do **not** declare boxes you only
  *read* or *depended on*.
- **Always run `stack verify` on your anchor(s)** after writing, so a typo'd anchor or real drift
  surfaces at the sharpest moment (when you can still fix it cheaply).
- **A task that genuinely touches no architectural boundary** (e.g. a one-function bugfix) may write
  little or nothing new — but it must still (a) read-to-orient and (b) `stack verify` the box it sits
  in is still accurate. Floor = "verify the box you're in"; ceiling = "declare the new boxes you
  created."
- **Granularity follows the agent's scope:** Test → the interface/contract it pinned; Impl → the
  layer/process it implemented; Root → verify the integrated subtree; Notes → the planned shape, then
  verify.
- **LSP-mandatory is already enforced upstream** (`stack-preflight.sh`, #2/#32): a `#symbol` anchor in
  a symbol-precise language with no registered LSP is `blocked`, never silently `verified`. C2 inherits
  this; it does not re-implement it.

## Components to build (all in `agent-tdd`)

1. **`skills/atdd/recipes/stack-zoom.sh`** — the deterministic floor: run `stack verify` on the touched
   boxes, write the completion marker, exit non-zero on drift/blocked/missing-declaration. Hybrid
   conventions (`set -euo pipefail`; progress→stderr; machine value→stdout; absolute paths;
   idempotent; zero `gh`).
2. **`hooks/hooks.json` + `hooks/stack-zoom-stop.sh`** — the `Stop`-hook backstop for Test/Impl
   (context-detection + role-detection + `stop_hook_active` guard + marker check + block JSON).
3. **Role-doc edits (Layer 1)** — IMPL / TEST role docs, Root `PROTOCOL.md`, Notes `CORE.md` +
   `ORCHESTRATE.md`: add the READ-to-orient step and the WRITE-at-sharpest-moment step, each pointing
   at `skills/STACK_USAGE.md`.
4. **`skills/STACK_USAGE.md`** — add the "end-of-task zoom-in" section (the WRITE contract per agent,
   the thoroughness rule). **Bump the `STACK-USAGE-SYNC` marker in both copies** (the drift gate).
5. **Test gate extensions** — `skills/atdd-plan/recipes/tests/run.sh` (+ `atdd-cli/tests/
   wave-coordination.sh`): assert the zoom-in marker exists with the terminal status, that
   `stack verify` ran, and that the `Stop` hook blocks a Test/Impl agent context with a missing marker
   and no-ops a non-agent context.

## Locked decisions (honor these)

- **No user-side initialization** — the Stack self-maintains from the sharpest-moment zoom-ins; the
  human never runs a setup pass.
- **All four agents are bidirectional** — read-to-orient throughout, write-at-sharpest-moment at the
  end.
- **The end-of-task zoom-in is mandatory, thorough, and un-skippable.**
- **The LSP is global + cross-cutting and mandatory for symbol-precise langs** (D6 reversal; #2/#32) —
  inherited from C1, not re-built.
- **Built in `agent-tdd`** (shell + markdown + one hook); **no `atdd-cli` changes expected** — confirm
  during planning.
- **Recipe = deterministic testable floor; markdown = judgment + human-facing** (the plugin's standing
  hybrid pattern).

## Open decisions to confirm (at this spec review)

1. **Ship the Layer-3 `Stop` hook, or keep enforcement at Layers 1+2 only?** The hook buys *true*
   harness-level un-skippability for Test/Impl, at the cost of coupling the plugin to Claude Code's
   hook system (global firing → context detection, the 8-block dance, the headless caveat). Layers 1+2
   alone are already strong and fully testable with no LLM. **Recommendation: ship it for Test/Impl as
   a backstop**, but it is cleanly separable if you'd rather not.
2. **The thoroughness floor** — is "verify the box you're in even when you declared nothing new" the
   right minimum, or too much for trivial tasks?
3. **Notes Touch-1 as `proposed` boxes** — confirm you want Notes to predict the shape before code
   exists (plan-as-prediction), versus recording only what's already real.

## Out of scope (not C2)

- Any new `atdd-cli` verb or schema change (C2 is plugin-only).
- The interactive four-agent LLM smoke run (cannot be scripted; `tests/SMOKE_RUN.md`).
- Re-implementing the LSP-mandatory gate (that is C1 / `stack-preflight.sh`).

## References

- `../atdd-cli/PHASE_2.md` §8 — authoritative C1/C2 spec + exit gate.
- `PHASE_C_KICKOFF.md` — the work doc (the three open design questions this spec answers).
- `skills/STACK_USAGE.md` — the single agent guide (gains the end-of-task zoom-in section).
- `../atdd-cli/STACK.md` §6–§7 — the determinism line (declare vs verify).
- `skills/stack-preflight.sh` — the existing un-skippable-gate model (exit-3 block).
- Claude Code hooks — `Stop` block semantics, `stop_hook_active`, plugin `hooks/hooks.json`.
