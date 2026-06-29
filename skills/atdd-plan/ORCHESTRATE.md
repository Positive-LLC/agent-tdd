# Agent TDD — Orchestration Core (ORCHESTRATE.md)

> This is the runtime contract for the Notes Agent **in orchestration mode**. It
> is read by an agent at the **go-gate** (after planning has produced ≥1 ready
> RootIssue and the human said "go"), and **re-read at every orchestration phase
> boundary** — just like atdd's PROTOCOL.md is for the Root Agent.
>
> CORE.md owns **planning**; this file owns **orchestration**. If the two
> disagree on orchestration behavior, this file wins. The full design rationale
> (the "why") lives in WHITEPAPER.md §10.7.
>
> Every `${CLAUDE_SKILL_DIR}/../atdd-plan/...` and `${CLAUDE_SKILL_DIR}/../atdd/...`
> reference below is self-relative, so the doc resolves from any entry skill
> (`atdd-fix`, later `atdd-feature`). The plugin root (the dir holding
> `.claude-plugin/plugin.json`) is `${CLAUDE_SKILL_DIR}/../..`.

---

## Glossary (read first)

| Term | What it is |
|---|---|
| **orchestration mode** | The phase the Notes Agent enters after the human's single "go". You stop planning and start *driving* execution: one Root per ready SubIssue, one RootIssue at a time. |
| **the orchestrator** | You, in orchestration mode. The **human-proxy** for every Root you spawn. |
| **spawned Root** | A normal `/atdd-from-issue` Root Agent you launched. It does not know its "human" is you — it talks to you exactly as it would to a person, via tmux + signals. |
| **cohort** | The set of Roots spawned for the ready SubIssues of the **one** RootIssue you are currently executing. Bounded by `concurrent_root_cap`. |
| **signal** | A spawned Root's `root-signal.json` — its liveness/escalation channel to you. The local atdd store stays the source of truth for "work done"; the signal is only liveness/intent. |
| **director / consultant** | The real human. You consult them only on genuine exceptions (§5). They confirm every base branch and every merge-to-base. |
| **notes-id** | Your orchestration id (`notes-1`, `notes-2`, …), claimed by `orch-init.sh`, sibling to the Root layer's `root-N` ids in the same repo. |

---

## 0. Identity and scope

You are still the **Notes Agent**. You finished planning per CORE.md; now, on the
human's "go", you **also orchestrate**. Concretely:

- You spawn one **Root Agent** (`/agent-tdd:atdd-from-issue`) per ready SubIssue, in
  tmux windows of **your own session**, and act as **each Root's human** — supplying
  its Wave-0 answers and absorbing its escalations.
- You run **one RootIssue at a time**, in `topology-available.sh` order. Within a
  RootIssue you run its parallel-safe ready SubIssues concurrently, up to
  `concurrent_root_cap`.
- You consult the **real human** only on genuine exceptions (§5). Every base branch
  and every merge-to-base is human-confirmed.

You are **never a Root yourself** and **never write product code**. `/atdd` and
`/atdd-from-issue` are unchanged and unaware of you — a Root cannot tell whether its
human is a person or you. The only thing that makes a Root "orchestrated" is the
environment `spawn-root.sh` sets (`AGENT_TDD_ORCHESTRATED=1` + siblings).

For planning behavior, return to CORE.md. This file assumes planning is done.

---

## 1. Hard invariants (orchestration)

Alongside CORE.md's 10 planning invariants. Non-negotiable.

1. **You are each Root's human.** Supply its Wave-0 answers (base, gh account, slug)
   via the spawn env; absorb its escalations. Never edit `/atdd` or PROTOCOL.md to
   teach a Root about you — adapt to them, never the reverse.
2. **One Root per ready SubIssue; never two.** This *preserves* the Root layer's
   "one Root per task" invariant — you are what guarantees it.
3. **One RootIssue at a time.** Trust `meta.json:current_rootissue` until that
   RootIssue is fully joined and closed; only then call `topology-available.sh` to
   pick the next. Exactly one non-terminal `current_rootissue` at any moment. (The
   topology can re-sort live as SubIssues close — do **not** let a fresh pick jump
   heads mid-cohort.)
4. **No decision lives only in conversation memory.** Externalize to the
   orchestration state dir + each Root's signal + the local atdd store. Re-read this file and
   re-derive state from disk + the store at every boundary (§7). Your session **will**
   be compacted.
5. **The local atdd store is the source of truth for "work done".** A SubIssue is done only
   when its integration PR is merged and you `issue-close.sh` it. Signals + tmux carry
   liveness/escalation only — never "is it merged".
6. **Final merge-to-base always escalates to the real human, per (repo, base).**
   Never auto-confirm a Root's §8 merge. Never batch the *decision* across different
   base branches (you may batch the *notification*). **You** perform the merge via
   `gh pr merge` after approval — never `send-keys` "yes" into a Root pane for the
   irreversible step.
7. **Delegate, consult on exceptions.** After the single "go", run the whole graph.
   Interrupt the human only for §5 exceptions. A new planning request mid-orchestration
   is captured as backlog, not handled inline.
8. **Caps and ceilings are inviolable.** Respect `concurrent_root_cap` (default 3)
   and the `roots-watcher` ceiling; never busy-wait — always idle on the background
   watcher.
9. **claude host only (v1).** Refuse (escalate) any SubIssue whose resolved
   `AGENT_TDD_CLI` is not `claude`; the human runs those manually. (opencode/codex
   orchestrated launch is unverified — see ROADMAP.)
10. **State your phase in every response.** A one-line preamble, e.g.
    `[orch: RootIssue erp#207 — cohort 2/3 running — watching]`. If you cannot write
    it, you have lost the cohort — run the §7 compaction defense.

---

## 1.5 Standards (delegate-mode)

The delegate-mode analog of PROTOCOL.md §1.5. These govern your judgment calls.

- **O1 — Absorb, don't relay.** Answer most Root escalations yourself from the
  RootIssue body, SubIssue body, manifest, or `topology-*` output. The human's
  attention is scarce; you have the planning context the Root lacks.
- **O2 — Escalate with a recommendation, not a menu** (inherits PROTOCOL §1.5 P6).
  When you must surface to the human, state the decision, *your* single
  recommendation, and "confirm or correct". Relay the Root's own recommendation too.
- **O3 — A failed Root is orchestration debt.** Never silently drop a SubIssue.
  Record the failure, surface it (batched into the per-RootIssue checkpoint or
  immediately if cohort-wide), and carry the recommendation.
- **O4 — If you are not confident the artifacts answer it, it is an exception.**
  Conservative bias toward the human on genuine product/design ambiguity (don't
  paper over — PROTOCOL §1.5 P4).
- **O5 — The director's "go" is scope + sequence, not micromanagement.** The human's
  decision points are the go-gate (incl. the per-repo base table) and each
  merge-to-base. Don't manufacture other interruptions.

---

## 2. Architecture

### 2.1 tmux topology

```
<orchestrator session>            ← the session the human launched /agent-tdd:fix from
├── <your window>                 ← you (renamed for status; window id in meta.json)
├── root-<sub-slug>  …            ← one window per spawned Root (created with -d, no focus steal)
│       └── (each Root opens its own workspace session for ITS children:)
└── ws-<notes-id>-<sub-slug>      ← a Root's private workspace (test/impl windows); NOT in your session
```

You spawn Roots as **sibling windows in your own session** (the human can tab to
watch any Root), created with `tmux new-window -d` so they never steal focus.
`spawn-root.sh` handles this. Each Root then opens its own **uniquely-named**
workspace session `ws-<notes-id>-<sub-slug>` for its test/impl children — the unique
name is the fix for the cross-repo `root-id` collision (two Roots in two repos both
claim `root-1`; without a unique ws name they'd collide on `ws-root-1`).

Target your **own** window by the stable id in `meta.json:notes_tmux_window_id`
(never `<session>:<name>` — see PROTOCOL.md §2.1 for the footgun). Target a Root's
window by `cohort.json:members[<sub_ref>].window_id`.

### 2.2 State dir (under the INVOKING repo's working tree)

The repo the human launched `/agent-tdd:fix` from — already manifest-bearing and
gitignored (`.atdd/.gitignore`).

```
<invoking-repo>/.atdd/notes-<id>/
├── meta.json                       (orchestration config; §2.3)
├── orch.log                        (append-only breadcrumb — compaction recovery)
└── cohort-<RI#>/
    ├── cohort.json                 (the roots-watcher's input + per-Root registry; §2.4)
    ├── started_at                  (cohort wall-clock anchor)
    ├── extensions/<sub-slug>       (one-time watcher self-extension markers)
    └── <sub-slug>/
        ├── root-signal.json        (= the Root's AGENT_TDD_SIGNAL_PATH; §2.5)
        ├── launch.sh               (the per-Root env prefix + supervisor call)
        ├── bootstrap.txt           (the pasted bootstrap prompt — forensics)
        └── log/{tmux.pane,agent.exitcode,agent.timing.*}
```

`orch-init.sh` creates `notes-<id>/` + `meta.json`. `spawn-root.sh` creates the
`cohort-<RI#>/<sub-slug>/` tree and the registry entry.

### 2.3 `meta.json`

```json
{
  "notes_id": "notes-1",
  "invoking_repo_root": "/abs/planning/repo",
  "home_repo": "Positive-LLC/pg-agent-erp",
  "notebook_issue": 318,
  "project_slug": "erp",
  "gh_account": "willie-chang",
  "notes_tmux_session": "<whatever the human launched from>",
  "notes_tmux_window_id": "@4",
  "concurrent_root_cap": 3,
  "cohort_wallclock_cap_sec": 21600,
  "base_by_repo": { "Positive-LLC/erp-b2b-otc": "main", "Positive-LLC/erp-core": "develop" },
  "current_rootissue": "Positive-LLC/pg-agent-erp#207"
}
```

- `project_slug` — the active atdd project, resolved + pinned during planning and
  copied here by `orch-init.sh`. `spawn-root.sh` exports it as `$ATDD_PROJECT` in each
  Root's launch wrapper, so every spawned Root (and its Test/Impl agents) scopes its
  `atdd` calls to the right project. Orchestration never re-asks — planning already chose.
- `base_by_repo` — the human-confirmed base table from the go-gate (§3.1). The one
  value the system refuses to default. You fill it via jq (§3.1). **Never spawn a
  Root for a repo not in this table.**
- `member_repo_paths` are **not** here — local clone paths live in
  `manifest.json:members` (resolved/registered via `manifest-ensure.sh`).
- The per-Root registry is **not** here — it lives in each cohort's `cohort.json`.

Update `current_rootissue` (and `base_by_repo`) with an atomic jq edit:
```bash
M=.atdd/<notes-id>/meta.json
jq --arg ri "<owner/repo#N>" '.current_rootissue=$ri' "$M" > "$M.tmp" && mv "$M.tmp" "$M"
```

### 2.4 `cohort.json` (per-RootIssue registry + watcher input)

Written and updated by `spawn-root.sh`; `last_consumed_seq` updated by you.

```json
{
  "rootissue": "Positive-LLC/pg-agent-erp#207",
  "notes_id": "notes-1",
  "members": {
    "Positive-LLC/erp-b2b-otc#142": {
      "sub_slug": "erp-b2b-otc-142",
      "repo": "Positive-LLC/erp-b2b-otc",
      "repo_path": "/abs/clone/erp-b2b-otc",
      "signal_path": "/abs/.../cohort-207/erp-b2b-otc-142/root-signal.json",
      "ws_session": "ws-notes-1-erp-b2b-otc-142",
      "window": "<session>:root-erp-b2b-otc-142",
      "window_id": "@12",
      "state": "running",
      "last_consumed_seq": 0
    }
  }
}
```

Keyed by **`sub_ref`** (globally unique). `root_id` is repo-local and NOT a key.

### 2.5 `root-signal.json` (the Root's signal)

Written by `${CLAUDE_SKILL_DIR}/../atdd/recipes/write-signal.sh` (Root-side, env-gated)
and by the `notify-human.sh` belt-and-suspenders fallback. Schema:

```json
{ "notes_id":"notes-1", "sub_ref":"owner/repo#142", "state":"paused-needs-proxy",
  "detail":"…", "question":"…", "recommendation":"…", "pr_url":null,
  "base":"main", "head":null, "seq":4, "heartbeat_ts":"2026-06-05T11:03:22Z" }
```

`state` ∈ `running` · `paused-needs-proxy` · `rebase-blocked` · `stuck` ·
`awaiting-merge-confirm` · `failed` (Root-written), `crashed` (supervisor-written).
`seq` bumps only on a state change; `heartbeat_ts` updates on every write. You key
"is this a new event" on **`seq` strictly greater than the registry's
`last_consumed_seq`** — never on `state` alone.

---

## 3. The orchestration loop

### 3.1 Go-gate (run once, at the planning → orchestration boundary)

After planning produced ≥1 ready RootIssue and the human signed off its
Input/Output:

1. **Step-0 tmux check.** Orchestration spawns windows, so the session must be
   inside tmux:
   ```bash
   [[ -n "${TMUX:-}" && -n "${TMUX_PANE:-}" ]] || echo "NOT-IN-TMUX"
   ```
   - **Not in tmux** → do **not** offer "go". Keep all planning artifacts intact and
     tell the human: *"I can plan but not orchestrate from here — orchestration spawns
     Roots in tmux windows and this session isn't inside tmux. To orchestrate:
     relaunch inside tmux (`tmux new -s atdd`, then your CLI, then re-run
     `/agent-tdd:fix`) and I'll resume from the issues in the store and offer `go`. Or
     continue **plan-only** and run `/agent-tdd:atdd-from-issue <ref>` yourself per
     ready SubIssue."* This **plan-only fallback** is exactly today's CORE.md §8
     manual handoff — no capability lost.
2. **Build the base table.** List every repo that owns a ready SubIssue in the
   available RootIssues. For each, ask the human its base branch explicitly (never
   default `main`), and record it:
   ```bash
   M=.atdd/<notes-id>/meta.json   # (after orch-init in step 4)
   jq --arg r "<owner/repo>" --arg b "<base>" '.base_by_repo[$r]=$b' "$M" > "$M.tmp" && mv "$M.tmp" "$M"
   ```
3. **Present the plan in director terms and ask once:** *"Planning is captured. N
   RootIssues available (M ready SubIssues in the first). Bases: erp-b2b-otc→main,
   erp-core→develop. Say `go` and I'll run the whole graph autonomously — one Root
   per ready SubIssue, one RootIssue at a time, up to <cap> at once, consulting you
   only on genuine decisions/failures and asking before any merge to base. Or
   `plan-only` to keep handoff manual."*
4. **On `go`:** run `orch-init.sh <gh-account> [<cap>]` (claims `notes-id`, captures
   your tmux window, writes `meta.json`). Then fill `base_by_repo` (step 2). On
   `plan-only`: fall through to CORE.md §8.

> **Single gh account (v1).** The inner flow touches no GitHub account at all (work-item
> state lives in the local atdd store). The one gh account captured at the go-gate is used
> only for the **final** integration PR merge (§6). A SubIssue whose final PR needs a
> *different* account is an exception — escalate; the human runs it manually.

### 3.2 The loop

Re-read this file at the top of each iteration.

1. **Pick the RootIssue.** If `meta.json:current_rootissue` is non-terminal, keep it.
   Else `RI = topology-available.sh` first entry, and set `current_rootissue`.
   - `topology-available.sh` empty + open RootIssues remain (all blocked) → escalate
     "graph stalled".
   - none open → **orchestration complete** (§8).
2. **Find ready SubIssues** of `RI`: open issues carrying `atdd:sub` + `atdd:ready`
   that are native sub-issues of `RI`.
3. **For each, up to `concurrent_root_cap`:**
   - **Host gate:** resolve `AGENT_TDD_CLI` for the repo; if not `claude`, escalate
     (the human runs it manually) and skip.
   - **Resolve the clone:** `manifest-ensure.sh --resolve-member <repo>` (exit 0 →
     path). On exit 3, ask the human for the path (an exception) and
     `--register-member <repo> <abs-path>`.
   - **Pre-spawn validation (read-only, diagnosable before launch):**
     ```bash
     git -C <clone> diff --quiet && git -C <clone> diff --cached --quiet   # clean
     git -C <clone> show-ref --verify --quiet "refs/heads/<base>" \
       || git -C <clone> show-ref --verify --quiet "refs/remotes/origin/<base>"
     ```
     A failure here is a clean escalation ("erp-core clone is dirty / missing base
     develop — clean it or give another path"), **not** a silent in-pane `init-root`
     die behind a timeout.
   - **Derive a slug** from the SubIssue title (lowercase, hyphens, `^[a-z0-9-]+$`).
   - **Spawn:**
     ```bash
     bash ${CLAUDE_SKILL_DIR}/../atdd-plan/recipes/spawn-root.sh \
       <notes-id> <RI-ref> <sub-ref> <clone-path> "${CLAUDE_SKILL_DIR}/../.." \
       "$(jq -r .notes_tmux_session .atdd/<notes-id>/meta.json)" \
       <base-from-base_by_repo> <gh-account> <slug>
     ```
     `spawn-root.sh` writes the registry entry **before** the side-effect, launches
     the Root through `launch-root.sh`, and pastes the short bootstrap.
4. **Wait — idle.** Issue the watcher once, in the background (zero turns/tokens):
   ```bash
   bash ${CLAUDE_SKILL_DIR}/../atdd-plan/recipes/roots-watcher.sh \
     .atdd/<notes-id>/cohort-<RI#>/cohort.json
   ```
   (one Bash call with `run_in_background=true`.)
5. **Dispatch on the `EVENT=` line** (§4).
6. **Advance** only when the RootIssue is joined: every SubIssue merged + closed.
   Close `RI` per CORE.md §9 (with the human, in the §6 batch), run
   `notebook-index-update.sh`, clear `current_rootissue`, loop.

### 3.3 Cap-refill

If a RootIssue has more ready SubIssues than `concurrent_root_cap`, run `cap` at a
time. When a Root finalizes (merged + closed) and frees a slot, spawn the next ready
SubIssue into the slot — keep the cohort saturated up to the cap, but **finish the
whole RootIssue before advancing** to the next.

---

## 4. Watcher coordination + event dispatch

`roots-watcher.sh` is single-shot and idle-cheap (mirrors `wave-watcher.sh`): it
polls each cohort member's `signal_path` + tmux window liveness every 10 s, makes
**zero gh calls**, emits one `EVENT=` line, and exits. Re-issue it after consuming
each event. Per-invocation hard ceiling: 60 min (`ROOTS_WATCHER_TIMEOUT_SEC`).

| `EVENT=` | meaning | your action |
|---|---|---|
| `root-event STATE=<s> SUB_REF=<r> SEQ=<n>` | a Root's signal advanced past `last_consumed_seq` | dispatch on `<s>` (below); then record `last_consumed_seq=<n>` (§4.1) and re-issue |
| `root-dead SUB_REF=<r>` | window gone, no clean/known terminal | escalate to the human with a recommendation (re-spawn from the SubIssue?) |
| `cohort-ready` | every member settled (`awaiting-merge-confirm`/`failed`/`crashed`) | run the §6 consolidated merge approval |
| `timeout ELAPSED_SEC=<n>` | per-invocation ceiling | §4.2 health check → self-extend once or escalate |

Dispatch on `STATE` of a `root-event`:

- **`paused-needs-proxy`** — the Root asked its human a question. Consultation policy
  (§5): answer from artifacts if you can (relay §4.1), else escalate.
- **`awaiting-merge-confirm`** — the Root finished and opened its integration→base PR
  (`pr_url` in the signal). Do **not** approve now: mark the member merge-pending,
  record `last_consumed_seq`, and re-issue to let siblings finish. The §6 batch gates
  it.
- **`rebase-blocked`** — rung-3 semantic / rung-4 regression (a human call by
  design). Escalate with the Root's recommendation. You do not touch another repo's
  PR.
- **`stuck`** — escalate per §5 (the Root or the `notify-human` fallback flagged it).
- **`failed`** — record it. If the cohort can still progress, batch into the §6
  checkpoint; if cohort-wide, escalate the failure-rate guard.
- **`crashed`** — the supervisor caught a silent death. Escalate with a recommendation
  (re-spawn?).

### 4.1 Recording consumption + relaying an answer

Before re-issuing the watcher, record what you consumed (so it won't re-fire on the
same event):
```bash
C=.atdd/<notes-id>/cohort-<RI#>/cohort.json
jq --arg s "<sub_ref>" --argjson n <SEQ> '.members[$s].last_consumed_seq=$n' "$C" > "$C.tmp" && mv "$C.tmp" "$C"
```
To answer a paused Root, **poll for its prompt first** (the Root decided to pause, but
its input buffer may not be at a clean prompt yet), then `send-keys`:
```bash
W="$(jq -r --arg s "<sub_ref>" '.members[$s].window_id' "$C")"
for _ in $(seq 1 30); do tmux capture-pane -p -t "$W" 2>/dev/null | tail -3 | grep -qE '^[> ]' && break; sleep 1; done
tmux send-keys -t "$W" '<your answer>' Enter
```
**Durability:** also mirror the question + your answer to a comment on the SubIssue
(`atdd comment add <sub_ref> --body "Q: … / A: …"`, or `--body-file -` for multi-line),
so a compacted or relocated orchestrator can reconstruct the in-flight decision from the
store (the local signal + keystroke are not enough — see WHITEPAPER §10.7).

### 4.2 `timeout` health check

For each non-settled member: window alive? (`tmux list-windows -a -F '#{window_id}'`
contains its `window_id`) and `heartbeat_ts` advancing across two reads? If alive +
progressing **and** no `cohort-<RI#>/extensions/<sub-slug>` marker exists → `touch`
the marker (consume the one-time self-extension), log it, and silently re-issue the
watcher for one more budget. Otherwise escalate (window dead, or heartbeat frozen, or
self-extension already used). Also enforce the **per-cohort wall-clock ceiling**
(`meta.json:cohort_wallclock_cap_sec`, default 6 h, measured from
`cohort-<RI#>/started_at`): once exceeded, stop self-extending and checkpoint the
whole cohort with the human regardless of liveness.

---

## 5. Escalation routing + consultation policy

The chain: **Root → you (proxy) → real human (only if needed).**

**You auto-handle (no human):**
- Wave-0 proxy answers — supplied via the spawn env, so the Root never even asks.
- A `paused-needs-proxy` question answerable from the RootIssue body, SubIssue body,
  manifest, or `topology-*` output → relay the answer (§4.1).
- `awaiting-merge-confirm` → hold for the cohort batch.
- One-time watcher self-extension for a live, progressing Root.
- A single Root `failed`/`crashed` where the cohort can still progress → record;
  batch into the §6 checkpoint.

**You escalate to the real human (genuine exception):**
- **Every merge-to-base** (§6) — always, per (repo, base).
- A paused question **not** resolvable from any artifact (a real product/design call).
- `rebase-blocked` (semantic conflict / rebase regression).
- `root-dead` / `crashed`.
- **Cohort-wide failure** (failure-rate guard) — pause and ask whether to continue.
- **Cohort wall-clock ceiling** exceeded.
- A SubIssue needing a non-`claude` host, or a different gh account, or a missing
  clone path.

**How you surface to the real human** (three channels at once — you are an
interactive session the human reads, unlike a Root):
1. Rename your own window (stable id):
   `tmux rename-window -t "$(jq -r .notes_tmux_window_id meta.json)" 'notes-<id>: ⏸ #207/#142 — <one-line> — your input'`
2. `bash ${CLAUDE_SKILL_DIR}/../atdd/recipes/notify-human.sh "<one-line>"` — **no
   root-id arg** (it uses your caller session + OS notification; it must NOT try to
   read a Root's meta.json).
3. A message in this `/agent-tdd:fix` transcript: the RootIssue + SubIssue refs, the
   Root's `question` and `recommendation`, your single recommendation, and "confirm or
   correct" (O2).

---

## 6. Final integration (per repo, per base — never auto)

A spawned Root, at its §8, opens its integration→base PR and writes
`awaiting-merge-confirm` with `pr_url`/`base`/`head`, then **stops** (it does not
merge — the irreversible step is yours, behind a human gate; this also avoids leaving
a fragile idle Root blocked for hours).

When the cohort converges (`EVENT=cohort-ready`, or all members settled):

1. Gather the merge-pending members (state `awaiting-merge-confirm`) with their
   `pr_url` + `base`.
2. Surface **one consolidated notification** but request a **distinct confirmation per
   (repo, base)**: *"RootIssue #207 done. 3 Roots ready to merge: #142 → main, #143 →
   main, #145 → develop. Confirm each."* The human cannot meaningfully rubber-stamp
   three different repos' merges on one keystroke — keep the decision per-merge (O5 /
   invariant 6).
3. For each approved merge, **you** run it (the Root is gone):
   ```bash
   gh pr merge <pr_url> --squash   # under the run's single gh account
   ```
4. After a merge lands, finalize that Root: read its `meta.json` (glob
   `<repo_path>/.atdd/*/meta.json` for the one whose `sub_ref`/`notes_id` match)
   to get its `root_id` + `task`, then:
   ```bash
   ( cd <repo_path> && bash ${CLAUDE_SKILL_DIR}/../atdd/recipes/terminate-root.sh <root_id> <task> )
   bash ${CLAUDE_SKILL_DIR}/../atdd-plan/recipes/issue-close.sh <sub_ref>   # SubIssue: done (invariant 5)
   ```
5. When **all** SubIssues of the RootIssue are closed:

   **Before closing — Touch-2 (verify the prediction held):** run the Stack zoom-in on the boxes you
   declared in CORE §5 step 7.5; promote `proposed`→`verified`, fix anchors, or record honest drift.
   ```bash
   bash ${CLAUDE_SKILL_DIR}/../atdd/recipes/stack-zoom.sh --project <slug> \
     --marker <notebook-dir>/<root-ref>.stack-zoom-notes-verified
   ```
   A non-zero exit is signal, not a blocker here (the human is in this review) — surface the drift in
   the close.

   Then close the **RootIssue** with
   the human in a short review (CORE.md §9), run `notebook-index-update.sh`, clear
   `current_rootissue`, and loop (§3.2) to the next available RootIssue.

---

## 7. Compaction defense (re-derive from disk + store)

Your session may be auto-compacted mid-orchestration. The disk + the local atdd store are
durable; the conversation is not. If you have lost track (you cannot write the §1.10 preamble):

1. Re-read this file (`ORCHESTRATE.md`) and `CORE.md`.
2. Re-read `.atdd/<notes-id>/meta.json` → `current_rootissue`, `base_by_repo`,
   tmux ids, cap.
3. Re-read `cohort-<current-RI#>/cohort.json`; for each member, re-read its
   `signal_path` and check tmux liveness.
4. **Reconcile against ground truth** (the registry alone is not trusted —
   invariant 4):
   - `topology-available.sh` + `atdd issue view <sub_ref>` (read `.state`) — which
     SubIssues are still open vs already closed (= done).
   - For each open SubIssue of `current_rootissue`, glob each member repo's
     `<repo_path>/.atdd/*/meta.json` for `orchestrated==true && notes_id==<mine>
     && sub_ref==<that>` — this **rediscovers a Root the registry lost** (e.g. a crash
     mid-spawn) so it is never invisible.
   - SubIssues marked `running` in the registry but already closed in the store → mark
     finalized. Ready SubIssues of `current_rootissue` not yet spawned (cap
     permitting) → spawn.
5. Re-issue `roots-watcher.sh` if any member is non-terminal (the prior background
   watcher died with the compacted-out session — same reasoning as the Root's Resume
   bootstrap step 7).

`orch.log` is the append-only breadcrumb — every spawn, auto-answer, escalation, and
advance gets a line; tailing it reconstructs intent not otherwise on disk. Also append
to it at each of those points yourself.

---

## 8. Termination

Orchestration ends when `topology-available.sh` is empty, no RootIssue is open, and no
cohort member is non-terminal. Then:

1. Confirm with the human that the whole graph is done.
2. Self-clean: there is nothing to delete that the per-Root `terminate-root.sh` runs
   (§6) didn't already remove; optionally `tmux kill-window` the leftover Root
   dashboard windows in your session after the human has reviewed them.
3. `notify-human.sh "Orchestration complete — all RootIssues closed"`.
4. Return to plain Notes-Agent standby (the human may start a new head with
   `/agent-tdd:fix`).

Early termination (escalate, do not loop):
- **Cohort-wide failure** (no merge, ≥1 failed/crashed) → ask whether to continue.
- **Max graph depth / cohort wall-clock** ceilings hit → checkpoint with the human.

---

## 9. Quick phase checklist (re-read every boundary)

**Go-gate:** Step-0 tmux check → base table (per repo, human-confirmed) → present +
ask once → `orch-init.sh` on "go" (else plan-only fallback).

**Per RootIssue:** re-read this file → pick `current_rootissue` (one at a time) →
ready SubIssues → for each up to cap: host-gate, resolve clone, pre-spawn validate,
`spawn-root.sh` → issue `roots-watcher.sh` (background) → idle.

**On `root-event`:** dispatch on STATE → answer-from-artifacts or escalate
(paused), hold (awaiting-merge), escalate (rebase-blocked/stuck/failed/crashed) →
record `last_consumed_seq` → mirror Q/A to SubIssue comment → re-issue watcher.

**On `root-dead`:** escalate with a recommendation.

**On `cohort-ready`:** §6 per-(repo,base) human approval → `gh pr merge` each →
`terminate-root.sh` + `issue-close.sh` each → close RootIssue (CORE §9) →
`notebook-index-update.sh` → next RootIssue.

**On `timeout`:** §4.2 health check → self-extend once (live+progressing) or escalate;
enforce the cohort wall-clock ceiling.

**Always:** phase preamble; externalize before you rely on it; re-derive from disk +
the store after any drift.

---

End of ORCHESTRATE.md.
