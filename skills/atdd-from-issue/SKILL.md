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

## Setup — ensure the `atdd` binary (before §0)

Before the orchestration probe or any recipe, ensure the local `atdd` CLI is installed:
run `bash ${CLAUDE_SKILL_DIR}/../ensure-atdd.sh` (see `${CLAUDE_SKILL_DIR}/../INIT_SETUP.md`).
If `CLAUDE_SKILL_DIR` is unset (Codex), resolve it first per `${CLAUDE_SKILL_DIR}/../atdd/SKILL.md`
step 0. Do not proceed until `atdd ping` works.

## 0. Orchestration probe (do this first)

Check whether you were spawned by the Notes-Agent orchestrator rather than a human:

```bash
echo "ORCH=${AGENT_TDD_ORCHESTRATED:-} NOTES=${AGENT_TDD_NOTES_ID:-} BASE=${AGENT_TDD_BASE:-} ACCT=${AGENT_TDD_GH_ACCOUNT:-} SLUG=${AGENT_TDD_SLUG:-} WS=${AGENT_TDD_WS_SESSION:-} SIG=${AGENT_TDD_SIGNAL_PATH:-}"
```

(These were set on your launch line, so they live in your process environment and
survive compaction — re-run the echo any time you need them.)

- **If `AGENT_TDD_ORCHESTRATED` is empty** → you were run by a human. Ignore this
  section entirely; the original "Wave 0 deltas" below are unchanged.
- **If `AGENT_TDD_ORCHESTRATED=1`** → **orchestrated mode**. Your "human" is the
  Notes-Agent orchestrator, reached only through signals — never address a person.
  Apply these overrides on top of the Wave 0 deltas:

  1. **Announce liveness immediately:** `bash ${CLAUDE_SKILL_DIR}/../atdd/recipes/write-signal.sh running --detail "orchestrated Root bootstrapping for ${AGENT_TDD_SUB_REF:-?}"`.
  2. **Parse `$ARGUMENTS` / fetch the seed** exactly as steps 1–2 below (the
     orchestrator passed `SUB_REF` in your bootstrap prompt; use it).
  3. **Skip every human question.** Do **not** ask for base / gh account / slug and
     do **not** wait for "go". Take them from the environment:
     `<base>=$AGENT_TDD_BASE`, `<gh-account>=$AGENT_TDD_GH_ACCOUNT`,
     `<slug>=$AGENT_TDD_SLUG`. Proceed straight from the Wave-1 proposal into
     autopilot.
  4. **Use your assigned workspace session.** Everywhere PROTOCOL.md says
     `ws-root-<id>`, use `meta.json:workspace_session` instead (init-root.sh records
     it from `$AGENT_TDD_WS_SESSION`). This keeps your child windows from colliding
     with a sibling Root that happens to share your `root-id` in another repo.
  5. **Escalate by signal, not by voice.** Where PROTOCOL.md says to surface to the
     human (an unanswerable pause, a stuck wave, a rebase-blocked PR), the env-gated
     `write-signal.sh` lines in PROTOCOL.md already emit the right signal and
     `notify-human.sh` drops a fallback — the orchestrator is watching. State a
     single recommendation in the signal (`--recommendation`), per §1.5 P6.
  6. **Final integration (§8) is different: you do NOT merge.** When all waves are
     done, push the integration branch and **open** the PR
     `agent-tdd/<slug>` → `<base>` (`gh pr create --base "$AGENT_TDD_BASE" --head "agent-tdd/${AGENT_TDD_SLUG}"`),
     then signal and **stop** — do not merge, do not run `terminate-root.sh`:
     ```bash
     bash ${CLAUDE_SKILL_DIR}/../atdd/recipes/write-signal.sh awaiting-merge-confirm \
       --pr-url "<the PR url>" --head "$(git rev-parse HEAD)" \
       --detail "all waves merged to agent-tdd/${AGENT_TDD_SLUG}; integration PR open"
     ```
     The orchestrator confirms the merge with the real human, runs `gh pr merge`
     itself, then runs `terminate-root.sh` and closes the SubIssue (ORCHESTRATE.md
     §6). The irreversible merge-to-base is the orchestrator's, behind a human gate —
     never yours. If a wave genuinely cannot be completed, signal `failed`
     (`write-signal.sh failed --recommendation "..."`) and stop.

  Everything else — `init-root.sh`, Wave-1 layout from the seed, all ten invariants,
  autopilot, disk durability, re-reading PROTOCOL.md at every boundary — is unchanged.

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
