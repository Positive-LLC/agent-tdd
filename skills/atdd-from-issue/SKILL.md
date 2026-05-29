---
name: atdd-from-issue
description: Run /atdd against a single ready SubIssue produced by the Notes Agent. Use when the human types `/agent-tdd:atdd-from-issue <owner/repo> <issue#>` (or `<owner/repo>#<N>` in one arg). Fetches the SubIssue body + its parent RootIssue body, then delegates to /atdd with the union as Wave-0 seed — skipping freeform spec discussion since planning is already done upstream.
disable-model-invocation: true
user-invocable: true
allowed-tools: Bash Read Write Edit Grep Glob Agent
argument-hint: <owner/repo> <issue-number>   (or  <owner/repo>#<N>  as one arg)
---

# You are Root (issue-driven mode)

Thin wrapper around `/atdd`. The human invoked you by typing
`/agent-tdd:atdd-from-issue` with a reference to a SubIssue already planned
by the upstream **Notes Agent** (see `${CLAUDE_SKILL_DIR}/../atdd-plan/CORE.md`).

atdd's SKILL.md and PROTOCOL.md use `${CLAUDE_SKILL_DIR}/../atdd/...`
self-relative paths throughout, so they resolve correctly from this skill's
directory without any per-call remap.

Read `${CLAUDE_SKILL_DIR}/../atdd/SKILL.md` and
`${CLAUDE_SKILL_DIR}/../atdd/PROTOCOL.md` and operate per /atdd's contract,
with the deltas below. **All ten hard invariants from /atdd apply unchanged.**

---

## Wave 0 deltas (the only thing this skill changes)

The /atdd protocol's §3.1 Wave 0 has three responsibilities: (a) ask the human
for **base branch** and **gh account** and **task slug**, (b) discuss the spec
freeform with the human, and (c) initialise the Root and propose Wave 1.

This wrapper replaces only (b) — the spec is already distilled by the Notes
Agent. Everything else runs as normal.

In order, immediately on invocation:

1. **Parse `$ARGUMENTS`.** Accept either form:
   - Two args: `<owner/repo> <issue#>` (e.g. `Positive-LLC/erp-b2b-otc 142`)
   - One arg:  `<owner/repo>#<N>`      (e.g. `Positive-LLC/erp-b2b-otc#142`)

   If unparseable, tell the human the expected forms and stop.

2. **Fetch the seed.** Run:
   ```bash
   bash ${CLAUDE_SKILL_DIR}/recipes/fetch-issue-seed.sh <owner/repo> <issue#>
   ```
   The recipe verifies the issue carries **both** `atdd:sub` and `atdd:ready`,
   resolves its native parent RootIssue, and prints a single markdown
   document (the Wave-0 seed) on stdout. Capture that output — it is your
   seed. If the recipe exits non-zero, surface its error verbatim to the
   human and stop. Likely causes:
   - The issue is not labelled `atdd:sub` → tell the human to use `/atdd`
     directly (not every issue is a planned SubIssue).
   - The issue is not labelled `atdd:ready` → tell the human to resolve it
     in `/agent-tdd:fix` first (the Notes Agent has not signed off).
   - No native parent linkage → the SubIssue was created without
     `sub-create.sh`; re-create it via the Notes Agent.

3. **Proceed through /atdd's Wave 0, with these substitutions:**
   - **Skip /atdd PROTOCOL.md §3.1 step 3** (the freeform "listen and clarify"
     loop). The seed *is* the spec — do not re-discuss it.
   - **Keep §3.1 step 1** — ask the human for **base branch** (no default).
   - **Keep §3.1 step 2** — ask the human for the **gh account** (no default;
     propose reusing a value from any prior `meta.json` in this repo if one
     exists).
   - **Keep §3.1 step 4** — ask for the **Root task slug**, or propose one
     derived from the SubIssue title (lowercase, hyphens, matching
     `^[a-z0-9-]+$`). The human confirms or edits.
   - **Run §3.1 step 5** — `init-root.sh <slug> <base> <gh-account>` — as
     normal.
   - **§3.1 step 6 (Wave 1 proposal):** the seed already enumerates test
     cases / scope for the SubIssue. Lay them out as Wave 1 issues exactly
     as the seed prescribes (one Subject Under Test + one-sentence
     Behavior + Type per issue). Apply /atdd's scope discipline (§3.6).
     If the SubIssue body is a single coherent test scope, Wave 1 may
     legitimately be one issue.
   - **§3.1 step 7** — wait for "go".

4. **From Wave 1 onward you are pure /atdd.** Re-read
   `${CLAUDE_SKILL_DIR}/../atdd/PROTOCOL.md` at every phase boundary as
   PROTOCOL requires. Do not re-read this file again — its job is done
   after Wave 0.

---

## Reminders

- This skill exists so the Notes Agent → Root Agent handoff is **one tight
  loop**: the human plans via `/agent-tdd:fix`, marks a SubIssue
  `atdd:ready`, and pastes its ref here. No spec re-discussion. No
  modification to `/atdd`.
- The seed is **read-only context** for you. Do not edit the SubIssue or
  RootIssue bodies from this session — those are the Notes Agent's
  artifacts. If you need to change them, the human should re-enter
  `/agent-tdd:fix`.
- If the human pastes the ref of a SubIssue that is **already closed** (its
  `/atdd` run merged previously), the recipe will still print a seed (the
  bodies still exist), but you should pause and ask the human whether they
  intended to re-run a closed task. Default recommendation: do not re-run
  without an explicit "yes, replay."
