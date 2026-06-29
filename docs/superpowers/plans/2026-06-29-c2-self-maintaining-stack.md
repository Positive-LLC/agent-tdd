# C2 — Self-Maintaining Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **STOP FOR HUMAN REVIEW** of this plan before writing any code (per the design-spec process).

**Goal:** Make the atdd Stack maintain itself: each of the four agents (Notes/Root/Test/Impl) reads the Stack to orient throughout its task and, at its sharpest moment, writes/verifies the boxes it touched — enforced so the step cannot be silently skipped.

**Architecture:** A 3-layer hybrid, exactly mirroring the plugin's existing `lsp-surface.sh` / `stack-preflight.sh` pattern. (1) **Markdown** role-doc contracts say what/how. (2) A new **`stack-zoom.sh` recipe** (the plugin's own deterministic bash floor) runs `atdd stack verify` on the touched scope and, only on a clean verify, writes a per-(issue,role) completion **marker** in the wave status dir. (3) A Claude Code **`Stop` hook** (`hooks/hooks.json` + `hooks/stack-zoom-stop.sh`) blocks the *autonomous one-shot* agents (Test/Impl) from ending until that marker exists; Root/Notes are markdown+recipe only (they pause for the human, so a Stop hook would mis-fire).

**Tech Stack:** Bash recipes (`set -uo pipefail`), `jq`, `git`, the local `atdd` CLI (no GitHub in the inner flow). A Claude Code plugin `Stop` hook. Hermetic bash test gates driving the real `atdd` binary under a temp `ATDD_HOME` (`skills/atdd-plan/recipes/tests/run.sh`; `atdd-cli/tests/wave-coordination.sh`).

## Global Constraints

- **Built in `agent-tdd` only** — shell + markdown + one hook. **No `atdd-cli` product/schema change**; the only `atdd-cli` touch is a test-gate addition in `tests/wave-coordination.sh`.
- **No new `atdd` verbs.** Use the existing ones, exact signatures: `atdd --project <slug> layer add <ID> [--parent --repo --at --name --summary --by lsp|llm|human --confidence proposed|verified]`; `layer edit <ID> [--name --summary --parent --at --by --confidence]`; `layer link <ID> --issue <owner/repo#N>`; `interface add --upper <L> --lower <L> --comm request-response|callback|persistent|brokered [--id --owner upper|lower --at --summary --by --confidence]`; `process add --layer <L> --id <id> --name <n> [--trigger --in --out --at --by --confidence]`; `process port --process <id> --direction trigger|in|out --descriptor <d> [--interface <id>]`; `stack verify [--layer <slug>]` (exits non-zero on drift/blocked); `stack roots`; `stack zoom <id>`; `stack drift`.
- **Recipe conventions:** `set -uo pipefail`; progress + diagnostics to **stderr**; only machine-readable value to **stdout**; absolute paths; idempotent/resumable; **zero `gh`** in the inner flow (the test harness's poison `gh` enforces this).
- **`${CLAUDE_SKILL_DIR}` / `${PLUGIN_DIR}`** are the canonical path roots in markdown contracts — never hard-code paths. Reference the single guide as the role doc already does (`STACK_USAGE.md`).
- **LSP-mandatory is inherited from C1** (`stack-preflight.sh`, atdd #2/#32) — `stack verify` reports a `#symbol` anchor with no registered LSP as `blocked` (exits non-zero). C2 does not re-implement it; `stack-zoom.sh` simply surfaces a non-zero verify as BLOCKED (exit 3).
- **Marker naming (the contract between recipe, hook, and gate):** `${STATUS_DIR}/issue-${ISSUE}.stack-zoom-${ROLE}` for the one-shot agents (Test/Impl share an issue # and status dir — the `-${ROLE}` suffix prevents collision). Root/Notes use their own marker path (not hook-gated).
- **Hook scope:** the launcher exports `ATDD_ROLE` (`test`|`impl` only), `ATDD_ISSUE`, `ATDD_STATUS_DIR` into the agent's `claude` process. Any session without `ATDD_ROLE ∈ {test,impl}` (the human's own session, Root, Notes) makes the hook no-op. Honor `stop_hook_active`; never lock an agent out.
- **`atdd-cli` build floor:** the `stack`/`layer` verbs require a v2 build. The recipe tests use `target/debug/atdd`; run `cargo build` in `../atdd-cli` first. `make use-dev-atdd` symlinks the dev build for live runs.
- **Thoroughness floor (locked):** even a task that creates no new box still runs `stack-zoom.sh` (it verifies the box it sits in). Declare only the boxes you directly touched — never the whole subtree, never boxes you only read.

---

## File Structure

- **Create `skills/atdd/recipes/stack-zoom.sh`** — the deterministic floor: `stack verify` the touched scope, write the completion marker on a clean verify. Used by all four agents (Notes via the cross-skill `${CLAUDE_SKILL_DIR}/../atdd/recipes/` path).
- **Create `hooks/hooks.json`** — register the `Stop` hook (plugin-shipped).
- **Create `hooks/stack-zoom-stop.sh`** — the `Stop`-hook script (Test/Impl backstop).
- **Modify `skills/atdd/recipes/launch-impl-agent.sh`** — export `ATDD_ROLE=impl` + issue/status-dir before launching `claude`.
- **Modify `skills/atdd/recipes/spawn-test-agent.sh`** — extend the `claude` env prefix with `ATDD_ROLE=test` + issue/status-dir.
- **Modify `skills/STACK_USAGE.md`** — add the "end-of-task zoom-in" section (the per-agent WRITE contract + thoroughness floor + READ-to-orient); bump `STACK-USAGE-SYNC: v1 → v2` (and in the `atdd-cli/STACK_USAGE.md` copy).
- **Modify `skills/atdd/roles/IMPL_AGENT_ROLE.md`** — Step 6.5 (WRITE, before `.done`) + a READ-to-orient line.
- **Modify `skills/atdd/roles/TEST_AGENT_ROLE.md`** — Step 6.5 (WRITE `proposed`, before spawn) + a READ-to-orient line.
- **Modify `skills/atdd/PROTOCOL.md`** — Root §3.5 step 3: zoom-in verify on the integrated subtree after `integrate`.
- **Modify `skills/atdd-plan/CORE.md`** — Notes §5: READ-to-orient (step 0) + Touch-1 (step 7.5, declare `proposed` shape).
- **Modify `skills/atdd-plan/ORCHESTRATE.md`** — Notes §6: Touch-2 (verify the merged shape before closing the RootIssue).
- **Modify `skills/atdd-plan/recipes/tests/run.sh`** — `== stack-zoom ==` (recipe), `== stack-zoom hook ==` (hook script), and bootstrap-wiring grep asserts for all role-doc references.
- **Modify `../atdd-cli/tests/wave-coordination.sh`** — assert the impl zoom-in marker gates `.done` end-to-end.

---

### Task 1: `stack-zoom.sh` recipe + hermetic test

**Files:**
- Create: `skills/atdd/recipes/stack-zoom.sh`
- Test: `skills/atdd-plan/recipes/tests/run.sh` (append a `== stack-zoom ==` section)

**Interfaces:**
- Produces: `stack-zoom.sh --project <slug> --marker <file> [--layer <slug>]`. Defaults `--project` from `$ATDD_PROJECT`. Exit `0` = verify clean + marker written; `3` = BLOCKED (drift/blocked anchor, no marker); `2` = hard error.

- [ ] **Step 1: Write the failing test** — append to `skills/atdd-plan/recipes/tests/run.sh` (before the final `summary`):

```bash
# ────────────────────────────────────────────────────────────────────────────
echo "== stack-zoom (recipe: verify touched scope, write marker on clean) =="
setup_repo                      # temp git repo + isolated ATDD_HOME + atdd on PATH
SZ="${RECIPES_DIR}/../atdd/recipes/stack-zoom.sh"
PROJ=zoomproj
atdd project create "$PROJ" --title 'zoom' >/dev/null
atdd --project "$PROJ" repo register acme/z "$WORK" >/dev/null
# a real file to anchor a clean layer at:
mkdir -p "${WORK}/src"; echo 'fn main(){}' > "${WORK}/src/lib.rs"; git -C "$WORK" add -A; git -C "$WORK" commit -qm src
atdd --project "$PROJ" layer add z/core --repo acme/z --name Core --at 'acme/z:src/lib.rs' --by llm --confidence verified >/dev/null
MK="${WORK}/issue-1.stack-zoom-impl"

# clean verify -> exit 0 + marker
( bash "$SZ" --project "$PROJ" --layer z/core --marker "$MK" >/dev/null 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && ok "stack-zoom exits 0 on a clean verify" || fail "stack-zoom clean exit" "rc=$rc"
[[ -f "$MK" ]] && ok "stack-zoom wrote the completion marker" || fail "marker written"

# drift -> exit 3 + NO marker
rm -f "$MK"
atdd --project "$PROJ" layer edit z/core --at 'acme/z:src/GONE.rs' >/dev/null
( bash "$SZ" --project "$PROJ" --layer z/core --marker "$MK" >/dev/null 2>&1 ); rc=$?
[[ $rc -eq 3 ]] && ok "stack-zoom exits 3 (BLOCKED) on drift" || fail "stack-zoom drift exit" "rc=$rc"
[[ ! -f "$MK" ]] && ok "stack-zoom withholds the marker on drift" || fail "marker withheld on drift"

# bad args -> exit 2
( bash "$SZ" --marker "$MK" >/dev/null 2>&1 ); rc=$?     # missing --project (and no $ATDD_PROJECT)
[[ $rc -eq 2 ]] && ok "stack-zoom exits 2 on missing --project" || fail "stack-zoom bad-args exit" "rc=$rc"
teardown_repo
```

- [ ] **Step 2: Run it to verify it fails** — `bash skills/atdd-plan/recipes/tests/run.sh`. Expected: the `== stack-zoom ==` checks FAIL (recipe not found / non-executable).

- [ ] **Step 3: Write the recipe** — create `skills/atdd/recipes/stack-zoom.sh`:

```bash
#!/usr/bin/env bash
# stack-zoom.sh — the end-of-task Stack zoom-in gate (Phase C / C2).
#
# The DETERMINISTIC half of the self-maintaining Stack. After an agent has
# DECLARED the boxes it touched (layer/interface/process add|edit + layer link
# --issue — the judgment half, done by the agent per STACK_USAGE.md), this recipe
# VERIFIES the touched scope against today's code and, only on a clean verify,
# writes a completion marker. The marker is the proof the zoom-in ran; the Stop
# hook (hooks/stack-zoom-stop.sh) and the coordination gate key off it.
#
# It does NOT decide which boxes to declare — it cannot know what SHOULD exist.
# It guarantees "what you declared verifies clean", not "you declared enough";
# thoroughness is the markdown contract's job (STACK_USAGE.md).
#
# Usage:
#   stack-zoom.sh [--project <slug>] --marker <file> [--layer <layer-slug>]
#     --project  atdd project slug (defaults to $ATDD_PROJECT; required either way)
#     --marker   absolute path of the completion marker to write on a clean verify
#     --layer    restrict `stack verify` to this layer's subtree (default: all)
#
# stdout: the `atdd stack verify` JSON (kept for the caller/log).
# exit:   0 = verify clean, marker written · 3 = BLOCKED (drift/blocked; no marker)
#         · 2 = hard error (bad args / atdd missing).
set -uo pipefail

log() { printf '[stack-zoom] %s\n' "$*" >&2; }
die() { printf '[stack-zoom] ERROR: %s\n' "$*" >&2; exit 2; }

PROJECT=""; MARKER=""; LAYER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --marker)  MARKER="${2:-}";  shift 2 ;;
    --layer)   LAYER="${2:-}";   shift 2 ;;
    *) die "unknown arg: $1 (usage: stack-zoom.sh [--project <slug>] --marker <file> [--layer <slug>])" ;;
  esac
done
[[ -n "$PROJECT" ]] || PROJECT="${ATDD_PROJECT:-}"
[[ -n "$PROJECT" ]] || die "no project: pass --project <slug> or set \$ATDD_PROJECT"
[[ -n "$MARKER"  ]] || die "--marker <file> is required"
command -v atdd >/dev/null 2>&1 || die "atdd not found on PATH (ensure-atdd.sh runs at bootstrap)"

if [[ -n "$LAYER" ]]; then
  OUT="$(atdd --project "$PROJECT" stack verify --layer "$LAYER")"; rc=$?
else
  OUT="$(atdd --project "$PROJECT" stack verify)"; rc=$?
fi
printf '%s\n' "$OUT"

if [[ $rc -ne 0 ]]; then
  {
    echo "[stack-zoom] ───── STACK ZOOM-IN: BLOCKED ─────────────────────────────────"
    echo "[stack-zoom] \`stack verify\` is not clean (drift, or a #symbol anchor blocked"
    echo "[stack-zoom] for want of a registered LSP). Fix the anchor(s) you just declared"
    echo "[stack-zoom] (typo'd path / moved symbol) or register the LSP, then re-run. The"
    echo "[stack-zoom] completion marker is NOT written until verify is clean."
    echo "[stack-zoom] ────────────────────────────────────────────────────────────────"
  } >&2
  exit 3
fi

mkdir -p "$(dirname "$MARKER")"
printf '{"zoom":"ok","project":"%s","layer":"%s","at":"%s"}\n' \
  "$PROJECT" "${LAYER:-*}" "$(date -Iseconds 2>/dev/null || echo unknown)" > "$MARKER"
log "zoom-in clean — wrote marker ${MARKER}"
exit 0
```

- [ ] **Step 4: Make it executable** — `chmod +x skills/atdd/recipes/stack-zoom.sh`

- [ ] **Step 5: Run the test to verify it passes** — `bash skills/atdd-plan/recipes/tests/run.sh`. Expected: the `== stack-zoom ==` checks PASS.

- [ ] **Step 6: Commit**

```bash
git add skills/atdd/recipes/stack-zoom.sh skills/atdd-plan/recipes/tests/run.sh
git commit -m "feat(stack): stack-zoom.sh — the end-of-task verify+marker gate (C2)"
```

---

### Task 2: `STACK_USAGE.md` end-of-task zoom-in section + sync bump

**Files:**
- Modify: `skills/STACK_USAGE.md` (add a section; bump the sync marker)
- Modify: `../atdd-cli/STACK_USAGE.md` (bump the sync marker to match)

**Interfaces:**
- Consumes: the `stack-zoom.sh` contract from Task 1.
- Produces: the single agent-facing "end-of-task zoom-in" contract every role doc points at.

- [ ] **Step 1: Add the section** — append to `skills/STACK_USAGE.md` (before the `## 7. Verb quick-reference` section):

```markdown
## 6b. The end-of-task zoom-in (mandatory — the self-maintaining loop)

Every agent maintains the Stack as a by-product of finishing its task, at the moment its
understanding is sharpest. Two directions:

- **READ to orient (throughout):** before you change a layer, `stack roots` then `stack zoom <id>`
  to see where your work sits — which layer, which side of which interface. Navigate one level at a
  time; never reconstruct the whole graph.
- **WRITE at your sharpest moment (at the end):** declare/update **only the boxes your work touched**
  (never the whole subtree, never boxes you only read), then run the `stack-zoom.sh` recipe — it
  `stack verify`s the touched scope and writes the completion marker the wave keys off.

**Per agent:**
- **Test** (after authoring the red tests + recording the test command, before spawning Impl):
  declare the *interface / behavioral contract* you pinned as `--by llm --confidence proposed`,
  anchored at a file that **already exists** (your test file, or the SUT file) — never at a
  `#symbol` the impl has not written yet (it would not resolve and would block you).
- **Impl** (right after `record-green`, before writing `.done`): declare/update the *layer(s) /
  process(es)* you created or changed as `--by llm --confidence verified`, anchored at the real
  symbol (LSP-backed). Promote any `proposed` box the Test agent left for this contract.
- **Root** (after `atdd integrate`, before marking the issue merged): `stack verify` the integrated
  subtree; reconcile any cross-issue interface that only became real at merge.
- **Notes** — two touches: **(1)** just before decomposing a RootIssue, declare the *intended* shape
  it will change as `--by llm --confidence proposed` (a prediction); **(2)** after the cohort's final
  merges, `stack verify` those boxes and reconcile (`proposed`→`verified`, fix anchors, or record
  honest drift) before closing the RootIssue.

**Thoroughness floor:** even a task that creates no new box runs `stack-zoom.sh` — it verifies the
box you sit in is still accurate. Always `layer link <slug> --issue <owner/repo#N>` so the work-item
is bridged to the box it changed.

**The recipe (the deterministic gate):**
```bash
bash "${PLUGIN_DIR}/recipes/stack-zoom.sh" --project "$ATDD_PROJECT" \
  --layer <touched-layer-slug> --marker "<status-dir>/issue-<N>.stack-zoom-<role>"
```
Exit 0 → marker written → proceed. Exit 3 (BLOCKED: drift, or a `#symbol` with no LSP) → fix the
anchor / register the LSP, then re-run. **Do not finish your task until it exits 0.**
```

- [ ] **Step 2: Bump the sync marker in the plugin guide** — in `skills/STACK_USAGE.md`, change `STACK-USAGE-SYNC: v1` to `STACK-USAGE-SYNC: v2`.

- [ ] **Step 3: Bump the sync marker in the atdd-cli copy** — in `../atdd-cli/STACK_USAGE.md`, change `STACK-USAGE-SYNC: v1` to `STACK-USAGE-SYNC: v2` (the drift gate requires both to match).

- [ ] **Step 4: Verify the sync gate stays green** — `bash ../atdd-cli/tests/stack-usage-sync.sh`. Expected: `PASSED` with `markers match (v2)`.

- [ ] **Step 5: Commit** (in each repo)

```bash
git add skills/STACK_USAGE.md && git commit -m "docs(stack): STACK_USAGE.md — the end-of-task zoom-in contract (C2); sync v2"
( cd ../atdd-cli && git add STACK_USAGE.md && git commit -m "docs(stack): bump STACK-USAGE-SYNC v2 (plugin added the end-of-task zoom-in)" )
```

---

### Task 3: the `Stop` hook + launcher env wiring + hook test

**Files:**
- Create: `hooks/hooks.json`, `hooks/stack-zoom-stop.sh`
- Modify: `skills/atdd/recipes/launch-impl-agent.sh` (export impl context), `skills/atdd/recipes/spawn-test-agent.sh` (export test context)
- Test: `skills/atdd-plan/recipes/tests/run.sh` (append a `== stack-zoom hook ==` section)

**Interfaces:**
- Consumes: the marker path contract `${ATDD_STATUS_DIR}/issue-${ATDD_ISSUE}.stack-zoom-${ATDD_ROLE}`.
- Produces: a `Stop` hook that no-ops unless `ATDD_ROLE ∈ {test,impl}` and blocks until the marker exists.

- [ ] **Step 1: Write the failing test** — append to `skills/atdd-plan/recipes/tests/run.sh` (before `summary`):

```bash
# ────────────────────────────────────────────────────────────────────────────
echo "== stack-zoom hook (Stop-hook backstop for test/impl) =="
HK="$(cd -- "${RECIPES_DIR}/../.." && pwd)/../hooks/stack-zoom-stop.sh"   # skills/.. -> plugin root /hooks
HK="$(cd -- "${RECIPES_DIR}/../../.." && pwd)/hooks/stack-zoom-stop.sh"   # plugin root = skills/..
HKDIR="$(mktemp -d)"; SD="${HKDIR}/status"; mkdir -p "$SD"

# (a) not an agent context -> no-op (exit 0, no output)
out="$(printf '{"stop_hook_active":false}' | bash "$HK")"; rc=$?
{ [[ $rc -eq 0 && -z "$out" ]]; } && ok "hook no-ops outside an agent context" || fail "hook no-op" "rc=$rc out=$out"

# (b) impl context, marker ABSENT -> block JSON
out="$(printf '{"stop_hook_active":false}' | ATDD_ROLE=impl ATDD_ISSUE=7 ATDD_STATUS_DIR="$SD" bash "$HK")"; rc=$?
{ [[ $rc -eq 0 ]] && jq -e '.hookSpecificOutput.decision=="block"' >/dev/null <<<"$out"; } \
  && ok "hook blocks impl with no marker" || fail "hook block" "rc=$rc out=$out"

# (c) impl context, marker PRESENT -> allow (exit 0, no output)
: > "${SD}/issue-7.stack-zoom-impl"
out="$(printf '{"stop_hook_active":false}' | ATDD_ROLE=impl ATDD_ISSUE=7 ATDD_STATUS_DIR="$SD" bash "$HK")"; rc=$?
{ [[ $rc -eq 0 && -z "$out" ]]; } && ok "hook allows impl once marker exists" || fail "hook allow" "rc=$rc out=$out"

# (d) loop guard: stop_hook_active=true -> allow even with no marker
out="$(printf '{"stop_hook_active":true}' | ATDD_ROLE=impl ATDD_ISSUE=9 ATDD_STATUS_DIR="$SD" bash "$HK")"; rc=$?
{ [[ $rc -eq 0 && -z "$out" ]]; } && ok "hook honors stop_hook_active (never locks out)" || fail "hook loop-guard" "rc=$rc out=$out"
rm -rf "$HKDIR"
```

*(Note for the implementer: delete the first `HK=` line — it is shown only to make the plugin-root math explicit. The correct path is the second: plugin root is `skills/..`, hooks live at `<plugin-root>/hooks/`.)*

- [ ] **Step 2: Run it to verify it fails** — `bash skills/atdd-plan/recipes/tests/run.sh`. Expected: `== stack-zoom hook ==` checks FAIL (script not found).

- [ ] **Step 3: Write the hook script** — create `hooks/stack-zoom-stop.sh`:

```bash
#!/usr/bin/env bash
# stack-zoom-stop.sh — Claude Code `Stop` hook: the hard backstop that keeps a
# one-shot worker agent (Test / Impl) from ending until its end-of-task Stack
# zoom-in has run clean (the completion marker exists). Phase C / C2, Layer 3.
#
# Scope: ONLY the autonomous one-shot agents. The launcher exports, into the
# agent's `claude` process env:
#   ATDD_ROLE        test | impl   (set ONLY for those two; absent otherwise)
#   ATDD_ISSUE       <N>
#   ATDD_STATUS_DIR  <wave status dir>
# Any other session (the human's own, Root, Notes — which pause for the human and
# would mis-fire) has no ATDD_ROLE in {test,impl}, so this hook no-ops (exit 0).
#
# stdin:  the Stop hook JSON ({..,"stop_hook_active":bool}).
# stdout: on block, the decision JSON; otherwise nothing.
# exit:   always 0 (control is the JSON, never the exit code).
set -uo pipefail

INPUT="$(cat 2>/dev/null || true)"

# Loop guard: if we are already the active blocking Stop hook, let the agent stop
# (the 8-block cap also backstops). Never lock an agent out.
if command -v jq >/dev/null 2>&1; then
  [[ "$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null)" == "true" ]] && exit 0
fi

case "${ATDD_ROLE:-}" in
  test|impl) ;;            # enforce for the one-shot workers
  *) exit 0 ;;             # any other context — no-op
esac

ISSUE="${ATDD_ISSUE:-}"; SDIR="${ATDD_STATUS_DIR:-}"
[[ -n "$ISSUE" && -n "$SDIR" ]] || exit 0          # missing context — no-op (never lock out)

MARKER="${SDIR}/issue-${ISSUE}.stack-zoom-${ATDD_ROLE}"
[[ -f "$MARKER" ]] && exit 0                        # zoom-in clean — allow stop

cat <<EOF
{"hookSpecificOutput":{"hookEventName":"Stop","decision":"block","reason":"End-of-task Stack zoom-in not done for issue ${ISSUE} (role ${ATDD_ROLE}). Per STACK_USAGE.md (the end-of-task zoom-in), update the Stack for the boxes you touched, then run skills/atdd/recipes/stack-zoom.sh (it runs \`atdd stack verify\` and writes the completion marker). You cannot finish until that recipe exits 0."}}
EOF
exit 0
```

- [ ] **Step 4: Make it executable** — `chmod +x hooks/stack-zoom-stop.sh`

- [ ] **Step 5: Write the plugin hook manifest** — create `hooks/hooks.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/hooks/stack-zoom-stop.sh", "timeout": 30 }
        ]
      }
    ]
  }
}
```

- [ ] **Step 6: Export the impl context** — in `skills/atdd/recipes/launch-impl-agent.sh`, immediately before the `if [[ "${AGENT_TDD_CLI}" == "opencode" ]]; then` launch block (after the `date -Ins > "${LOG_DIR}/agent.timing.start"` line), add:

```bash
# C2: give the Stop hook (hooks/stack-zoom-stop.sh) the context to enforce the
# end-of-task Stack zoom-in for this impl agent. Only test/impl set ATDD_ROLE,
# so the hook no-ops in every other claude session.
export ATDD_ROLE=impl ATDD_ISSUE="${ISSUE_NUM}" ATDD_STATUS_DIR="${STATUS_DIR}"
```

- [ ] **Step 7: Export the test context** — in `skills/atdd/recipes/spawn-test-agent.sh`, change the `claude` launch line (currently `tmux send-keys -t "${TARGET}" "ATDD_PROJECT='${PROJECT_SLUG}' claude --permission-mode bypassPermissions" Enter`) to:

```bash
	tmux send-keys -t "${TARGET}" "ATDD_PROJECT='${PROJECT_SLUG}' ATDD_ROLE=test ATDD_ISSUE='${ISSUE_NUM}' ATDD_STATUS_DIR='${STATUS_DIR}' claude --permission-mode bypassPermissions" Enter
```

- [ ] **Step 8: Run the hook test to verify it passes** — `bash skills/atdd-plan/recipes/tests/run.sh`. Expected: `== stack-zoom hook ==` checks PASS.

- [ ] **Step 9: Commit**

```bash
git add hooks/hooks.json hooks/stack-zoom-stop.sh skills/atdd/recipes/launch-impl-agent.sh skills/atdd/recipes/spawn-test-agent.sh skills/atdd-plan/recipes/tests/run.sh
git commit -m "feat(stack): Stop-hook backstop forcing the end-of-task zoom-in for test/impl (C2)"
```

---

### Task 4: Wire the zoom-in into the one-shot agents (IMPL + TEST role docs)

**Files:**
- Modify: `skills/atdd/roles/IMPL_AGENT_ROLE.md`, `skills/atdd/roles/TEST_AGENT_ROLE.md`
- Test: `skills/atdd-plan/recipes/tests/run.sh` (extend the `== bootstrap wiring ==` grep gate)

**Interfaces:**
- Consumes: `stack-zoom.sh` (Task 1), the marker contract (Task 3), the `STACK_USAGE.md` section (Task 2).

- [ ] **Step 1: Write the failing grep gate** — in `skills/atdd-plan/recipes/tests/run.sh`, inside the existing `== bootstrap wiring ==` block, add:

```bash
grep -q 'stack-zoom.sh' "${SKILLS_DIR}/atdd/roles/IMPL_AGENT_ROLE.md" \
  && pass "IMPL role doc wires the end-of-task zoom-in (stack-zoom.sh)" \
  || fail "IMPL role doc wires stack-zoom.sh" "no reference"
grep -q 'stack-zoom.sh' "${SKILLS_DIR}/atdd/roles/TEST_AGENT_ROLE.md" \
  && pass "TEST role doc wires the end-of-task zoom-in (stack-zoom.sh)" \
  || fail "TEST role doc wires stack-zoom.sh" "no reference"
grep -q 'stack-zoom-impl' "${SKILLS_DIR}/atdd/roles/IMPL_AGENT_ROLE.md" \
  && pass "IMPL role doc uses the impl marker name" || fail "IMPL marker name" "no issue-<N>.stack-zoom-impl"
grep -q 'confidence proposed' "${SKILLS_DIR}/atdd/roles/TEST_AGENT_ROLE.md" \
  && pass "TEST role doc declares its contract as proposed" || fail "TEST proposed" "no 'confidence proposed'"
```

- [ ] **Step 2: Run it to verify it fails** — `bash skills/atdd-plan/recipes/tests/run.sh`. Expected: the four new grep checks FAIL.

- [ ] **Step 3: Add the IMPL WRITE step** — in `skills/atdd/roles/IMPL_AGENT_ROLE.md`, insert between the end of `### Step 6: Reach green locally` (after the "Do not loop…" paragraph) and `### Step 7: Write terminal status`:

```markdown
### Step 6.5: End-of-task Stack zoom-in (mandatory — before Step 7)

Your understanding of what you built is sharpest now. Update the Stack for the boxes you
**touched** (only those — never the whole subtree), then verify. Contract: the "end-of-task
zoom-in" section of `${PLUGIN_DIR}/../STACK_USAGE.md`.

1. Declare what you created/changed, anchored at the real symbol, `verified` (promote any
   `proposed` box the Test agent left for this contract):
   ```bash
   atdd --project "$ATDD_PROJECT" layer edit <slug> --at '<owner/repo>:<path>#<Symbol>' --by llm --confidence verified
   atdd --project "$ATDD_PROJECT" layer link <slug> --issue <owner/repo>#${ISSUE_NUM}
   ```
2. Verify + record (the gate):
   ```bash
   bash "${PLUGIN_DIR}/recipes/stack-zoom.sh" --project "$ATDD_PROJECT" \
     --layer <touched-layer-slug> --marker "${STATUS_DIR}/issue-${ISSUE_NUM}.stack-zoom-impl"
   ```
   Exit 0 → proceed to Step 7. Exit 3 (BLOCKED) → fix the anchor / register the LSP, re-run.
   **Do not write `.done` until this exits 0.** (A task that changed no boundary still runs it.)
```

- [ ] **Step 4: Add the IMPL READ-to-orient line** — in `skills/atdd/roles/IMPL_AGENT_ROLE.md`, at the start of the implementation protocol (before the first build step), add:

```markdown
> **Orient first (READ the Stack):** before you change code, `atdd --project "$ATDD_PROJECT" stack roots`
> then `stack zoom <id>` to see which layer/interface you are about to touch. See `${PLUGIN_DIR}/../STACK_USAGE.md`.
```

- [ ] **Step 5: Add the TEST WRITE step** — in `skills/atdd/roles/TEST_AGENT_ROLE.md`, insert between the end of `### Step 6: Record the test command(s)` and `### Step 7: Spawn the Impl Agent`:

```markdown
### Step 6.5: End-of-task Stack zoom-in (mandatory — before Step 7)

You have just pinned this issue's behavioral contract — your understanding of the boundary is
sharpest now. Record it, then verify. Contract: the "end-of-task zoom-in" section of
`${PLUGIN_DIR}/../STACK_USAGE.md`.

1. Declare the interface/contract you pinned as `proposed` (the impl does not exist yet),
   anchored at a file that **already exists** (your test file, or the SUT file) — never at a
   `#symbol` the impl has not written yet:
   ```bash
   atdd --project "$ATDD_PROJECT" interface add --id <id> --upper <L> --lower <L> --comm <type> \
     --at '<owner/repo>:<existing-path>' --by llm --confidence proposed
   atdd --project "$ATDD_PROJECT" layer link <slug> --issue <owner/repo>#${ISSUE_NUM}
   ```
2. Verify + record (the gate):
   ```bash
   bash "${PLUGIN_DIR}/recipes/stack-zoom.sh" --project "$ATDD_PROJECT" \
     --marker "${STATUS_DIR}/issue-${ISSUE_NUM}.stack-zoom-test"
   ```
   Exit 0 → proceed to Step 7 (spawn impl). Exit 3 → point the anchor at a file that exists, re-run.
   **Do not spawn the impl agent until this exits 0.**
```

- [ ] **Step 6: Add the TEST READ-to-orient line** — in `skills/atdd/roles/TEST_AGENT_ROLE.md`, inside `### Step 3` (Understand the codebase), add:

```markdown
> **Orient (READ the Stack):** `atdd --project "$ATDD_PROJECT" stack roots` then `stack zoom <id>` to
> see the layer/interface the code-under-test sits in, so your test boundary matches the real one.
```

- [ ] **Step 7: Run the grep gate to verify it passes** — `bash skills/atdd-plan/recipes/tests/run.sh`. Expected: all `== bootstrap wiring ==` checks PASS.

- [ ] **Step 8: Commit**

```bash
git add skills/atdd/roles/IMPL_AGENT_ROLE.md skills/atdd/roles/TEST_AGENT_ROLE.md skills/atdd-plan/recipes/tests/run.sh
git commit -m "feat(stack): wire the end-of-task zoom-in into the Impl + Test role docs (C2)"
```

---

### Task 5: Wire Root (PROTOCOL) + Notes (CORE/ORCHESTRATE)

**Files:**
- Modify: `skills/atdd/PROTOCOL.md`, `skills/atdd-plan/CORE.md`, `skills/atdd-plan/ORCHESTRATE.md`
- Test: `skills/atdd-plan/recipes/tests/run.sh` (extend the `== bootstrap wiring ==` grep gate)

**Interfaces:**
- Consumes: `stack-zoom.sh` (Task 1), the `STACK_USAGE.md` section (Task 2). Root/Notes are NOT hook-gated (soft enforcement, human-in-loop).

- [ ] **Step 1: Write the failing grep gate** — in `skills/atdd-plan/recipes/tests/run.sh`, inside `== bootstrap wiring ==`, add:

```bash
grep -q 'stack-zoom.sh' "${SKILLS_DIR}/atdd/PROTOCOL.md" \
  && pass "Root PROTOCOL wires the post-integrate zoom-in" || fail "Root PROTOCOL wires stack-zoom.sh" "no reference"
grep -q 'stack-zoom.sh' "${SKILLS_DIR}/atdd-plan/CORE.md" \
  && pass "Notes CORE wires Touch-1 (declare proposed shape)" || fail "Notes CORE wires stack-zoom.sh" "no reference"
grep -q 'stack-zoom.sh' "${SKILLS_DIR}/atdd-plan/ORCHESTRATE.md" \
  && pass "Notes ORCHESTRATE wires Touch-2 (verify before close)" || fail "Notes ORCHESTRATE wires stack-zoom.sh" "no reference"
```

- [ ] **Step 2: Run it to verify it fails** — Expected: the three new grep checks FAIL.

- [ ] **Step 3: Add the Root zoom-in** — in `skills/atdd/PROTOCOL.md` §3.5 step 3 (the `atdd integrate` step), append to that step:

```markdown
   On a successful merge, **before** writing `merged:true`: run the Stack zoom-in verify on the
   integrated subtree and reconcile any cross-issue interface that only became real at merge
   (promote `proposed`→`verified`, fix anchors). Sharpest-moment contract: `${CLAUDE_SKILL_DIR}/../STACK_USAGE.md`.
   ```bash
   bash ${CLAUDE_SKILL_DIR}/../atdd/recipes/stack-zoom.sh --project <slug> \
     --marker <root-worktree>/.atdd/<root-id>/wave-<N>/status/wave-<N>.stack-zoom-root
   ```
   If it exits 3 (post-merge drift/blocked), treat it as a post-merge regression and climb §3.7.
```

- [ ] **Step 4: Add the Notes READ-to-orient + Touch-1** — in `skills/atdd-plan/CORE.md` §5, add a step 0 before "1. Investigate privately", and a step 7.5 after "7. After each batch of writes, regenerate the index…":

```markdown
0. **Orient (READ the Stack).** `atdd --project <slug> stack roots` to place this head in the
   existing architecture before you trace code. See `${CLAUDE_SKILL_DIR}/../STACK_USAGE.md`.
```
```markdown
7.5. **Declare the intended shape (Touch-1, before you move on).** Record the layers/interfaces this
   RootIssue will add or move as a *prediction* — `--by llm --confidence proposed`, anchored where you
   expect the code to land — and `layer link --issue` the RootIssue. The workers + the LSP verify it
   later (Touch-2). Then run the recipe so the prediction is registered + checked:
   ```bash
   bash ${CLAUDE_SKILL_DIR}/../atdd/recipes/stack-zoom.sh --project <slug> \
     --marker <notebook-dir>/<root-ref>.stack-zoom-notes-declared
   ```
```

- [ ] **Step 5: Add the Notes Touch-2** — in `skills/atdd-plan/ORCHESTRATE.md` §6 step 5 (close the RootIssue), insert before closing:

```markdown
   **Before closing — Touch-2 (verify the prediction held):** run the Stack zoom-in on the boxes you
   declared in CORE §5 step 7.5; promote `proposed`→`verified`, fix anchors, or record honest drift.
   ```bash
   bash ${CLAUDE_SKILL_DIR}/../atdd/recipes/stack-zoom.sh --project <slug> \
     --marker <notebook-dir>/<root-ref>.stack-zoom-notes-verified
   ```
   A non-zero exit is signal, not a blocker here (the human is in this review) — surface the drift in
   the close.
```

- [ ] **Step 6: Run the grep gate to verify it passes** — Expected: all `== bootstrap wiring ==` checks PASS.

- [ ] **Step 7: Commit**

```bash
git add skills/atdd/PROTOCOL.md skills/atdd-plan/CORE.md skills/atdd-plan/ORCHESTRATE.md skills/atdd-plan/recipes/tests/run.sh
git commit -m "feat(stack): wire the zoom-in into Root (post-integrate) + Notes (two-touch) (C2)"
```

---

### Task 6: End-to-end coordination gate (impl marker gates `.done`)

**Files:**
- Modify: `../atdd-cli/tests/wave-coordination.sh`

**Interfaces:**
- Consumes: `stack-zoom.sh` (Task 1), the marker contract (Task 3). Proves the seam with no LLM.

- [ ] **Step 1: Write the failing assertion** — in `../atdd-cli/tests/wave-coordination.sh`, after the `record-green` block (right after the `ok "Impl agent reached green locally"` line, before the `.done` status is written) add:

```bash
# ── C2: the impl agent's end-of-task Stack zoom-in (declare + verify + marker) ──
SZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../agent-tdd/skills/atdd/recipes" && pwd)/stack-zoom.sh"
if [[ -x "$SZ" ]]; then
  "$ATDD_BIN" --project default layer add calc/core --repo local/calc --name Core --at 'local/calc:calc.sh' --by llm --confidence verified >/dev/null 2>&1 || true
  MK="${WAVE_DIR}/status/issue-1.stack-zoom-impl"
  ( ATDD_PROJECT=default bash "$SZ" --marker "$MK" >/dev/null 2>&1 ); rc=$?
  { [[ $rc -eq 0 && -f "$MK" ]]; } && ok "impl zoom-in verified + wrote marker (C2)" || bad "impl zoom-in marker" "rc=$rc"
else
  ok "SKIP C2 marker — sibling agent-tdd/stack-zoom.sh not present"
fi
```

*(Note: this block runs before the existing `WAVE_DIR=...` line creates the status dir — move the `WAVE_DIR=` + `mkdir -p "${WAVE_DIR}/status"` lines up to just after `record-green`, so both this block and the `.done` write share them. The C2 invariant: in the real flow `issue-1.done` is written by Impl's Step 7 only AFTER Step 6.5 wrote `issue-1.stack-zoom-impl`; this gate asserts the marker is producible on a clean verify.)*

- [ ] **Step 2: Run it to verify it fails** — `bash ../atdd-cli/tests/wave-coordination.sh` (after `cargo build` in atdd-cli). Expected: the new check FAILs (marker not produced) until the recipe from Task 1 exists.

- [ ] **Step 3: (recipe already exists from Task 1)** — confirm `skills/atdd/recipes/stack-zoom.sh` is present and executable.

- [ ] **Step 4: Run the gate to verify it passes** — `bash ../atdd-cli/tests/wave-coordination.sh`. Expected: `ALLPASS` including "impl zoom-in verified + wrote marker (C2)".

- [ ] **Step 5: Commit** (in the atdd-cli repo)

```bash
( cd ../atdd-cli && git add tests/wave-coordination.sh && git commit -m "test(wave): assert the impl end-of-task zoom-in marker (agent-tdd C2 seam)" )
```

---

## Self-Review

**Spec coverage:**
- Four agents bidirectional (READ + WRITE) → READ lines + WRITE steps in Tasks 4 (Impl/Test) & 5 (Root/Notes). ✓
- Per-agent sharpest moments → Impl Step 6.5, Test Step 6.5, Root §3.5 post-integrate, Notes Touch-1/Touch-2. ✓
- Notes two-touch (proposed → verify) → Task 5 steps 4–5. ✓
- 3-layer hybrid enforcement → Layer 1 (Tasks 4/5 markdown), Layer 2 (Task 1 recipe + Task 6 gate), Layer 3 (Task 3 hook). ✓
- Thoroughness floor → STACK_USAGE.md (Task 2) + Impl Step 6.5 note. ✓
- Marker naming contract → Global Constraints + used identically in recipe call (Tasks 4/5), hook (Task 3), gate (Task 6). ✓
- No atdd-cli product change → only `tests/wave-coordination.sh` (Task 6) + `STACK_USAGE.md` sync bump (Task 2). ✓

**Placeholder scan:** `<slug>`, `<L>`, `<id>`, `<touched-layer-slug>` etc. in the role-doc blocks are agent-fill-in-at-runtime parameters (the agent supplies real values per task), not plan placeholders — they are the contract text the agent reads. All recipe/hook/test code is complete and literal.

**Type/name consistency:** marker `issue-${ISSUE}.stack-zoom-${ROLE}` matches across recipe `--marker` arg (Task 1), hook `MARKER=` (Task 3), role docs (Task 4), and gate (Task 6). Env vars `ATDD_ROLE`/`ATDD_ISSUE`/`ATDD_STATUS_DIR` are exported (Task 3 steps 6–7) exactly as the hook reads them (Task 3 step 3). Recipe flags (`--project`/`--marker`/`--layer`) match every call site.

**Known soft spots (intentional, per the spec):** Notes enforcement is markdown+recipe only (no hook, no terminal-file count) — acknowledged in the spec as acceptable because the human is in the Notes loop. The recipe guarantees "what you declared verifies clean", not "you declared enough" — thoroughness is markdown-driven by design.
