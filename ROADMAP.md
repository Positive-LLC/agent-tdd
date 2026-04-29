# Roadmap

Project status, known risks, and future work for agent-tdd. The design is in [WHITEPAPER.md](WHITEPAPER.md) (immutable v1 spec). The operational protocol is in [skills/atdd/PROTOCOL.md](skills/atdd/PROTOCOL.md). This file tracks what's built, what's broken, and what's next.

---

## Status

**v1 — built, pending end-to-end smoke test.**

What's in place:

- ✅ Plugin scaffold (`.claude-plugin/plugin.json`)
- ✅ Single user-facing skill: `/agent-tdd:atdd`
- ✅ `SKILL.md` (Root bootstrap + invariants)
- ✅ `PROTOCOL.md` (full operational spec, re-read at every phase boundary)
- ✅ Role markdowns for all three spawned-agent kinds (test, impl, rebase)
- ✅ Seven recipe scripts (init, spawn-test, spawn-impl, wave-watcher, wave-end-cleanup, terminate-root, notify)
- ✅ Issue template (§5.2 schema)
- ✅ Atomic status-write protocol
- ✅ Background-Bash event-watcher (single-shot, no timeout)
- ✅ Auto-merge + rebase ladder up to rung 4
- ✅ Root runs in its own worktree (`.agent-tdd/<root-id>/root/`) — multiple concurrent Roots in one repo no longer share the main worktree's HEAD/index. Root ID is claimed atomically via `mkdir`. (v0.2.0)

Not yet validated end-to-end. See **Smoke-Test Risks** below for the specific things to watch when running the first real workflow.

---

## Smoke-Test Risks (v1)

Three implementation choices that look correct on paper but haven't been exercised in a real session. Verify these first when running the first end-to-end test, and document the resolution here.

### 1. Multi-line prompt delivery via tmux

**Where:** `recipes/spawn-test-agent.sh`, `recipes/spawn-impl-agent.sh`.

**What we did:** Use `tmux load-buffer` + `tmux paste-buffer -p` (bracketed paste) to deliver the multi-line spawn prompt (role markdown + per-issue task block, ~250 lines) into the agent's tmux pane, then `tmux send-keys Enter` to submit.

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

### 3. `claude -p` argument-length limits

**Where:** `recipes/spawn-impl-agent.sh` (the launch line uses `claude -p "$(cat PROMPT_FILE)" ...`).

**What we did:** Pass the entire impl-agent prompt (`IMPL_AGENT_ROLE.md` + per-issue task block, ~290 lines / ~10–15 KB) as a single command-line argument.

**Risk:** OS argument-length limits (`ARG_MAX`, typically 128–2048 KB on Linux) shouldn't be a problem for ~15 KB, but tmux's `send-keys -l` on the constructed shell command line (a few hundred chars wrapping a `$(cat ...)` substitution) is what's actually sent. There may be:

- Quote-escaping issues when the prompt body contains shell metacharacters (backticks, `$`, `"`).
- tmux input rate-limiting on large `-l` payloads.
- `claude -p` truncating very large prompts on stdin/argv.

**If broken:** Switch to `claude -p --prompt-file PROMPT_FILE ...` if the CLI supports it; otherwise pipe via stdin: `cat PROMPT_FILE | claude -p --dangerously-skip-permissions ; tmux kill-window`.

---

## v1 Deferrals

These were considered during design and deliberately deferred. Source: WHITEPAPER §10.

- **Recursive spawning within a wave.** Test agents spawning test agents was explored and rejected: red tests cascading down child branches break the "narrow scope per impl agent" principle, and stacked PR fragility makes one-shot impl unreliable. The only sanctioned re-spawn is Root re-spawning aborted agents (bounded to 1 retry).
- **Stacked PRs across pairs.** Sibling test/impl pairs are flat off the Root branch; no PR depends on another sibling's PR.
- **Cross-wave dependency tracking beyond GitHub issue links.** No machine-enforced graph of "Wave 2 issue X depends on Wave 1 issue Y" — provenance lives in issue bodies only.
- **Auto-merge of Root branch to `main`.** Final integration is human-confirmed.
- **Crash recovery / Root resume protocol.** If Root or the host machine dies mid-wave, status files persist on disk but Root's conversation context is lost. v1 has no automatic resume; human re-launches Root and manually consults disk state. Future: a `/agent-tdd:resume <root-id>` slash command that re-derives state from `.agent-tdd/<root-id>/` + GitHub labels.

---

## Known Risks

Open risks to monitor through v1 use. Source: WHITEPAPER §11 + smoke-test learnings.

- **Dedup quality.** Structured templates make dedup tractable but not perfect. Some semantic dupes will slip through. Acceptable for v1.
- **Paused agents AFK for days.** The workflow blocks indefinitely on a paused agent. By design — fire-and-forget allows human gates. Add a "stale paused agent" warning if it becomes a UX problem.
- **Root branch lifetime.** Long-running Root branches drift from `main`. Recommend periodic `git merge main` into the Root branch between waves; automate later.
- **Crash recovery.** No automatic resume in v1. Human can re-launch Root and inspect `.agent-tdd/<root-id>/` to reconstruct state.
- **GitHub API rate limits.** With multiple Roots and large waves, the 5000/hr authenticated limit can bite. Issue creation, label updates, and `gh pr checks --watch` polling all count. Monitor and back off as needed.
- **Anthropic API rate limits.** Each child agent is a separate Claude session. Highly parallel waves on small accounts may rate-limit.
- **Test isolation.** Multiple parallel test runs (during impl agent CI) may interfere if the project uses shared resources (databases, fixed ports, shared on-disk state). Project-specific concern; document in your project README if relevant.
- **Worktree disk usage.** Each worktree is a full working tree. For large repos, N parallel worktrees = N× disk. Prune aggressively on terminal status.
- **`--dangerously-skip-permissions` for impl agents.** Required for non-interactive autonomy. Intended for trusted local repos; do not run Agent TDD against repos whose build steps would expose secrets to an unaudited shell.
- **Mode discipline is soft.** Once Root enters autopilot, nothing in Claude Code prevents the human from typing freeform and Root engaging inline. v1 mitigations: strong invariants in `SKILL.md`, plus Root prefixing every response with a `[wave-N: phase]` preamble. Hardening (hooks, settings.json policy) is post-v1.
- **Compaction over long workflows.** SKILL.md and PROTOCOL.md content may be evicted from context after auto-compaction during multi-hour workflows. Mitigation in `SKILL.md`: Root re-reads `${CLAUDE_SKILL_DIR}/PROTOCOL.md` and `.agent-tdd/<root-id>/` files at every phase transition. Verify this discipline holds in long sessions.

---

## Future Work

In rough priority order. Each item is a candidate for a v2 issue once v1 is validated.

### Near-term (after v1 smoke test passes)

- **Crash recovery skill.** `/agent-tdd:resume <root-id>` that re-derives Root state from disk + GitHub labels and resumes autopilot.
- **Stale-pause warning.** If a `.paused` file is older than 1 hour, surface to the dashboard window title automatically.
- **Intermittent `git push` blocked despite permission flag — verify `--permission-mode auto` resolves it.** During the second smoke test, 2/3 impl agents (#11, #13) reported `git push` blocked despite the launch wrapper passing `--dangerously-skip-permissions`; #12 in the same wave pushed successfully. Same hit/miss pattern as smoke run #1 (#7 blocked, #8 succeeded, #9 died before push). Hypothesis: project-level `.claude/settings.json` `permissions.ask` (`Bash(git push:*)`) and/or its `PreToolUse` Bash hook intercepts before the deprecated bypass flag takes effect. Switched the launch wrapper from `--dangerously-skip-permissions` to `--permission-mode auto` (per `claude --help`); revisit if the next smoke run still produces the same hit/miss pattern. If it does, investigate: project-scope settings overrides, `PreToolUse` hook timing, or `--permission-mode` semantics for blanket Bash-tool bypass.
- **Per-agent log bundle (impl + test).** Wrap `claude -p` in `spawn-impl-agent.sh` with stdout/stderr capture, exit-code recording, a `.crashed` status marker on non-zero exit (only when no terminal status was written), and hardened `tmux kill-window -t "$TMUX_PANE"` with retry. Add `tmux pipe-pane` to `spawn-test-agent.sh` so interactive test-agent panes are captured to disk too. Result: per-agent debug bundle at `.agent-tdd/<root-id>/wave-<N>/logs/issue-<X>/` containing `claude.stdout`, `claude.stderr`, `claude.exitcode`, `claude.timing.{start,end}` (impl) and `tmux.pane` (test). Closes two distinct smoke-test failure modes that this would have one-line-diagnosed: (1) issue-9's impl agent died silently mid-investigation with no terminal status, leaving the wave to hang until the 30-min heartbeat; (2) issue-8-PR's `tmux kill-window` returned 0 yet didn't kill the window — most likely a race with friday's `SessionEnd` hook subprocess teardown, which will recur on any session where friday is installed.
- **Heartbeat for stuck agents.** Detect when a wave has gone N minutes without status changes and no `.paused`, surface in dashboard.
- **`gh pr checks --watch` no-CI handling.** Pre-flight check (see Smoke-Test Risk #2) regardless of how risk #2 resolves.
- **End-to-end test harness.** A throwaway-repo script that automates the smoke-test playbook from the implementation plan, suitable for CI on this plugin itself.

### Medium-term

- **Mode-enforcement hooks.** `PreToolUse` hook that rejects human-initiated tool calls during a wave (e.g. block direct `gh` calls when Root is in autopilot), reducing the chance of human-induced state drift.
- **Periodic `git merge main` into the Root branch** between waves, automated.
- **Backlog visualization.** A dashboard skill that renders the current `.agent-tdd/<root-id>/` state + GitHub labels as a tree, for the human to skim.
- **Multi-root cross-dedup.** Concurrent Roots in one repo are now structurally safe at the git layer (each runs in its own worktree on its own integration branch — see Status). What's still missing: a shared dedup check so Root A doesn't open an `agent-tdd:pending` issue that Root B is already working on. Today each Root's dedup query filters by `agent-tdd:root-<id>`, so cross-Root overlap is invisible. Add a layer that ignores the root-id label when dedup'ing, OR have agents register a "claim" label early so other Roots can see in-flight scope.
- **Multi-user namespacing on a shared repo.** The plugin assumes one user per repo. Two users running concurrent waves on the same GitHub repo would collide on: (a) **`agent-tdd/<task>` integration branches** — the slug is human-supplied, both users picking `sync-fixes` collide on push; (b) **`agent-tdd:root-<id>` labels** — each user computes `root-1` independently from local `.agent-tdd/`, so issues across users all get the same label and per-user filtering breaks; (c) **backlog activation race** — both users' Wave 2 could pick up the same `agent-tdd:pending` issue; (d) **layer-1 dedup scope** — agents filter `agent-tdd:pending --label agent-tdd:root-<id>`, so they only see their own user's backlog and won't dedup against the other user's in-flight issues. (Issue/PR numbers are GitHub-unique per repo so safe; `.agent-tdd/<root-id>/` dirs are local-only and gitignored so safe.) Fix shape: namespace everything by `gh api user --jq .login` — Root ID becomes `<gh-user>-<n>`, integration branches `agent-tdd/<gh-user>/<task>`, labels `agent-tdd:root-<gh-user>-<n>`. Tradeoff: longer branch names; PROTOCOL.md examples and the SKILL.md root-id derivation step need updating; existing single-user state needs a migration shim or clean break. Add when the plugin gets a second user.

### Longer-term / speculative

- **Issue dependency graph.** Machine-enforced cross-wave dependencies ("Wave 2 #X depends on Wave 1 #Y").
- **Cost telemetry.** Per-wave token counts so users can see what each wave actually costs.
- **Plugin marketplace submission.** Publish to the Anthropic-managed plugin marketplace once the protocol is stable.
- **Alternative event-delivery via `monitors/`.** Currently the wave-watcher is a single-shot background Bash. Claude Code's `monitors/monitors.json` supports tail-based notifications that push events to live sessions. Trade-off: monitors keep the conversation active (uses tokens for each event), background-Bash is silent until the wave ends. Worth exploring for short, chatty waves where mid-wave visibility matters more than token cost.

---

## How to update this file

When you finish a smoke test, move resolved Smoke-Test Risks to a "Resolved" subsection (don't delete — leave the resolution note for future readers). When you ship something from Future Work, move it to Status' "What's in place" list.

The WHITEPAPER is immutable v1 design. This file is the living tracker.
