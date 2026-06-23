# Roadmap

Project status, known risks, and future work for agent-tdd. The design is in [WHITEPAPER.md](WHITEPAPER.md) (v2 design rationale; edited only at major-version bumps — last at v1.0.0, which added §10.7 for orchestration). The operational protocols are in [skills/atdd/PROTOCOL.md](skills/atdd/PROTOCOL.md) (Root) and [skills/atdd-plan/ORCHESTRATE.md](skills/atdd-plan/ORCHESTRATE.md) (Notes Agent orchestration). This file tracks what's built, what's broken, and what's next.

---

## Status

**v1 — built, pending end-to-end smoke test.**

What's in place:

- ✅ Plugin scaffold (`.claude-plugin/plugin.json`)
- ✅ User-facing skills: `/agent-tdd:atdd` (real workflow) and `/agent-tdd:atdd-compact` (session-handoff utility for compacted Roots — added v0.8.0). The earlier `/agent-tdd:atdd-demo` wrapper (v0.5.0) was removed in v0.10.0 along with `init-root.sh`'s `[demo]` 4th-arg flag.
- ✅ `SKILL.md` (Root bootstrap + invariants)
- ✅ `PROTOCOL.md` (full operational spec, re-read at every phase boundary)
- ✅ Role markdowns for all three spawned-agent kinds (test, impl, rebase)
- ✅ Seven recipe scripts (init, spawn-test, spawn-impl, wave-watcher, wave-end-cleanup, terminate-root, notify)
- ✅ Issue template (§5.2 schema)
- ✅ Atomic status-write protocol
- ✅ Background-Bash event-watcher with 30-min hard ceiling per invocation. Three exits: `EVENT=terminal` (Gate 1), `EVENT=paused` (any `.paused`), `EVENT=timeout` (no event for 30 min). On timeout, Root escalates to the human per §1.5 P6 instead of waiting forever — the safety net for silently dead child agents (impl/test agent crashes without writing a status file). The ceiling is per-invocation, not cumulative; re-issuing after a pause grants a fresh budget. (v0.6.0 — replaces the original "no timeout" design which led to indefinite hangs in smoke runs.)
- ✅ Auto-merge + rebase ladder up to rung 4
- ✅ Root runs in its own worktree (`.atdd/<root-id>/root/`) — multiple concurrent Roots in one repo no longer share the main worktree's HEAD/index. Root ID is claimed atomically via `mkdir`. (v0.2.0)
- ✅ Dashboard tmux session name is observed, not prescribed. The plugin previously assumed the human launched Claude Code from a session literally named `roots`; PROTOCOL.md and several recipes hardcoded `-t roots:root-<id>` for window renames. The workflow itself worked from any session (workspace `ws-root-<id>` is created on demand), but title updates silently failed when the session was named anything else. `init-root.sh` now captures the caller's session via `tmux display-message -p '#S'` and persists it as `meta.json:root_tmux_session`; PROTOCOL.md, SKILL.md, and `notify-human.sh` read it from there. WHITEPAPER.md is unchanged (immutable v1 spec). (v0.4.0)
- ✅ Compact handoff: `/agent-tdd:atdd-compact` is a one-shot utility the human types in the current Root window when its conversation has bloated mid-workflow. It externalizes a gap-free handoff brief (template at `skills/atdd-compact/templates/checkpoint-comment.md`) to `wave-<N>/handoff.md`, comments it on the wave's active issues + open impl PRs, then `tmux new-window`s a fresh `claude` in the same dashboard session and `tmux send-keys`-fires `/agent-tdd:atdd resume <root-id>` into it. The new claude session is auto-loaded with the globally-installed plugin and re-enters `atdd`'s "Resume bootstrap" branch (added in this version's `skills/atdd/SKILL.md` edit), which skips Wave 0 and rehydrates from `meta.json` + `manifest.json` + `handoff.md`. The prior Root waits 60s, capture-panes the new window, judges visually whether the resume worked, and only then renames its own window to `[ARCHIVED] <prior-name>` (it leaves both windows alive on a failed verify). Children in `ws-root-<id>` keep running through the handoff — status files are atomic, agnostic to which Root reads them; the new Root re-issues `wave-watcher.sh` on resume. Not an orchestrator: it re-enters `/atdd`, does not duplicate wave state. (v0.8.0)
- ✅ **Interactive impl agents (v0.13.0).** Impl agents no longer run headless (`claude -p` / `opencode run` / `codex exec`); they run an interactive CLI session in their `issue-<N>-PR` tmux window, exactly like test agents — `spawn-impl-agent.sh` pipe-panes the window to `logs/issue-<N>/tmux.pane`, launches the CLI via `launch-impl-agent.sh` (now a session supervisor: EXIT/HUP trap, timing, orphan-`.tmp` promotion, hardened kill-window), waits for the prompt, and pastes the role + task block via tmux buffer. `.crashed` is now triggered by **status absence at session end** (an interactive exit returns 0 regardless), and the supervisor removes any stale `.paused` before writing it (crash wins over pause — a dead session must not loop the watcher on `EVENT=paused`). Pausing is now **enabled for impl agents** (bounded to 2 per issue; Root answers via `tmux send-keys` to `issue-<N>-PR`). `wave-end-cleanup.sh` also kills leftover `issue-<N>` / `issue-<N>-PR` windows for terminal issues (previously nothing reaped them until root termination). Only the rebase agent remains headless. See Smoke-Test Risk #7.
- ✅ **Multi-host packaging (v0.12.0).** One `skills/` source, three host manifests, no build step (pattern from obra/superpowers):
  - **Claude Code** — `.claude-plugin/plugin.json` (unchanged behavior).
  - **OpenCode** — `package.json` `main` → `index.js`; on load it copies `skills/` into `.opencode/skills/`, generates one `/atdd*` command per `user-invocable` entry skill into `.opencode/commands/` (discovered from SKILL.md frontmatter — the old hard-coded `atdd`/`atdd-demo`/`atdd-compact` list is gone, so `atdd-fix`/`atdd-from-issue`/`atdd-feature` now register too), and sets `CLAUDE_SKILL_DIR` + `AGENT_TDD_CLI=opencode` via `shell.env`.
  - **Codex** — `.codex-plugin/plugin.json` (`"skills": "./skills/"` + `interface`) and `.codex-plugin/marketplace.json`. Each entry skill ships `agents/openai.yaml` with `allow_implicit_invocation: false` so these heavy orchestrators never auto-inject. The spawn recipes gained a `codex exec --dangerously-bypass-approvals-and-sandbox` branch; `atdd/SKILL.md` gained a **Step 0** that resolves `CLAUDE_SKILL_DIR`/`AGENT_TDD_CLI` (Codex has no session env hook). Tool-name map at `skills/atdd/references/codex-tools.md`.

- ✅ **Notes Agent orchestration mode (v1.0.0).** After a single human "go", the planning session drives execution instead of handing off manually: it spawns one Root per ready SubIssue via `/agent-tdd:atdd-from-issue` (a bare `claude` launched with orchestration env + a short paste-bootstrap pointing at the wrapper markdown — no `--plugin-dir` bet), one RootIssue at a time per `topology-available.sh`, up to a concurrent-Root cap (default 3). It is each Root's human-proxy: supplies Wave-0 answers via env, absorbs escalations via per-Root `root-signal.json` polled by the idle-cheap `roots-watcher.sh` (mirrors `wave-watcher.sh`; zero `gh` calls), and surfaces to the real human only on exceptions. Every merge-to-base is human-confirmed per (repo, base) and performed by the orchestrator (`gh pr merge`); the Root opens the PR and stops. A `launch-root.sh` supervisor writes a `crashed` signal on silent Root death. New recipes: `orch-init.sh`, `spawn-root.sh`, `launch-root.sh`, `roots-watcher.sh`, `write-signal.sh`; `manifest-ensure.sh` gained `--resolve-member`/`--register-member`; `init-root.sh`/`notify-human.sh`/`PROTOCOL.md` gained additive env-gated hooks (no behavior change when unset — the manual handoff is fully preserved). Contract: `skills/atdd-plan/ORCHESTRATE.md`. Major bump because it reverses two Notes-Agent invariants ("never run /atdd", "no child agents") and scopes the WHITEPAPER "only via GitHub" axiom (see §10.7).

- ✅ **Multi-project store + project-aware planning (v1.1.1).** The atdd CLI is now multi-project: one isolated SQLite DB per project (`~/.atdd/projects/<slug>/atdd.db`) plus a global `~/.atdd/master.db` (project registry + repo registry with stable UUIDs + project↔repo membership). A repo can belong to many projects; issues never cross a project boundary. The plugin resolves an active project at planning bootstrap from the master registry (`atdd repo where <home_repo>`: first run → `default`, home repo in exactly one project → auto, **asks the human only when it is in >1 project**), pins it in `manifest.json:project_slug` (the NotebookIssue is now per-project), and propagates it to every spawned Root + its test/impl agents via `$ATDD_PROJECT` (`orch-init.sh` → `meta.json`, `spawn-root.sh` → launch env). Agents never pass `--project`. New recipes: `project-resolve.sh`, `project-set.sh`; new CLI: `atdd project create|list`, `atdd repo where`, global `--project`. Contracts: `CORE.md §2` + `ORCHESTRATE.md §2.3`.

- ✅ **Phase C piece 1 — bootstrap LSP surfacing (v2 `Stack` work; branch `v2`).** A new top-level shared recipe `skills/lsp-surface.sh` (sibling of `ensure-atdd.sh`) runs at bootstrap in both layers: it detects the repo's symbol-precise languages (by file pattern), cross-checks `atdd lsp list` (`status` = ok/missing/not_executable), and emits a gap JSON `{repo, repo_registered, detected, covered, missing}`. The repo slug is **never null** (resolves `--repo` → git origin → manifest `home_repo` → atdd registry by path → `local/<folder>`). Wired into the Root (`skills/atdd/SKILL.md` bootstrap step 0) and the Notes Agent (`skills/atdd-plan/CORE.md` §2 + `skills/atdd-fix/SKILL.md`) — **hybrid**: the recipe is the deterministic floor, the agent refines and provisions (install → `atdd repo register` if `repo_registered` is false → `atdd lsp register`). **Advisory — never blocks.** Covered by a hermetic no-LLM gate in `skills/atdd-plan/recipes/tests/run.sh` (`== lsp-surface ==` + a `== bootstrap wiring ==` grep gate). Needs an `atdd-cli` build ≥ commit `377a013` (the `lsp list` `status` field; the `oracle`→`lsp` rename + the D6 reversal). Spec: `../atdd-cli/PHASE_2.md` §8; plan: `docs/superpowers/plans/2026-06-18-lsp-surfacing.md`. **Phase C pieces 2–3 (`stack init` skeleton, end-of-task zoom-in) not yet started — see `PHASE_C_KICKOFF.md` (the living Phase C work doc: state, open design questions, where-to-build).**

Not yet validated end-to-end. See **Smoke-Test Risks** below for the specific things to watch when running the first real workflow.

---

## Smoke-Test Risks (v1)

Several implementation choices that look correct on paper but haven't been exercised in a real session. Verify these first when running the first end-to-end test, and document the resolution here.

### 1. Multi-line prompt delivery via tmux

**Where:** `recipes/spawn-test-agent.sh`, `recipes/spawn-impl-agent.sh`.

**What we did:** Use `tmux load-buffer` + `tmux paste-buffer -p` (bracketed paste) to deliver the multi-line spawn prompt (role markdown + per-issue task block, ~250 lines) into the agent's tmux pane, then `tmux send-keys Enter` to submit. As of v0.13.0 this path carries **both** agent kinds — impl prompts are pasted too (the old `claude -p "$(cat …)"` argv delivery is gone), so a paste failure now blocks the whole pair, not just the test half.

**Risk:** Claude Code's interactive UI may not honor bracketed paste consistently. Possible failure modes:

- Each `\n` in the buffer interpreted as a separate Enter → the prompt gets submitted line-by-line instead of as one message.
- Bracketed-paste delimiters (`\e[200~`, `\e[201~`) leak into the visible input as garbage characters.
- Large pastes get truncated by terminal buffering.

**If broken, try:**

- Replace `tmux paste-buffer -p -t TARGET -b BUF` with `tmux send-keys -t TARGET -l "$(cat PROMPT_FILE)"`. The `-l` flag treats input as literal text; embedded newlines arrive as `\n` characters rather than Enter keypresses.
- If that also fails, fall back to `cat PROMPT_FILE | claude` — but this makes the session non-interactive, which breaks the test agent's ability to receive `tmux send-keys` answers when paused. Would require redesigning the pause protocol.

### 2. CI status detection on repos with no CI

**Where:** `roles/IMPL_AGENT_ROLE.md` Step 6 (and the rebase agent's Step 5).

**What we did:** Run `gh pr checks --watch <pr#>` after opening a PR. Map result to `ci_status: "passing" | "failing" | "no-checks"`.

**Risk:** `gh pr checks --watch` behavior on a repo with **no CI configured** is unclear. It may:

- Hang forever waiting for checks that will never appear.
- Return immediately with exit code 0 (which the agent might mistake for "passing").
- Return immediately with exit code 1 (which the agent might mistake for "failing").

**If broken:** Add a pre-flight `gh pr checks <pr#>` (no `--watch`) immediately after PR creation. If the output reports "no checks", set `ci_status: "no-checks"` and skip the watch entirely. Then call `--watch` only when checks exist.

### 3. `claude -p` argument-length limits — RESOLVED for impl agents (v0.13.0)

**Where (historical):** `recipes/spawn-impl-agent.sh` (the launch line used `claude -p "$(cat PROMPT_FILE)" ...`).

**Resolution (v0.13.0):** impl agents no longer receive their prompt via argv — the prompt is pasted into the interactive session via tmux buffer (same as test agents), so `ARG_MAX`, quote-escaping, and argv-truncation concerns no longer apply to the test/impl path. (The paste path has its own risk — see #1.)

**Still applies to:** the **rebase agent**, which Root spawns headless with the prompt as a `claude -p` / `opencode run` / `codex exec` argument (PROTOCOL §3.7 rung 2). Its prompt is shorter (REBASE_AGENT_ROLE.md + a small task block), so the original mitigations stand if it ever breaks: `--prompt-file` if supported, else pipe via stdin.

---

### 4. Notes Agent CRUD recipes — live GitHub API unverified (v0.10.0+)

**Where:** `skills/atdd-plan/recipes/{sub-adopt,issue-edit,issue-close,sub-unlink,root-undepend,ready-unmark}.sh`.

**What we did:** Added full CRUD over RootIssues/SubIssues. `tests/run.sh` covers arg-validation, which endpoint each recipe fires, and idempotency skips — all against a **mock `gh`**. The mock proves the recipes' *logic*, not GitHub's *behaviour*.

**Risk — three live-API assumptions the mock cannot check:**

- **Sub-issue remove endpoint.** `sub-unlink.sh` calls `DELETE /repos/<o>/<r>/issues/<N>/sub_issue` (singular path) with `-F sub_issue_id=<db-id>`. Path/verb taken from GitHub docs; the *add* side (`sub_issues`, plural) is verified working (CORE §7, 2026-05-28) but the *remove* side has not been run against a real repo.
- **Dependency remove endpoint.** `root-undepend.sh` calls `DELETE /repos/<o>/<r>/issues/<N>/dependencies/blocked_by/<issue_id>` (blocker db-id in the path, no body) and lists `GET .../dependencies/blocked_by` for its idempotency check. Both unverified live; if the GET list endpoint differs, the idempotency guard silently degrades (it would attempt the DELETE regardless — still correct, just not a clean no-op).
- **`gh project item-add` idempotency.** `sub-adopt.sh` assumes re-adding an already-present item exits 0 (server-side dedup). If gh instead errors on duplicate, a re-run of `sub-adopt.sh` after a partial success will `die` at the project step. If smoke testing shows this, guard it with a membership pre-check or tolerate the duplicate-error path.

**How to test (low cost, reversible):** in a throwaway repo with a real manifest — adopt a loose issue, unlink it, re-adopt (idempotency), add+remove a root dependency, mark+unmark ready, close+reopen. All operations are reversible.

**If broken:** correct the endpoint path/verb in the one affected recipe; the mock tests pin the *call shape*, so update the matching fixture/assertion in `tests/run.sh` alongside.

**Resolved (v0.12.1) — user-owned GitHubProjects.** First live-API bug confirmed in the field: `manifest-ensure.sh` and `_graph.sh` resolved the project via org-only GraphQL (`organization(login:)`), which returns null for a user login — so bootstrap died on `https://github.com/users/<user>/projects/<n>` URLs (which the URL parser *already accepted*) and every `_graph.sh` consumer (`topology-*.sh`, `notebook-index-update.sh`, `root-depend.sh`'s same-graph/cycle guards) saw an empty graph. Fixed owner-agnostically: `manifest-ensure.sh` resolves id+title via `gh project view --owner`, `_graph.sh` queries the project by its global node id (`node(id: <manifest .project.id>)`). Reporter verified the fix live against a user-owned project (`hn12404988/cooksy-hil` ↔ user project #2). `tests/run.sh` gained the first behavioral coverage for both recipes (user-owned + org-owned bootstrap, lookup-failure, node-id query shape); the mock `gh` learned canned stdout for non-`api` subcommands (`CMD__*` fixtures, e.g. `gh project view`).

### 5. OpenCode end-to-end (v0.12.0)

**Where:** `index.js`, the `opencode` branches in `launch-impl-agent.sh` / `spawn-test-agent.sh` / `spawn-resume-window.sh`.

**What we did:** The plugin self-installs on load (skills + one command per entry skill). Test/impl agents launch the bare `opencode` TUI interactively (since v0.13.0; the rebase agent still uses `opencode run … --dangerously-skip-permissions`). Command generation and `shell.env` were unit-checked (a temp-dir run produces all five `/atdd*` commands and sets the two env vars), but a full wave has not run under OpenCode.

**Risk / verify:** plugin loads in a real project → `/atdd` starts Root → an interactive `opencode` child agent writes a `.done`/`.failed` status file the watcher sees → tmux paste + prompt-ready detection (`grep -qE '^[> ]'`) match OpenCode's TUI → `/atdd resume` re-enters cleanly. (See also Smoke-Test Risk #7b/#7c for the interactive permission posture and the `/exit` self-close token.)

### 6. Codex orchestration — experimental (v0.12.0)

**Where:** `.codex-plugin/`, the `codex` branches in the spawn recipes, and `atdd/SKILL.md` Step 0.

**What we did:** Packaging only is well-trodden (manifest + marketplace + `agents/openai.yaml`). The *runtime* is the unproven part: nested `codex exec` under a Codex Root, tmux window driving, worktree isolation, and the `$atdd` invoke form are all unverified against a live Codex session.

**Risks / verify (in order):**

- **Skills do not auto-inject.** With `allow_implicit_invocation: false` on every entry skill, confirm none of them load into an unrelated Codex session. If Codex still injects, the extra SKILL.md frontmatter keys may be the trigger — fall back to minimal `name`+`description` frontmatter on the Codex copy.
- **Step 0 resolves the skill dir.** The probe `find "$HOME/.codex" … -path '*/atdd/SKILL.md' | grep -m1 agent-tdd` depends on where Codex's marketplace install lands skills. If it prints empty, Step 0 falls back to asking the human — confirm that path, then consider hard-coding the real install location or writing the two vars into `~/.codex/config.toml [shell_environment_policy].set`.
- **Interactive child shape (test/impl).** Since v0.13.0 test and impl agents launch the bare `codex` TUI in a tmux window with the prompt pasted via buffer. Confirm Codex's TUI accepts the paste as one message, matches the prompt-ready regex, and that the agent can self-close (see Smoke-Test Risk #7b/#7c). The headless `codex exec "<prompt>" --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check` form now applies only to the **rebase agent** — confirm it runs to completion in a worktree and writes its terminal status (prompt-length limits per risk #3 still apply there).
- **`$atdd resume <id>` form.** The resume recipe types `$atdd resume <id>`; confirm that is how Codex re-invokes a named skill interactively, and adjust `spawn-resume-window.sh` if the live form differs.

**If broken:** Codex is marked experimental in README — degrade gracefully to documenting Codex as "packaging present, orchestration pending" until a wave passes.

### 7. Interactive impl agent (v0.13.0)

**Where:** `recipes/spawn-impl-agent.sh`, `recipes/launch-impl-agent.sh`, `roles/IMPL_AGENT_ROLE.md` §2/Step 8, `recipes/wave-end-cleanup.sh`.

**What we did:** Moved the impl agent from headless `claude -p` to an interactive CLI session (see Status). Verify, in order:

- **(a) Push permissions under interactive mode.** Does interactive `claude --permission-mode bypassPermissions` actually let `git push` through? This is a *re-test of the open hit/miss bug* (see Known Risks / Future Work below): under the old headless launch, 2/3 impl agents were intermittently blocked despite bypass flags. Interactive mode is a new variable — project-level `.claude/settings.json` `permissions.ask` rules and `PreToolUse` hooks may behave differently against an interactive session.
- **(b) OpenCode/Codex bare interactive sessions.** Impl agents on those hosts now launch the bare TUI (no permission flags — interactive flag support is unverified). Confirm the prompt-ready regex (`^[> ]`) matches their TUIs, the paste lands as one message, and an impl wave completes. (Extends risks #5 and #6.)
- **(c) Self-close token per host.** The role tells the agent to `/exit` after writing status. Confirm `/exit` (or turn-end) actually terminates the session for opencode and codex; if not, the window lingers until wave-end cleanup kills it — the wave itself still advances (status file exists), but confirm the supervisor's kill-window then settles cleanly.
- **(d) No false `.crashed` on clean exit.** A clean `/exit` after `.done` must NOT produce `.crashed` (the supervisor checks status presence, not exit code). Conversely:
- **(e) Crash path.** Killing the impl window mid-task (no status written) must produce `.crashed` via the supervisor's HUP trap, and must remove any pre-existing `.paused` for that issue (crash wins over pause — otherwise the watcher loops on `EVENT=paused` for a dead session).

**If broken:** (a) → revisit `--permission-mode auto` or a `--settings`-level override, and document the working posture here; (b)/(c) → per-host branches in the supervisor (flags / exit token), or mark the host's impl path experimental; (d)/(e) → fix the supervisor's trap logic before any real wave (these two are the load-bearing safety nets).

These were considered during design and deliberately deferred. Source: WHITEPAPER §10.

- **Recursive spawning within a wave.** Test agents spawning test agents was explored and rejected: red tests cascading down child branches break the "narrow scope per impl agent" principle, and stacked PR fragility makes one-shot impl unreliable. The only sanctioned re-spawn is Root re-spawning aborted agents (bounded to 1 retry).
- **Stacked PRs across pairs.** Sibling test/impl pairs are flat off the Root branch; no PR depends on another sibling's PR.
- **Cross-wave dependency tracking beyond GitHub issue links.** No machine-enforced graph of "Wave 2 issue X depends on Wave 1 issue Y" — provenance lives in issue bodies only.
- **Auto-merge of Root branch to `main`.** Final integration is human-confirmed.
- **Crash recovery / Root resume protocol.** If Root or the host machine dies mid-wave, status files persist on disk but Root's conversation context is lost. v1 has no automatic resume; human re-launches Root and manually consults disk state. Future: a `/agent-tdd:resume <root-id>` slash command that re-derives state from `.atdd/<root-id>/` + GitHub labels.

### 8. Notes Agent orchestration mode — unproven end-to-end (v1.0.0)

The orchestration layer (built per the "build the full protocol now, smoke-test at the end" decision) sits on top of a Root layer that is **itself still pending end-to-end smoke test** (above), and leans on several mechanisms not yet exercised. Verify in a throwaway multi-repo project (plan two RootIssues with a dependency, say `go`, watch the first head's Roots run + merge with per-(repo,base) human confirms, watch the second head become available and run, confirm the graph drains and RootIssues close — on the claude host):

- **(a) Paste-bootstrap launch.** A bare `claude --permission-mode bypassPermissions` started by `spawn-root.sh`, handed a short pasted bootstrap that points it at `atdd-from-issue/SKILL.md` (read from disk via `CLAUDE_SKILL_DIR`), actually boots into orchestrated mode and runs autonomously. (We deliberately did **not** bet on `claude --plugin-dir` registering the slash command — no existing code proves that works.) Cross-ref Risk #1 (tmux paste).
- **(b) `git push` under unattended `bypassPermissions`.** The orchestrated Root and its grandchildren push/PR without a human watching — the same intermittent `permissions.ask` block logged in Known Risks / Future Work bites harder here (no human at the Root's window). The orchestrator's `roots-watcher` must surface a Root wedged on an in-pane permission prompt (currently it would show as a `timeout` health-check escalation). Cross-ref Risk #7a.
- **(c) Single gh account per run.** v1 uses one gh account for the whole orchestration; the global `gh auth switch` race is benign only because all Roots switch to the *same* account. A cohort whose repos need *different* accounts is unsupported (escalate + run manually) — per-repo accounts would need `GH_CONFIG_DIR` isolation propagated to every grandchild gh process. Verify no member repo silently needs a different account.
- **(d) Final-merge indirection.** The Root opens the integration→base PR and stops; the orchestrator confirms with the human per (repo, base) and runs `gh pr merge` itself, then `terminate-root.sh` + `issue-close.sh`. Verify the orchestrator correctly finds the Root's `root_id`/`task` (glob `<clone>/.atdd/*/meta.json`) for cleanup.
- **(e) Watcher cross-repo + liveness.** `roots-watcher.sh` reads each Root's `root-signal.json` by the absolute path recorded in `cohort.json` (repos may live on different paths) and detects a dead Root via `tmux list-windows -a` membership (not `display-message -t`, which falls back to the current window). Confirm both across real repos.
- **(f) opencode/codex orchestrated launch deferred.** The host-capability gate refuses any SubIssue whose `AGENT_TDD_CLI` ≠ `claude` (escalate → human runs it manually). opencode has no `--plugin-dir`/paste-bootstrap equivalence verified; codex approval posture is unverified. claude is the v1 orchestration target.

### 9. Phase C LSP surfacing — hermetically tested, unproven in a real bootstrap (v2)

**Where:** `skills/lsp-surface.sh`, the bootstrap step in `skills/atdd/SKILL.md` + `skills/atdd-plan/CORE.md`, and the `== lsp-surface ==` + `== bootstrap wiring ==` gates in `skills/atdd-plan/recipes/tests/run.sh`.

**What we did:** A deterministic, advisory recipe that surfaces languages lacking a working LSP, plus the agent-side provisioning instruction. The recipe is covered by a hermetic no-LLM gate (real `atdd`, temp `ATDD_HOME`, no language server). The **agent half** — deciding which server, installing it, and running `atdd repo register`/`atdd lsp register` — is LLM/human and is not exercised by any test.

**Verify in a real bootstrap:**

- **(a) Provisioning flow.** On a repo with a missing LSP, the agent surfaces it, the human picks a server, it installs, and `atdd lsp register` lands under the right repo slug (with `atdd repo register` first when `repo_registered` is false). Confirm the LSP is then visible to `atdd stack verify`.
- **(b) Local-only repo slug.** The Root's normal case (no GitHub origin, no manifest) must fall back to `local/<folder>` and stay advisory — never `register --repo null`.
- **(c) Registry path-match.** The `(g)` test assumes `git rev-parse --show-toplevel` and `atdd repo list`'s stored `localPath` agree as strings; where the repo path (or `/tmp`) is a symlink, only the recipe's `pwd -P` match-arm saves it. Confirm on the real host.
- **(d) Over-detection noise.** `_has_ext` prunes only a top-level `.git` and does **not** skip `node_modules`/`vendor`/`target` — a repo with vendored sources in another language over-surfaces (advisory, but noisy). Tighten the prune set if it bites.

**If broken:** the recipe is advisory and exits 0, so a bug degrades to noise, not a block — fix the affected resolution rung or detection signal and update the matching `run.sh` assertion.

---

## Known Risks

Open risks to monitor through v1 use. Source: WHITEPAPER §11 + smoke-test learnings.

- **Dedup quality.** Structured templates make dedup tractable but not perfect. Some semantic dupes will slip through. Acceptable for v1.
- **Paused agents AFK for days.** The workflow blocks indefinitely on a paused agent. By design — fire-and-forget allows human gates. Add a "stale paused agent" warning if it becomes a UX problem.
- **Root branch lifetime.** Long-running Root branches drift from `main`. Recommend periodic `git merge main` into the Root branch between waves; automate later.
- **Crash recovery.** No automatic resume in v1. Human can re-launch Root and inspect `.atdd/<root-id>/` to reconstruct state.
- **GitHub API rate limits.** With multiple Roots and large waves, the 5000/hr authenticated limit can bite. Issue creation, label updates, and `gh pr checks --watch` polling all count. Monitor and back off as needed.
- **Anthropic API rate limits.** Each child agent is a separate Claude session. Highly parallel waves on small accounts may rate-limit.
- **Test isolation.** Multiple parallel test runs (during impl agent CI) may interfere if the project uses shared resources (databases, fixed ports, shared on-disk state). Project-specific concern; document in your project README if relevant.
- **Worktree disk usage.** Each worktree is a full working tree. For large repos, N parallel worktrees = N× disk. Prune aggressively on terminal status.
- **Permission bypass for impl agents.** Impl agents launch as interactive `claude --permission-mode bypassPermissions` sessions (v0.13.0; opencode/codex launch bare — see Smoke-Test Risk #7b). Required for unattended autonomy. Intended for trusted local repos; do not run Agent TDD against repos whose build steps would expose secrets to an unaudited shell.
- **Mode discipline is soft.** Once Root enters autopilot, nothing in Claude Code prevents the human from typing freeform and Root engaging inline. v1 mitigations: strong invariants in `SKILL.md`, plus Root prefixing every response with a `[wave-N: phase]` preamble. Hardening (hooks, settings.json policy) is post-v1.
- **Compaction over long workflows.** SKILL.md and PROTOCOL.md content may be evicted from context after auto-compaction during multi-hour workflows. Mitigation in `SKILL.md`: Root re-reads `${CLAUDE_SKILL_DIR}/PROTOCOL.md` and `.atdd/<root-id>/` files at every phase transition. Verify this discipline holds in long sessions.
- **WHITEPAPER describes the pre-v0.13.0 impl-agent launch.** WHITEPAPER.md (lines ~73, ~84, ~305, ~651) still describes impl agents as spawned via `claude -p` (non-interactive) and self-cleaning via shell chaining (`claude -p '...' ; gh pr checks --watch ... ; tmux kill-window`) — line ~651 is a copy-pasteable command example a reader might lift verbatim. As of v0.13.0 impl agents are interactive (see Status). Per repo rule the whitepaper is edited only at major-version bumps; PROTOCOL.md is authoritative where they disagree (PROTOCOL §1). Recorded here for the next major-bump editor.
- **WHITEPAPER.md + `../atdd-cli/STACK.md` still use the old "oracle" term.** The v2 `Stack` work renamed the verb `oracle`→`lsp` and reversed decision D6 ("registered == active"; `lsp require/unrequire/check/unregister` dropped — only `lsp register`/`lsp list` remain, and surfacing is **advisory**, not project-blocking). Both design docs still say "oracle" (e.g. WHITEPAPER §7 Bedrock; STACK.md Bedrock). Per the repo rule the whitepaper is edited only at major-version bumps; recorded here so the next major-bump editor aligns the terminology + the D6 reversal in one pass (together with the pre-v0.13.0 impl-agent note above).
- **~~One NotebookIssue per home repo~~ — RESOLVED (v1.1.1).** *(was: `manifest.json` stored exactly one `notebook_issue`, so two independent planning streams in the same home repo — parallel engagements, separate product lines — couldn't keep separate NotebookIssues.)* v1.1.1's multi-project store solves this: the home repo can belong to many **projects**, each its own isolated DB with its own per-project NotebookIssue. Two independent streams in one home repo are now simply two projects (`manifest.json:project_slug` pins the active one; `atdd project create <slug>` adds another). The predicted "stream slug" fix shipped as the project concept.

---

## Future Work

In rough priority order. Each item is a candidate for a v2 issue once v1 is validated.

### Near-term (after v1 smoke test passes)

- **Crash recovery skill.** `/agent-tdd:resume <root-id>` that re-derives Root state from disk + GitHub labels and resumes autopilot.
- **Stale-pause warning.** If a `.paused` file is older than 1 hour, surface to the dashboard window title automatically.
- **Intermittent `git push` blocked despite permission flag — re-test under interactive mode (v0.13.0).** During the second smoke test, 2/3 impl agents (#11, #13) reported `git push` blocked despite the launch wrapper passing `--dangerously-skip-permissions`; #12 in the same wave pushed successfully. Same hit/miss pattern as smoke run #1 (#7 blocked, #8 succeeded, #9 died before push). Hypothesis: project-level `.claude/settings.json` `permissions.ask` (`Bash(git push:*)`) and/or its `PreToolUse` Bash hook intercepts before the bypass flag takes effect. The wrapper briefly used `--permission-mode auto`, then settled on `--permission-mode bypassPermissions` (which replaced both the deprecated `--dangerously-skip-permissions` and the `auto` interim). As of v0.13.0 the launch is **interactive** `claude --permission-mode bypassPermissions` — a new variable for this bug; verify per Smoke-Test Risk #7a. If still blocked, investigate: project-scope settings overrides, `PreToolUse` hook timing, or `--permission-mode` semantics for blanket Bash-tool bypass.
- **Per-agent log bundle (impl + test) — SHIPPED; shape changed in v0.13.0.** Originally: wrap headless `claude -p` with stdout/stderr capture + exit-code recording + `.crashed` on silent death + hardened `tmux kill-window` retry, and `tmux pipe-pane` for test agents. Since v0.13.0 impl agents are interactive too, so the bundle is now symmetric: `.atdd/<root-id>/wave-<N>/logs/issue-<X>/` contains `tmux.pane` for **both** agent kinds, plus `agent.exitcode` and `agent.timing.{start,end}` from the impl session supervisor (`agent.stdout`/`agent.stderr` are no longer produced — pane capture replaced them). The two original failure modes stay covered: silent death now writes `.crashed` on status absence at session end, and the hardened kill-window retry survives (friday's `SessionEnd` hook race).
- **`gh pr checks --watch` no-CI handling.** Pre-flight check (see Smoke-Test Risk #2) regardless of how risk #2 resolves.
- **End-to-end test harness.** A throwaway-repo script that automates the smoke-test playbook from the implementation plan, suitable for CI on this plugin itself.
- **Phase C piece 2 — `stack init` skeleton recipe.** A cheap top-down first pass (read manifests / top dirs / contracts → declare the coarse top Layers + the headline cross-repo Interface, all `--confidence proposed`). Spec: `../atdd-cli/PHASE_2.md` §8 (C2); open design questions + likely shape: `PHASE_C_KICKOFF.md`.
- **Phase C piece 3 — mandatory end-of-task zoom-in.** After `record-green` (Impl) and `integrate`/`issue-done` (Root), a required, un-skippable step that updates the Stack model for the touched boxes (`layer`/`interface`/`process` verbs + `layer link --issue`) and runs `stack verify`. Spec: `../atdd-cli/PHASE_2.md` §8 (C3); open design questions (where it hooks, how to make it un-skippable, what "thorough" means) + likely shape: `PHASE_C_KICKOFF.md`.

### Medium-term

- **Mode-enforcement hooks.** `PreToolUse` hook that rejects human-initiated tool calls during a wave (e.g. block direct `gh` calls when Root is in autopilot), reducing the chance of human-induced state drift.
- **Periodic `git merge main` into the Root branch** between waves, automated.
- **Backlog visualization.** A dashboard skill that renders the current `.atdd/<root-id>/` state + GitHub labels as a tree, for the human to skim.
- **Multi-root cross-dedup.** Concurrent Roots in one repo are now structurally safe at the git layer (each runs in its own worktree on its own integration branch — see Status). What's still missing: a shared dedup check so Root A doesn't open an `agent-tdd:pending` issue that Root B is already working on. Today each Root's dedup query filters by `agent-tdd:root-<id>`, so cross-Root overlap is invisible. Add a layer that ignores the root-id label when dedup'ing, OR have agents register a "claim" label early so other Roots can see in-flight scope.
- **Multi-user namespacing on a shared repo.** The plugin assumes one user per repo. Two users running concurrent waves on the same GitHub repo would collide on: (a) **`agent-tdd/<task>` integration branches** — the slug is human-supplied, both users picking `sync-fixes` collide on push; (b) **`agent-tdd:root-<id>` labels** — each user computes `root-1` independently from local `.atdd/`, so issues across users all get the same label and per-user filtering breaks; (c) **backlog activation race** — both users' Wave 2 could pick up the same `agent-tdd:pending` issue; (d) **layer-1 dedup scope** — agents filter `agent-tdd:pending --label agent-tdd:root-<id>`, so they only see their own user's backlog and won't dedup against the other user's in-flight issues. (Issue/PR numbers are GitHub-unique per repo so safe; `.atdd/<root-id>/` dirs are local-only and gitignored so safe.) Fix shape: namespace everything by `gh api user --jq .login` — Root ID becomes `<gh-user>-<n>`, integration branches `agent-tdd/<gh-user>/<task>`, labels `agent-tdd:root-<gh-user>-<n>`. Tradeoff: longer branch names; PROTOCOL.md examples and the SKILL.md root-id derivation step need updating; existing single-user state needs a migration shim or clean break. Add when the plugin gets a second user.

- **Orchestration: concurrency *across* RootIssues.** v1.0.0 runs one RootIssue at a time (its parallel-safe SubIssues together, up to the cap). Running independent unblocked RootIssues concurrently would need a cross-cohort scheduler and a watcher over multiple cohorts.
- **Orchestration: per-repo gh accounts.** v1.0.0 uses one gh account per orchestration run (makes the global `gh auth switch` race benign). Distinct accounts per repo in one cohort would need `GH_CONFIG_DIR` isolation propagated to every grandchild gh process (Root + test + impl + rebase), since tmux doesn't propagate env to new windows.
- **Orchestration: auto-clone of a missing member repo.** v1.0.0 asks the human for a local clone path and registers it (`manifest-ensure.sh --register-member`). A future version could `git clone` a missing member into a convention location after confirmation.
- **Orchestration: opencode/codex hosts.** v1.0.0 refuses to orchestrate a SubIssue whose `AGENT_TDD_CLI` ≠ `claude` (the host-capability gate; the human runs those manually). opencode has no `--plugin-dir`/paste-bootstrap equivalence verified, and codex's interactive approval posture under tmux driving is unverified (Smoke-Test Risk #8f).

### Longer-term / speculative

- **Issue dependency graph.** Machine-enforced cross-wave dependencies ("Wave 2 #X depends on Wave 1 #Y").
- **Cost telemetry.** Per-wave token counts so users can see what each wave actually costs.
- **Plugin marketplace submission.** Publish to the Anthropic-managed plugin marketplace once the protocol is stable.
- **Alternative event-delivery via `monitors/`.** Currently the wave-watcher is a single-shot background Bash. Claude Code's `monitors/monitors.json` supports tail-based notifications that push events to live sessions. Trade-off: monitors keep the conversation active (uses tokens for each event), background-Bash is silent until the wave ends. Worth exploring for short, chatty waves where mid-wave visibility matters more than token cost.

---

## How to update this file

When you finish a smoke test, move resolved Smoke-Test Risks to a "Resolved" subsection (don't delete — leave the resolution note for future readers). When you ship something from Future Work, move it to Status' "What's in place" list.

The WHITEPAPER is the design rationale (v2), edited only at major-version bumps (last: v1.0.0, §10.7 orchestration). This file is the living tracker.
