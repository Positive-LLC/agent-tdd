# Agent TDD: A Wave-Based Workflow for Human-Agent Co-Authored Tests

**Version:** v2 (plugin v0.10.0)
**Audience:** Engineers implementing the workflow

> Project status, v1 deferrals, and known risks are tracked in [ROADMAP.md](ROADMAP.md).
>
> **v2 changelog (0.10.0):** Adds a Notes Agent planning layer upstream of
> the Root Agent. The Root Agent design described in §1–§9 is **unchanged**.
> See §1.5 (Layer architecture) and §10 (Notes Agent layer) for the addition.
>
> **⚠️ Current execution model (v1.1.x) — read before §2–§10.** The body below is the
> v2/v0.10.0 design rationale and still narrates the **GitHub-era** mechanics (issues,
> PRs, CI, a GitHubProject board). The *implemented* inner flow no longer uses GitHub:
> it runs on a **local work-item store (the `atdd` CLI) + plain git**, with GitHub
> touched only at the **optional final hand-off PR** to a base branch. The rationale
> (waves, gates, roles, coordination, token model) is unchanged — read the GitHub
> vocabulary through this map:
>
> | §2–§10 says (GitHub era) | Implemented now (local `atdd` store) |
> |---|---|
> | GitHub issue / GitHubProject board | work-item in the local `atdd` store (no board) |
> | impl agent "opens a PR" | impl agent pushes a branch + records green (`atdd record-green`) |
> | "CI passing" / `gh pr checks --watch` | the daemon re-runs the recorded test commands locally (green = all exit 0) |
> | "merge the PR into the Root branch" | Root runs `atdd integrate` = `git merge --no-ff` + a union re-verify of all merged issues' commands |
> | "done = integration PR merges + issue closed" | done = `atdd integrate` succeeds (work-item `merged`) |
> | the single final PR to base | **unchanged** — the one optional `gh pr` hand-off (PROTOCOL §8 / ORCHESTRATE §6) |
>
> **Multi-project (v1.1.1).** The store is multi-project: one isolated DB per project
> plus a global `master.db` registry (project + repo registries with stable UUIDs +
> repo↔project membership). A repo may belong to many projects; no work-item is ever
> shared across them. The Notes Agent resolves + pins an active project at planning
> bootstrap (sole project → auto; asks the human only when a repo belongs to >1) and
> carries it to every spawned agent via `$ATDD_PROJECT`. Detail: ROADMAP.md (v1.1.1),
> CORE.md §2.
>
> A full rewrite of §2–§10 into this local model is owed at the next major-version
> bump (per the repo rule the whitepaper body is edited only at major bumps — see
> CLAUDE.md / ROADMAP.md). This callout keeps the doc accurate until then.

---

## 1. Overview

**Agent TDD** inverts the labor split of classic TDD for the human-agent collaboration era. The human's high-leverage activity is *reviewing and shaping the test cases* (the spec); the agent does both the test-writing and the implementation, across two distinct kinds of sessions. The workflow proceeds in **waves** — bounded, parallel batches of work — with discovery deferred between waves rather than triggering recursive spawning.

Two principles anchor the design:

1. **Decouple discovery from execution.** When an agent finds new work mid-wave, it records it as a backlog item; the next wave executes it. This sacrifices reactive responsiveness in exchange for boundedness, parallelizability, and human auditability.
2. **Contract-first batch generation, not iterative TDD.** Agent TDD is *not* classical red-green-refactor. Each (test, impl) pair runs once: tests are committed, an implementation attempt is made, and the result is a PR (success or "gave up"). Refactor moves to PR review (handled by Root, escalated to human only when needed). Iteration happens at the *wave* level, not within a pair.

The Root Agent runs in **autopilot mode**: it spawns child agents, reviews their output, reroutes work, and re-spawns when needed. The human only ever talks to the Root Agent; child agents communicate exclusively with their Root.

---

## 1.5 Layer architecture (v0.10.0+)

Agent TDD is two layers, each with a single human-facing surface:

1. **Notes Agent** — `/agent-tdd:fix` today (and, later, `/agent-tdd:feature`). The **planning** layer, and (as of v1.0.0) the **orchestration** layer. In *planning mode* it investigates privately across one or more repositories, maintains a per-project NotebookIssue, and emits well-specced GitHub artifacts: RootIssues (concept-level "heads", in a designated home repo) + SubIssues (per-repo work units, native sub-issues of their RootIssue) inside a single GitHubProject board. After a single human "go", in *orchestration mode* it also **drives** the Root layer — spawning one Root per ready SubIssue and acting as each Root's human (delegate mode; one RootIssue at a time). Never writes product code, never becomes a Root itself. Operations contracts: `skills/atdd-plan/CORE.md` (planning) + `skills/atdd-plan/ORCHESTRATE.md` (orchestration). Design rationale: §10 below.

2. **Root Agent** — `/agent-tdd:atdd` (free-form spec), `/agent-tdd:atdd-from-issue <owner/repo> <#>` (consume a planned SubIssue), plus the compact wrapper. The **execution** layer — the wave-based orchestrator described in §1–§9. **Behaviorally unchanged**: a Root cannot tell whether its "human" is a person or the Notes Agent. Orchestration is carried entirely by environment the spawn sets + the `atdd-from-issue` wrapper; `/atdd` and PROTOCOL.md never branch on it. Operations contract: `skills/atdd/PROTOCOL.md`.

The two layers communicate via GitHub for all planning artifacts and the completion contract — **GitHub remains the single source of truth for "work done"** (a SubIssue is done only when its integration PR merges and it is closed). As of v1.0.0 the Notes Agent can additionally *orchestrate* the Root layer; that orchestration **coordination** layer uses local status files + tmux window state for Root liveness and escalation — a deliberate, scoped exception to "GitHub only", justified in §10.7. The planning artifacts and the completion contract are unchanged, and from the Root Agent's perspective nothing changes: a SubIssue body still looks identical to free-form `$ARGUMENTS`, and the Root cannot tell whether its "human" is a person or the Notes Agent.

> *(v1.1.x: per the **Current execution model** callout at the top, those "planning artifacts" and the "source of truth" now live in the **local `atdd` store**, not GitHub.com — both layers read/write the local store; GitHub appears only at the optional final hand-off PR. Read "GitHub" in this section as the local store.)*

Pick the entry point that matches the situation:

- One-shot spec describable inline → `/agent-tdd:atdd "<spec>"`.
- Multi-repo bug fix you want planned and then **executed hands-off** → `/agent-tdd:fix "<bug description>"`, plan the heads, then say `go` to orchestrate the whole dependency graph (one RootIssue at a time, one Root per ready SubIssue; you confirm a base branch per repo and each merge to base). See §10.7.
- Same, but you prefer to drive execution yourself (`plan-only`, or any time the session isn't inside tmux) → after planning, run `/agent-tdd:atdd-from-issue <owner/repo> <#>` for each `atdd:ready` SubIssue.

---

## 2. Roles

### Root Agent
- **Launched manually** by the human in a dedicated tmux window.
- **Interactive** — discusses the high-level feature/bug with the human at a spec level during Wave 0; thereafter operates in **autopilot orchestrator mode**.
- Acts as the **orchestrator and reviewer**:
  - Creates the initial wave's issues, spawns child agents.
  - Listens for status events (terminal + paused) from agents.
  - **Reviews** test outputs and impl PRs autonomously; re-spawns agents (with feedback) when work is unsatisfactory.
  - Handles paused agents: answers their questions if it can; raises hand to human only when truly stuck.
  - Drives the wave-merged gate (auto-merge, rebase ladder); escalates unresolvable conflicts to human.
  - Performs dedup, scope-discipline checks, and plans subsequent waves.
- One Root per task. Lives for the whole workflow.
- **Sole human interface.** Child agents never communicate with the human directly — all human-facing escalations go through Root.

### Test Agent
- **Spawned by Root** at the start of each wave (one per issue), in its own `git worktree`.
- **Interactive** tmux window. Default behavior: **self-close** after spawning the impl agent.
- May enter a **paused** state if the issue body contains an explicit `## Needs Clarification` section, or the agent encounters genuine ambiguity it cannot resolve from the issue spec. When paused, it writes a `.paused` status file containing the question and waits for Root's response (delivered via `tmux send-keys`).
- Communicates exclusively with Root. Never talks to the human, never talks to peer agents.
- Responsibilities:
  1. Build red tests for one issue.
  2. Commit them on a dedicated test branch.
  3. **Push the test branch to the remote** (so the impl agent — running in a different worktree — can fetch it).
  4. Update the GitHub issue body's `Test Branch` section with the SHA. Preserve all other sections.
  5. Spawn its paired Implementation Agent (creates the impl worktree, opens a new tmux window).
  6. Self-close. (No terminal status file is written by the test agent — that is the impl agent's job. The test agent only writes a `.paused` file if it explicitly pauses.)

### Implementation Agent
- **Spawned by its paired Test Agent** via `claude -p` (non-interactive).
- Runs in its own `git worktree` on a branch stacked off the test branch.
- **Single-session, single-PR rule.** The agent runs in one Claude session and produces at most one PR. Within that session it may iterate freely (run tests, see failures, edit, re-run) — that is normal work, not a forbidden retry. What is forbidden:
  - Spawning additional impl agents.
  - Starting a new Claude session against the same issue.
  - Working past clear signals that the test contract is malformed (see effort heuristic below).
- **Three terminal outcomes:**
  - ✅ **success** (`.done`) — tests green, CI passing → PR opened.
  - ❌ **gave-up** (`.failed`) — exhausted reasonable attempts but tests still red, OR PR opened but CI failing → PR remains open with explanation comment.
  - 🛑 **aborted** (`.aborted`) — test contract appears malformed → no PR opened. Root receives this and re-spawns the test agent with feedback (max one re-spawn per issue per wave; second abort escalates to human).
- **CI status is part of the terminal signal.** After opening a PR, the impl agent runs `gh pr checks --watch <pr#>` until CI completes, then writes its status file with `ci_status` set. A PR opened but failing CI is `outcome: "failed"`, not "success."
- **Always cleans up its tmux window** via shell chaining: `claude -p '...' ; gh pr checks --watch ... ; tmux kill-window`.

#### Impl agent effort heuristic (the "don't work too hard" rule)

The agent should choose its terminal outcome based on these signals:

| Signal | Outcome |
|---|---|
| Tests fail to **load/import** on first run, with errors that suggest test-side bugs (undefined symbols inside the test file, syntax errors, references to fixtures the issue body doesn't promise) | 🛑 abort immediately |
| After **3 distinct, plausible** implementation attempts targeting the apparent intent of the assertions, the tests still fail with the **same** assertion error pattern (suggesting the assertion is logically inconsistent or testing the wrong thing) | 🛑 abort |
| Tests require infrastructure clearly outside the issue's stated scope | 🛑 abort |
| **5+ varied** implementation attempts have been made, tests are still red, but the test contract appears valid and the problem seems genuinely hard | ❌ gave-up (open PR with explanation) |
| Tests green, CI green | ✅ success |
| Tests green, CI red | ❌ gave-up (CI failure) |

The "3" and "5" are guidelines, not hard limits — the agent uses judgment. The point is **bounded effort**: don't iterate forever on a malformed test, and don't open a PR that's clearly broken.

---

## 3. Architecture

### 3.1 tmux Topology

A single tmux server hosts all sessions. Sessions/windows are mutually addressable across the server.

```
tmux server (one)
├── session: roots                   ← human focuses here (the "dashboard")
│   ├── window: root-1
│   ├── window: root-2
│   └── window: root-3
├── session: ws-root-1               ← root-1's private workspace
│   ├── window: issue-3              (test agent for issue #3)
│   ├── window: issue-3-PR           (impl agent for issue #3)
│   ├── window: issue-7
│   ├── window: issue-7-PR
│   └── ...
├── session: ws-root-2
│   └── ...
└── session: ws-root-3
    └── ...
```

**Window naming convention:**
- Test agent window → `issue-<N>` (e.g. `issue-3`)
- Impl agent window → `issue-<N>-PR` (e.g. `issue-3-PR`)
- Root agent's dashboard window → `root-<id>` (e.g. `root-1`)

The human only watches the `roots` session. Workspace sessions can be noisy without polluting the dashboard.

### 3.2 Filesystem Layout

State and per-agent worktrees live under `.atdd/`, **namespaced by Root ID**. The directory must be gitignored.

```
<repo>/.atdd/                                ← gitignored (contents: *)
├── .gitignore                                    (single line: *)
├── root-1/
│   ├── meta.json                                 (root config: task slug, base branch, max wave count, wave size cap)
│   ├── wave-1/
│   │   ├── manifest.json                         (issues in this wave + expected count)
│   │   └── status/
│   │       ├── issue-3.done
│   │       ├── issue-7.failed
│   │       ├── issue-9.aborted
│   │       └── issue-11.paused                   (transient; cleared by Root)
│   ├── wave-2/
│   │   └── ...
│   └── worktrees/
│       ├── issue-3-tests/                        (worktree on branch issue-3-tests)
│       └── issue-3-impl/                         (worktree on branch issue-3-impl)
└── root-2/
    └── ...
```

**Worktree lifecycle.** Root creates a worktree for each test agent at wave-spawn time (`git worktree add .atdd/root-1/worktrees/issue-3-tests -b issue-3-tests <root-branch>`). The test agent creates the impl worktree before spawning its impl agent. On terminal status, Root prunes both worktrees (`git worktree remove --force ...`).

**Path discipline for status writes.** Worktrees see their own working tree, not the main repo's. Agents write status files to the **absolute path** of `.atdd/<root-id>/wave-N/status/`, which Root passes in their initial prompt. Do not rely on relative paths — the gitignored state directory only exists in the main repo's working tree.

**Status file contents (atomic-write JSON; write to `.tmp`, then `mv` to final name).** Terminal:

```json
{
  "issue": 3,
  "outcome": "success",                  // success | failed | aborted
  "pr_url": "https://github.com/org/repo/pull/42",
  "head_sha": "abc123...",
  "ci_status": "passing",                // passing | failing | no-checks | not-applicable
  "exit_reason": "tests green, CI passing"
}
```

Paused (transient):

```json
{
  "issue": 11,
  "state": "paused",
  "from": "test-agent",                  // test-agent | impl-agent
  "question": "The issue mentions 'auth middleware' but the codebase has both src/auth/ and src/middleware/auth/. Which do you mean?",
  "context_path": "/abs/path/.atdd/root-1/worktrees/issue-11-tests"
}
```

### 3.3 Git Branch Topology

```
main
└── agent-tdd/<root-task>          ← Root branch (wave integration target)
    ├── issue-3-tests              ← off Root, holds red tests (PUSHED to remote by test agent)
    │   └── issue-3-impl           ← off issue-3-tests, holds implementation
    │       → PR: issue-3-impl → agent-tdd/<root-task>
    ├── issue-7-tests
    │   └── issue-7-impl
    │       → PR: issue-7-impl → agent-tdd/<root-task>
    └── ...
```

**Rules:**
- `<root-task>` is human-supplied at Wave 0, validated against `^[a-z0-9-]+$`.
- All test branches in a wave are siblings off the Root branch.
- Each impl branch stacks 2-deep on its paired test branch (this is the *only* stacking allowed).
- All impl PRs target the Root branch.
- Test branches do not get their own PRs; the issue body's `Test Branch` section links to the test branch SHA.
- **Test branches must be pushed to origin by the test agent** before spawning the impl agent. Each agent works in a separate `git worktree` that fetches from origin — there is no shared filesystem between worktrees.

**Wave gating:** see §4.4 for the two thresholds. Wave N+1 only fires after Wave N reaches `wave-merged` — i.e. all successful PRs are actually merged to the Root branch.

When the entire workflow terminates, the Root branch merges to its configured base branch (`meta.json:base`, usually `main`) as the final integration step (human-confirmed; not automatic).

---

## 4. The Wave Lifecycle

### 4.1 Wave 0: Initial Setup (Manual)

1. Human opens a new tmux window in the `roots` session, named `root-<id>`.
2. Human launches `claude` in that window — this is the Root Agent.
3. Human and Root discuss the feature/bug at spec level.
4. Root creates the integration branch: `agent-tdd/<root-task>` off `main` (or off a configurable base).
5. Root initializes `.atdd/<root-id>/meta.json` (task slug, base branch, max wave count, wave size cap).
6. Human says "go" → Root transitions into autopilot orchestrator mode. From this point, the human only intervenes when Root explicitly raises hand.

### 4.2 Wave Initiation

For each wave, Root performs:

1. Decides the N issues to work on this wave.
   - Wave 1: from human discussion.
   - Wave 2+: Root-driven from the dedup'd `agent-tdd:pending` backlog. Root only raises to human if backlog is empty (terminating) or selection is unclear (see §4.5).
2. **Scope-discipline check** (see §4.6): rejects pairings likely to conflict, defers them to subsequent waves.
3. Creates N GitHub issues (or activates pending ones). Adds two labels:
   - `agent-tdd:active-wave-<N>`
   - `agent-tdd:root-<id>` *(present from issue creation, used for filtering)*
4. Creates the per-Root workspace session if it doesn't exist (e.g. `ws-root-1`).
5. Creates per-issue git worktrees under `.atdd/<root-id>/worktrees/issue-<N>-tests/`.
6. Spawns N test-agent windows in that session, each named `issue-<X>`, each pointed at one issue and at its worktree.
7. Issues a single **background Bash** event-watcher (see §6.1) — wakes Root on either terminal-threshold or first paused agent.

### 4.3 Mid-Wave Discovery

When any agent (test or impl) discovers something out-of-scope or a missing fixture:

| Discovery type | Action |
|---|---|
| **Related to current issue** (e.g. "this test needs more cases") | Comment on the existing issue |
| **Impl gave up** | Comment on existing issue with attempt summary; impl writes `.failed` status |
| **Test malformed** (impl agent's call) | No comment from impl — write `.aborted` with details. Root re-spawns test agent with the abort details as feedback |
| **Unrelated** (e.g. "we should also test fixture Y") | Create a new GitHub issue, label `agent-tdd:pending` *and* `agent-tdd:root-<id>`, link back to parent issue |

**Hard rule:** newly created issues are *static* — they do not trigger any agent during the current wave. They wait in the backlog for the next wave.

**No recursive spawning during a wave.** Test agents do not spawn other test agents. Impl agents do not spawn test agents. The only exception is **Root re-spawning** in response to an `.aborted` status (see §2 Impl Agent), which is bounded to one re-spawn per issue per wave.

### 4.4 Wave Completion: two thresholds

Wave completion has **two distinct gates**:

#### Gate 1: `agent-terminal`
Every agent in the wave has reached a terminal state:
- ✅ `.done` — impl PR opened, CI passing
- ❌ `.failed` — impl PR opened with "gave up" comment, OR PR opened but CI failing
- 🛑 `.aborted` — impl agent aborted (test malformed). Root must consume this — either re-spawn (resetting the issue to in-flight) or escalate; only after consumption does the wave's terminal count include it.

Paused agents are *not* terminal; the wave waits indefinitely for them to be resolved. This is intentional — fire-and-forget allows pause gates without timing out.

#### Gate 2: `wave-merged`
All `.done` PRs have been merged to the Root branch. Root drives this autonomously (auto-merge, auto-rebase) and only escalates to human on genuine semantic conflict or rebase-regression. See §4.7 for the procedure.

**Wave N+1 only fires after Gate 2.** The dashboard window name reflects current gate state (e.g. `root-1: wave-1 (agent-terminal, merging…)`).

### 4.5 Wave-to-Wave Handoff (Housekeeping)

On Gate 1 (`agent-terminal`), Root performs in order:

1. **Process aborted issues.** For each `.aborted`: re-spawn test agent once with the abort details as feedback. If the second pass also aborts, label the issue `agent-tdd:failed` and escalate to human via dashboard. Re-spawned agents return to in-flight; Gate 1 is re-evaluated when they finish.
2. **Dedup static issues** created during the wave. See §5.3.
3. **Drive Gate 2 (`wave-merged`).** For each `.done` PR, Root attempts to merge it (see §4.7 for the rebase ladder).
4. **Re-baseline**: pull the updated Root branch into Root's own working tree.
5. **Wave Review (autopilot).** Root reviews the dedup'd backlog. By default it picks the next wave's issues itself. It *only* raises hand to human if:
   - The backlog is empty (workflow may be terminating).
   - Issue selection is ambiguous (e.g. competing scopes that need human prioritization).
   - The wave produced unusually many failures (see §8 failure-rate guard).
6. Prune worktrees of completed issues.
7. Fire Wave N+1, or terminate if backlog is empty / max-wave-count reached.

### 4.6 Scope discipline (issue partitioning)

To minimize conflict and rebase work in Gate 2, Root applies a scope-discipline check before spawning a wave:

1. **Subject Under Test partitioning.** If two candidate issues have the same `Subject Under Test` (file or `path:symbol`), they are *not* parallelizable; defer one to a subsequent wave.
2. **File-path overlap heuristic.** If two issues' Subject Under Tests sit in the same module/directory and the issues are likely to touch the same files, prefer sequential waves. Root estimates overlap from the structured issue body and recent git history.
3. **Wave size cap.** A wave is limited to N parallel agents (default 5; configurable in `meta.json` as `wave_size_cap`). Larger candidate sets are split across multiple waves.

Scope discipline is heuristic, not a guarantee. Conflicts that slip through are handled by the rebase-failure escalation path (§4.7).

### 4.7 Rebase-failure escalation

When Root attempts to merge `.done` PRs in Gate 2 and hits a conflict, it follows this ladder:

1. **Trivial conflict** (mechanical: import order, formatting, lock files): Root performs the rebase itself in a temporary worktree, pushes, re-runs CI, merges if green.
2. **Non-trivial but mechanical conflict**: Root spawns a one-shot rebase agent (`claude -p`) targeted at the specific conflict. Same single-session/single-PR rules as impl agents. If green after rebase, merge. If not, escalate.
3. **Semantic conflict** (e.g. two PRs implement an overlapping feature in incompatible ways): Root cannot resolve. Marks the PR with `agent-tdd:rebase-blocked`, names the offending PRs in the dashboard window title, and waits for human to either:
   - Resolve manually and signal Root to retry merge.
   - Close one PR (defer to a subsequent wave) and let Root proceed.
4. **Rebase regression** (rebased cleanly, but CI now fails): Root marks the PR `agent-tdd:rebase-regression` and escalates to human. Root does *not* auto-spawn a fix agent — regressions imply the original test contract may need adjustment, which is a human call.

Wave N+1 does not fire while any rebase escalation is unresolved.

---

## 5. GitHub Issue Conventions

### 5.1 Labels

| Label | Meaning |
|---|---|
| `agent-tdd:pending` | In backlog, not yet assigned to a wave |
| `agent-tdd:active-wave-<N>` | Currently being worked by Wave N |
| `agent-tdd:root-<id>` | Owned by Root `<id>` (always present once Root touches the issue, used for filtering) |
| `agent-tdd:done` | Implementation merged |
| `agent-tdd:failed` | Impl agent gave up, second-pass abort, or otherwise unmergeable; PR open with explanation |
| `agent-tdd:rebase-blocked` | PR can't be auto-rebased; human needed |
| `agent-tdd:rebase-regression` | PR rebased clean but CI now fails; human needed |

**Label transitions** (driven by Root):

| Event | Transition |
|---|---|
| Wave start | `agent-tdd:pending` → `agent-tdd:active-wave-<N>` (also adds `agent-tdd:root-<id>` if missing) |
| Impl `.done` (CI green) | `agent-tdd:active-wave-<N>` → `agent-tdd:done` |
| Impl `.failed` | `agent-tdd:active-wave-<N>` → `agent-tdd:failed` |
| Impl `.aborted` (second pass) | `agent-tdd:active-wave-<N>` → `agent-tdd:failed` |
| Auto-merge clean | (no label change; `agent-tdd:done` already set) |
| Rebase ladder rung 3 | `agent-tdd:rebase-blocked` added |
| Rebase ladder rung 4 | `agent-tdd:rebase-regression` added |

Cheap filter for an agent: `gh issue list --label agent-tdd:active-wave-1 --label agent-tdd:root-1`.

### 5.2 Structured Issue Template

To make dedup and parsing tractable, every agent-created issue must follow:

```markdown
## Subject Under Test
<repo-relative POSIX path, optionally with `:identifier`. Examples:
  src/auth.ts
  src/auth.ts:validateToken
Always repo-root relative; never `./` prefix; always forward slashes.>

## Behavior
<one-sentence description of the contract>

## Type
unit | integration | property | regression

## Provenance
Spawned from #<parent-issue> during Wave <N> by Root <id>.
Reason: <why this was discovered>

## Test Branch (filled in by test agent)
`issue-<N>-tests` @ <commit-sha>

## Needs Clarification (optional; explicit pause marker)
<question — if this section exists when a test agent activates the issue,
the test agent will pause and ask Root before proceeding. Test agent
removes this section once Root resolves the question.>
```

When a test agent activates an existing pending issue, it updates only the `Test Branch` section (and removes `Needs Clarification` if Root resolved the question). It must not touch other sections.

### 5.3 Dedup Protocol

Two-layer dedup:

1. **Search-before-file** (agent-side): before any `gh issue create`, the agent runs `gh issue list --label agent-tdd:pending --label agent-tdd:root-<id>` and inspects titles + structured fields. If a candidate dupe exists, comment on the existing issue instead of filing a new one.
2. **Orchestrator pass** (Root-side, at wave completion): Root scans `agent-tdd:pending --label agent-tdd:root-<id>` issues created during this wave, compares structured fields (Subject + Behavior + Type), and merges/closes obvious dupes.

The standardized Subject Under Test format makes (2) a cheap field-equality check rather than fuzzy LLM comparison.

---

## 6. Coordination Mechanism

### 6.1 Agent → Root: Status Files + Background Bash (the key trick)

**The token-cost-saving insight is here. Read carefully.**

Every agent writes status atomically (`.tmp` → `mv`). Terminal states (`.done`, `.failed`, `.aborted`) are written by impl agents. The transient `.paused` state can be written by either test or impl agents.

```bash
# Inside the impl agent's final shell command
status_dir=/abs/path/.atdd/root-1/wave-1/status
cat > "$status_dir/issue-3.done.tmp" <<EOF
{"issue": 3, "outcome": "success", "pr_url": "...", "head_sha": "...", "ci_status": "passing"}
EOF
mv "$status_dir/issue-3.done.tmp" "$status_dir/issue-3.done"
```

Root waits using a **single background Bash event-watcher** that exits on either terminal-threshold or first paused agent:

```bash
# Issued ONCE via Bash(run_in_background=true)
expected=3
status_dir=.atdd/root-1/wave-1/status
while true; do
  terminal=$(ls "$status_dir" 2>/dev/null | grep -E '\.(done|failed|aborted)$' | wc -l)
  paused=$(ls "$status_dir" 2>/dev/null | grep '\.paused$' | head -1)
  if [ "$terminal" -ge "$expected" ]; then
    echo "EVENT=terminal"
    exit 0
  fi
  if [ -n "$paused" ]; then
    echo "EVENT=paused FILE=$paused"
    exit 0
  fi
  sleep 10
done
```

When Root resumes:
- `EVENT=terminal` → proceed to §4.5 housekeeping.
- `EVENT=paused` → read the paused file's question, decide:
  - **Answerable from context** → `tmux send-keys` the answer to the agent's window, delete the `.paused` file, re-issue the wait.
  - **Not answerable** → rename own dashboard window to indicate human attention needed, `notify-send`, wait for human input, then relay answer to agent and re-issue the wait.

**Why this is critical for token cost:**

| Approach | Token cost for a 1-hour wave |
|---|---|
| Naive poll every 30s in conversation | ~120 turns 💸💸💸 |
| Foreground blocking Bash (10-min cap) | ~6 turns (re-issue every 10 min) |
| **Background Bash + auto-notification** | **~2 turns total** ✅ |

`run_in_background=true` makes Root **idle during the wait — zero turns, zero tokens**. Claude Code automatically resumes Root when the background command exits. The wait phase costs ~2 turns total per wake-up regardless of wall-clock duration; pauses add ~3-5 turns each to handle.

**Verified (smoke-tested 2026-04-26):** Claude Code's background Bash does NOT inherit the 10-minute foreground cap. An 11-minute `sleep 660` ran to completion with auto-notification on exit. Background Bash is suitable for waves of arbitrary duration.

### 6.2 Root → Agent (cross-window control)

Root drives child agents by sending keystrokes into their tmux windows. Used for:
- Answering paused agents.
- Re-spawning aborted agents (kill old window, launch new one).
- Requesting amendments after Root reviews a PR.

```bash
# Answer a paused test agent
tmux send-keys -t ws-root-1:issue-11 'Use src/auth/middleware.ts — that is the canonical path.' Enter

# Resume the agent after clearing the paused signal
rm .atdd/root-1/wave-1/status/issue-11.paused
```

Re-spawning is a fresh `claude` invocation in the same window (after `tmux kill-window` + `tmux new-window`) with updated context including the abort feedback.

### 6.3 Root → Human: tmux Cross-Session Signals

The human watches the `roots` session. Root signals status by manipulating *its own window* in that session — visible at a glance.

```bash
# Status update in window name
tmux rename-window -t roots:root-1 'root-1: wave-1 (3 active)'
tmux rename-window -t roots:root-1 'root-1: wave-1 ⏸ paused (#5) — human input needed'
tmux rename-window -t roots:root-1 'root-1: wave-1 merging…'
tmux rename-window -t roots:root-1 'root-1: ALL DONE ✅'

# Transient status-bar message
tmux display-message -t roots: 'root-1: wave 1 done'

# OS-level pop-over (preferred for urgent attention)
notify-send "Agent TDD" "root-1: wave 1 done"                                     # Linux
osascript -e 'display notification "wave 1 done" with title "Agent TDD"'          # macOS

# Style change (red background = needs attention)
tmux set-window-option -t roots:root-1 window-status-style 'bg=red,fg=white'

# Bell (legacy fallback; many modern terminals ignore)
tmux send-keys -t roots:root-1 $'\a'
```

These do **not** inject keystrokes into Root's input buffer — they manipulate window metadata only, so they don't collide with whatever Root is doing.

### 6.4 Summary Table

| Direction | Mechanism | Why |
|---|---|---|
| Agent → Root | Status file + background Bash event-watcher | Durable, structured, ~zero idle tokens; supports terminal + paused |
| Root → Agent | `tmux send-keys` to agent's window | Direct control without spawning a new session |
| Root → Human (passive status) | `tmux rename-window`, status-line | At-a-glance dashboard |
| Root → Human (urgent) | `notify-send`/`osascript` + window restyle | Pulls attention without requiring tmux focus |
| Human → Root | Type into Root's window | Normal interactive flow |

**Hard rule: child agents never communicate with the human directly.** All human-facing escalations go through Root.

---

## 7. Failure Handling

| Failure | Handling |
|---|---|
| **Impl agent gave up** (tests still red after varied attempts) | PR opened with explanation; status `.failed`; window self-cleans. Wave continues. |
| **Impl agent CI failed post-PR** | Status `.failed` with `ci_status: failing`; PR remains open for Root review. Root may retry once after auto-rebase if conflict-induced. |
| **Impl agent aborted** (test malformed) | Status `.aborted`; no PR. Root re-spawns test agent (max 1 retry per issue per wave). Second abort → `agent-tdd:failed`, escalate to human. |
| **Test agent crash** | Status file missing; wave's background watcher does not advance. Root's dashboard reflects "stuck" once a heartbeat threshold passes. Human notices and intervenes. |
| **Wave gates on completion, not success** | A partially-failed wave still triggers wave-merged + Wave N+1 (provided merged PRs exist and any rebase escalations are resolved). |
| **Human-induced failure** (e.g. human closes a paused agent without resolving) | Status file missing; wave blocks. Human must explicitly mark it failed (`touch .atdd/<root-id>/wave-N/status/issue-X.failed`). |
| **Rebase-blocked / rebase-regression** | See §4.7 escalation ladder. |

---

## 8. Termination

The workflow ends when one of:

- A wave produces **zero new pending static issues** AND all current-wave issues are terminal AND `wave-merged` reached.
- **Max wave count** reached (default: **10**; configurable in `meta.json`). Root halts and surfaces remaining backlog to human.
- **Failure-rate guard:** if a wave produces zero successful merges and at least one `.failed` or `.aborted`, Root pauses and asks human whether to continue. Avoids degenerate loops where every wave fails the same way.

On clean termination, Root performs:

1. Merge the Root branch (`agent-tdd/<root-task>`) to its configured base branch (`meta.json:base`, usually `main`). (Human-confirmed.)
2. Close all `agent-tdd:done` issues.
3. Update the dashboard window: `root-<id>: COMPLETE ✅`.
4. Notify the human (`notify-send`).
5. Self-close after a confirmation prompt.

---

## 9. Token Cost Analysis (full workflow)

For a workflow with W waves and ~3 agents per wave:

| Phase | Per-wave cost | Total |
|---|---|---|
| Wave 0: spec discussion | — | variable (1× human session, often substantial) |
| Spawning agents + worktrees | ~1 turn per agent + 1 turn to issue background wait | ~4 turns/wave |
| **Waiting for wave** (idle in background Bash) | **~2 turns** if no pauses; +3-5 per pause handled | ~2-5W turns |
| Reviewing + dedup + planning + scope check | ~5-8 turns | ~6W turns |
| Auto-merge + rebase attempts | ~2 turns/PR (more if conflicts) | ~3W turns |
| Final integration | — | ~3 turns |

A 3-wave workflow costs roughly **~40 turns of orchestration** plus the agent sessions themselves and Wave 0 discussion. The wait phases — historically the expensive part — are nearly free thanks to background Bash.

---

## 10. The Notes Agent Layer (v0.10.0+)

v0.10.0 introduces a second human-facing agent above the Root Agent: the **Notes Agent** (`/agent-tdd:fix`). The Root Agent design in §1–§9 is unchanged. This section is the design rationale for the new upstream layer; its runtime contract lives in `skills/atdd-plan/CORE.md`.

### 10.1 What it solves

In a multi-repo system (e.g. an ERP composed of several services), preparing a sharp spec for `/atdd` is itself a long human-agent dialogue. The human spends disproportionate time reading the agent's investigation notes when all they actually need to sign off on is **Input/Output** and **any major architecture change** the work would force.

The Notes Agent moves that investigation out of the conversation. It investigates privately (logged into a per-project GitHub issue — the NotebookIssue), surfaces only the minimum the human needs to decide, and emits well-specced GitHub artifacts for `/atdd` to consume.

### 10.2 Design principles

1. **Result-driven dialogue.** The Notes Agent surfaces to the human ONLY three kinds of thing: (a) the **Input → Output** of the active head, (b) any **major infrastructure / architecture change** the work would force, (c) which single head is currently active. Everything else — trace, dead ends, full topology — goes to the NotebookIssue. This is what reclaims the human's time. No process narration, no praise, no emotion; machinery.

2. **Externalize before you speak.** Every detail and decision lives in GitHub before the agent relies on it. A multi-hour planning session will be compacted; GitHub is the only durable memory. The choice to make the notebook a GitHub Issue (not a local file) follows from this — it must survive compaction and be reachable from any machine.

3. **Native GitHub only.** Use native sub-issues (parent/child) and native issue dependencies ("blocked by"). Do not invent custom Project fields or a side-channel topology mechanism. Cross-repo sub-issues are verified working (2026-05-28, against `Positive-LLC/pg-agent-erp` ↔ `Positive-LLC/erp-b2b-otc`).

### 10.3 Three artifact kinds

| Artifact | Where | Audience | Purpose |
|---|---|---|---|
| **NotebookIssue** | home repo | Notes Agent only (private) | Working memory + topology index. Body = topology index (small, stable cached projection of live state). One comment per head, addressed by an HTML marker, holds that head's detailed notes — keeps each within the 65k single-comment cap. |
| **RootIssue** (a "head") | home repo | Notes Agent + human + `/atdd` | Distilled Input/Output + shared context that every SubIssue under it needs. The unit of human discussion (one head at a time) and the unit of root-level topology. |
| **SubIssue** | target repo (per-repo) | Notes Agent + human + `/atdd` | Per-repo work unit, linked as a **native sub-issue** of its RootIssue. The unit `/atdd` consumes — its body is the Wave-0 seed. |

The strictly separated audiences are what enables the result-driven goal: investigation accumulates in the notebook (the human is not expected to read it), while the human only sees distilled heads.

### 10.4 Topology

- **Dependencies live only between RootIssues**, never between SubIssues.
- **SubIssues of one RootIssue are strictly parallel-safe.** If an ordering dependency would emerge between two SubIssues, the rule is to **split the RootIssue in two** and put the dependency at the root level — not to encode intra-root order. This is what guarantees that any SubIssue of a "ready" head can be picked first.
- The graph is a DAG. Cycle prevention is enforced **at write time** by the `root-depend.sh` recipe (rejects self-loops, would-be cycles, and edges between non-RootIssues or across GitHubProjects). The Notes Agent never has to "validate" the graph after the fact — it is structurally clean by construction.
- The Notes Agent **never computes the graph in its head**. The `topology-*.sh` recipes (next-urgent / available / blocking / blocked-by) are the single source of truth. Pushing graph logic out of the LLM is what makes prioritization deterministic and saves tokens.

### 10.5 Handoff to the Root Agent (manual or orchestrated)

The unit of handoff is `/agent-tdd:atdd-from-issue <owner/repo> <#>`: it fetches the SubIssue body + the parent RootIssue body and delegates to `/atdd` with that union as the Wave-0 seed, skipping freeform spec discussion. From the Root Agent's perspective there are no API changes — only a new entry point that pre-fills `$ARGUMENTS`.

**Manual (plan-only):** the human runs that wrapper themselves, once per `atdd:ready` SubIssue. This is the fallback when the session isn't inside tmux, or when the human declines "go".

**Orchestrated (default, v1.0.0+):** after a single human "go", the Notes Agent runs each ready SubIssue itself, acting as each Root's human — supplying the Root's Wave-0 answers via the spawn environment and absorbing its escalations through signals. See §10.7. Original `/atdd` (free-form `$ARGUMENTS`) keeps working unchanged for tasks the human prefers to spec inline.

### 10.6 Completion semantics

A SubIssue closes when its `/atdd` run merges and it is closed — by the human in manual mode, or by the orchestrator in orchestrated mode (the spawned Root never edits the SubIssue; `/atdd` never closes it). A **RootIssue** is complete only when **all its SubIssues are closed** (the "join"). The Notes Agent — not `/atdd`, not automatic — closes the RootIssue, together with the human in a short review. The human's decision points are: the planning sign-offs, the orchestration "go" (which includes confirming a base branch per repo), and **each merge to base** (always human-confirmed, per (repo, base) — never batched into one rubber-stamp).

### 10.7 Orchestration (delegate mode, v1.0.0)

Preparing a sharp spec is one long human-agent dialogue (§10.1); *executing* a multi-repo plan is another, repeated once per SubIssue. Before v1.0.0 the human absorbed that second cost — running `/agent-tdd:atdd-from-issue` by hand for every ready SubIssue and watching each Root. Orchestration moves that loop, too, off the human: after a single "go", the Notes Agent drives the whole dependency graph and surfaces only genuine decisions. The human's role shifts from *operator* to **director/consultant** — they set scope and sequence at the "go", answer the rare question the planning artifacts don't, and confirm every merge to base; everything else runs unattended.

The shape was chosen on three axes (the human's explicit calls): **full protocol up front** (mirror the Root layer's rigor — state dir, an idle-cheap completion watcher, a session supervisor, hard ceilings — rather than a thin best-effort wrapper); **delegate, consult on exceptions** (one "go", then autonomous; interrupt the human only for genuine decisions or failures); and **one RootIssue at a time** (run the parallel-safe ready SubIssues of a single `topology-available` head together, up to a small concurrent-Root cap, then advance).

Four design commitments make this safe and durable:

- **The orchestrator is each Root's human; the Root layer is untouched.** A spawned Root talks to "its human" exactly as before — Wave-0 questions, escalations, the final-merge confirmation. The orchestrator simply *is* that human: it supplies Wave-0 answers through the spawn environment and reads escalations from the Root's signal. `/atdd` and PROTOCOL.md never learn they're being orchestrated (the only additions are environment-gated no-ops). This is what keeps the manual handoff working unchanged and avoids a forked execution layer.
- **GitHub stays the completion truth; coordination is local.** Polling GitHub for liveness would be slow and rate-limited, so the orchestration layer uses local per-Root signal files + tmux window state to learn "is this Root asking / stuck / done / dead" — a scoped exception to §1.5's "only via GitHub". But "work done" is still authoritative on GitHub (a merged PR + a closed SubIssue), and every escalation and its answer is **also** mirrored to a SubIssue comment, so a compacted or relocated orchestrator reconstructs in-flight decisions from GitHub, preserving the resumability the GitHub handoff was chosen for.
- **Irreversible actions always reach the real human.** The base branch is confirmed per repo at the "go" (never defaulted — the one value the system refuses to infer), and the merge-to-base is confirmed per (repo, base) and performed by the orchestrator via `gh pr merge` after that confirmation — never auto-merged, never batched into a single rubber-stamp, and never delegated to a `send-keys "yes"` into a Root pane that might have died. A single gh account is used for the whole run, which makes the global `gh auth switch` race benign (every Root switches to the same account); per-repo distinct accounts are deferred.
- **Failure is observable.** A spawned Root is the longest-lived child in the system, so it gets a session supervisor (the `launch-root.sh` analogue of the impl supervisor) that writes a `crashed` signal on silent death, and the watcher flags a Root whose window vanished without a clean terminal. A globally-unique workspace session name per Root prevents two Roots that claim the same repo-local `root-id` from colliding on one tmux session. The orchestrator re-derives its live-Root set from disk + GitHub after any compaction, rediscovering a Root the registry lost.

The operational contract — the orchestration loop, the watcher event protocol, the consultation policy, and the compaction defense — is `skills/atdd-plan/ORCHESTRATE.md`, which is authoritative over this section exactly as PROTOCOL.md is authoritative over §1–§9.

---

## Appendix A: Concrete Command Recipes

### Initialize a Root

```bash
# In Root's window (main repo working tree, on main):
mkdir -p .atdd/root-1
echo '*' > .atdd/.gitignore
git checkout -b agent-tdd/<root-task> main
git push -u origin agent-tdd/<root-task>
# Root writes meta.json:
# { "task": "<root-task>", "base": "main", "max_waves": 10, "wave_size_cap": 5 }
```

### Spawn a test agent (from Root)

```bash
# Create the worktree
git worktree add .atdd/root-1/worktrees/issue-3-tests \
  -b issue-3-tests agent-tdd/<root-task>

# Create the tmux window in the workspace, anchored to the worktree
tmux new-window -t ws-root-1: -n issue-3 \
  -c "$PWD/.atdd/root-1/worktrees/issue-3-tests"
tmux send-keys -t ws-root-1:issue-3 'claude' Enter

# Wait for prompt (more robust than a fixed sleep)
until tmux capture-pane -p -t ws-root-1:issue-3 | grep -q '^>'; do sleep 1; done

tmux send-keys -t ws-root-1:issue-3 \
'You are a test agent for issue #3 under root-1, wave-1.
Read the issue: gh issue view 3
If the issue body has a "## Needs Clarification" section, write
  /abs/path/.atdd/root-1/wave-1/status/issue-3.paused
with the question and wait for an answer (delivered via tmux send-keys).
Otherwise: build red tests on this worktree (branch issue-3-tests).
Push the branch: git push -u origin issue-3-tests
Update the issue body Test Branch section with the SHA.
Spawn your impl agent (see protocol).
Self-close. (Status file is the impl agent'"'"'s job; you only write
.paused if you pause.)' Enter
```

### Spawn an impl agent (from a test agent, fire-and-forget)

```bash
# Create the impl worktree (stacked off test branch)
git worktree add /abs/path/.atdd/root-1/worktrees/issue-3-impl \
  -b issue-3-impl issue-3-tests

# Spawn the agent window
tmux new-window -t ws-root-1: -n issue-3-PR \
  -c /abs/path/.atdd/root-1/worktrees/issue-3-impl

tmux send-keys -t ws-root-1:issue-3-PR \
"claude -p 'You are an impl agent for issue #3, root-1, wave-1.
You are on branch issue-3-impl stacked on issue-3-tests.
Single Claude session, single PR. Iterate within session as needed.
Effort heuristic:
  - Tests fail to load with test-side errors -> abort.
  - Same assertion error after 3 distinct attempts -> abort.
  - 5+ varied attempts, still red, contract looks valid -> gave-up.
  - Tests green + CI green -> success.
After opening PR: gh pr checks --watch <pr#>
Write status to /abs/path/.atdd/root-1/wave-1/status/issue-3.{done,failed,aborted}
(atomic: .tmp + mv).
If aborted, do NOT open a PR.' \
  --dangerously-skip-permissions ; tmux kill-window" Enter
```

### Root waits for wave (background Bash event-watcher)

```bash
# Bash(run_in_background=true)
expected=3
status_dir=.atdd/root-1/wave-1/status
while true; do
  terminal=$(ls "$status_dir" 2>/dev/null | grep -E '\.(done|failed|aborted)$' | wc -l)
  paused=$(ls "$status_dir" 2>/dev/null | grep '\.paused$' | head -1)
  if [ "$terminal" -ge "$expected" ]; then echo "EVENT=terminal"; exit 0; fi
  if [ -n "$paused" ]; then echo "EVENT=paused FILE=$paused"; exit 0; fi
  sleep 10
done
```

### Root drives Gate 2 (wave-merged)

```bash
# For each .done status:
gh pr merge <pr#> --squash --auto || {
  # Conflict — fall through to rebase ladder (§4.7)
  git fetch origin
  # ... attempt rebase, push, retry CI, merge, or escalate ...
}
```

### Root signals human on wave completion

```bash
tmux rename-window -t roots:root-1 'root-1: wave-1 done — review backlog'
tmux display-message -t roots: 'root-1: wave 1 complete'
notify-send "Agent TDD" "Wave 1 done — review backlog"
```

### Root prunes worktrees on terminal

```bash
git worktree remove --force .atdd/root-1/worktrees/issue-3-tests
git worktree remove --force .atdd/root-1/worktrees/issue-3-impl
```

---

## Appendix B: Glossary

- **Root Agent** — the orchestrator; human-launched, lives in `roots:root-<id>`. Operates in autopilot from Wave 1 onward. Sole human interface.
- **Wave** — a bounded batch of parallel test+impl pairs; gated by `agent-terminal` then `wave-merged`.
- **Static issue** — a GitHub issue created during a wave that does not trigger an agent until a future wave activates it.
- **Pair** — one (test agent, impl agent) tuple working a single issue.
- **Terminal state** — any of: `.done` (success), `.failed` (gave up or CI failed), `.aborted` (test malformed). Paused is *not* terminal.
- **Agent-terminal (Gate 1)** — every agent in the wave has reached a terminal state.
- **Wave-merged (Gate 2)** — all `.done` PRs have been merged to the Root branch.
- **Single-session, single-PR rule** — an impl agent runs one Claude session and produces at most one PR; iteration within session is permitted, spawning new agents is not.
- **Effort heuristic** — the "don't work too hard" rule that bounds an impl agent's iteration before it terminates as `aborted` or `gave-up` (see §2).
- **Scope discipline** — the pre-wave check that partitions issues to minimize file-overlap conflicts.
- **Rebase-failure escalation** — the ladder Root follows when a `.done` PR can't auto-merge cleanly (§4.7).
- **Notes Agent** — the planning agent added in v0.10.0. Entry: `/agent-tdd:fix` (and, later, `/agent-tdd:feature`). Upstream of the Root Agent. See §1.5, §10, and `skills/atdd-plan/CORE.md`.
- **NotebookIssue, RootIssue, SubIssue** — the three artifact kinds the Notes Agent produces; see §10.3.
- **GitHubProject** — the shared Projects-v2 board on which the Notes Agent aggregates RootIssues and SubIssues across the system's repos.
- **`/agent-tdd:atdd-from-issue`** — thin Root Agent entry point that pre-fills `$ARGUMENTS` from a planned SubIssue + its parent RootIssue body, then delegates to `/atdd` skipping freeform spec discussion.
