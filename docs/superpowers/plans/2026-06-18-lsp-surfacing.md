# LSP Coverage Surfacing (Phase C piece 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **STATUS — built + reviewed (2026-06-18).** Implemented on branch `v2-lsp-surfacing` in 4 commits (`9d59aa0` recipe+test, `b331a92` Root wiring, `d9c0f5c` Notes wiring, `98ae377` A′ fix). Full suite ALL PASS (142 assertions). Final whole-branch review: ready to merge. **The Task 1 recipe block and the Task 2/3 contract texts below are SUPERSEDED by the A′ amendment** (see "Post-final-review amendment — A′" at the bottom) — read the amendment for the final recipe contract (`repo` never null + `repo_registered`).

**Goal:** At bootstrap, both the Notes Agent and the Root Agent become aware of any language the working repo uses that lacks a working LSP in the `atdd` stack registry, and offer to provision it — advisory, never blocking.

**Architecture (hybrid — decision C):** One shared, deterministic recipe (`skills/lsp-surface.sh`, sibling of `ensure-atdd.sh`) is the **always-on floor** — it detects the common symbol-precise languages by file pattern, cross-checks `atdd lsp list` (a row whose `status == "ok"` means a working binary), and emits the gap as JSON. The **agent then refines on top**: it may add a symbol-precise language the recipe's fixed set missed, may skip an obvious stray-file over-detection, and does the human/LLM half (ask which server, install, `atdd lsp register`). The contracts live in `skills/atdd/SKILL.md` (Root) and `skills/atdd-plan/CORE.md` (Notes). This mirrors the repo's standing pattern — recipes carry testable deterministic logic and emit to stdout; markdown contracts carry the judgment + human-facing behavior — and keeps the floor in the no-LLM test gate (only the agent's refinement is un-tested, by design).

**Tech Stack:** Bash recipes (`set -euo pipefail`), `jq`, `git`, the local `atdd` CLI (no GitHub in the inner flow). Hermetic bash test gate driving the real `atdd` binary under a temp `ATDD_HOME` (the existing `skills/atdd-plan/recipes/tests/` harness).

## Global Constraints

- **`atdd-cli` build floor:** the recipe reads the `status` field of `atdd lsp list`, which landed in `atdd-cli` commit `377a013` ("registered == active — drop require/unrequire/check/unregister"). Build the tool at or after that commit. The dev binaries were rebuilt 2026-06-18; `make use-dev-atdd` symlinks the release build, and the test harness uses `target/debug/atdd` — run `cargo build` in `../atdd-cli` before the recipe tests. A pre-`377a013` binary emits no `status`, which degrades safely to "everything detected is missing" (over-surfaces, never under-surfaces).
- **Advisory, never blocking (locked decision):** a missing LSP must not stop Wave 0, planning, or any gate. The recipe always exits `0` on a coverage gap; non-zero exit is reserved for hard errors (bad args, no `git`, no `jq`).
- **Need is detected, not declared (locked decision):** the set of required languages comes from scanning the repo's own code, never from a policy file. The tool has no `lsp require` verb — only `register` and `list`.
- **Recipe conventions:** `set -euo pipefail`; progress + diagnostics to **stderr**; only the machine-readable return value to **stdout**; absolute paths; idempotent/resumable; **zero `gh`** in the inner flow (the test harness's poison `gh` enforces this).
- **`${CLAUDE_SKILL_DIR}`** is the canonical path root in every markdown contract — never hard-code paths.
- **Symbol-precise languages only:** shell and markdown are intentionally NOT flagged (file-granularity downgrade, `../atdd-cli/PHASE_2.md` §11). Starter detected set: `rust`, `python`, `typescript`, `javascript`, `go`.
- **`atdd lsp register` is an upsert** keyed by `(repo, lang)` — re-registering replaces the row.
- **`atdd lsp list --repo <slug>` and `atdd lsp register` require the repo to be registered to the active project** (`atdd repo register`). The recipe treats a failed list as "no coverage" (graceful), so surfacing still works for an unregistered repo.

---

## File Structure

- **Create `skills/lsp-surface.sh`** — the shared surfacing recipe. Sole responsibility: detect repo languages + cross-check the registry + emit the gap JSON. Advisory exit 0.
- **Modify `skills/atdd/SKILL.md`** — add an advisory surfacing step at the end of Bootstrap step 0 (right after `ensure-atdd.sh`).
- **Modify `skills/atdd-plan/CORE.md`** — add a surfacing step to §2 Bootstrap, after the project is pinned (so the `home_repo` slug + project scope are known).
- **Modify `skills/atdd-fix/SKILL.md`** — one pointer line in its Bootstrap so the Notes entry surfaces CORE.md's step.
- **Modify `skills/atdd-plan/recipes/tests/run.sh`** — add a hermetic `== lsp-surface ==` section (the real test cycle) and a `== bootstrap wiring ==` no-LLM gate that asserts both contracts reference the recipe.

---

### Task 1: `skills/lsp-surface.sh` recipe + hermetic recipe test

**Files:**
- Create: `skills/lsp-surface.sh`
- Test: `skills/atdd-plan/recipes/tests/run.sh` (append a new section)

**Interfaces:**
- Consumes: the `atdd` CLI on PATH (`atdd lsp list --repo <slug>`), `git`, `jq`.
- Produces: a CLI `bash skills/lsp-surface.sh [--repo <owner/repo>] [--path <dir>]` that prints one JSON object on stdout:
  `{"repo": <slug|null>, "path": <dir>, "detected": [<lang>...], "covered": [<lang>...], "missing": [<lang>...]}`
  where `missing == detected - covered` and `covered` = langs with a `status=="ok"` registry row. Always exits `0` except on hard errors (exit `2`).

- [ ] **Step 1: Write the failing test section**

Append this section to `skills/atdd-plan/recipes/tests/run.sh`, immediately before the final `summary` line:

```bash
# ────────────────────────────────────────────────────────────────────────────
echo "== lsp-surface (detection + registry cross-check, advisory) =="
SKILLS_DIR="$(cd -- "${RECIPES_DIR}/../.." && pwd)"
LSP_SURFACE="${SKILLS_DIR}/lsp-surface.sh"
setup_repo   # registers acme/home into the default project; WORK is the repo

# run lsp-surface inside the repo; capture stdout JSON into OUT, exit into RC
surface() { OUT="$( cd "$WORK" && bash "$LSP_SURFACE" "$@" 2>"${WORK}/err" )" && RC=0 || RC=$?; }

# (a) empty repo: no symbol-precise language -> nothing detected, nothing missing
surface --repo acme/home; assert_ok "surface ok on empty repo"
jchk "empty repo -> detected []" '.detected==[]' "$OUT"
jchk "empty repo -> missing  []" '.missing==[]' "$OUT"

# (b) add Cargo.toml -> rust detected; no lsp registered yet -> rust is missing
: > "${WORK}/Cargo.toml"
surface --repo acme/home; assert_ok "surface ok with Cargo.toml"
jchk "rust detected"            '.detected|index("rust")' "$OUT"
jchk "rust missing (no lsp)"    '.missing|index("rust")'  "$OUT"

# (c) register a WORKING rust lsp (status ok) -> rust no longer missing
atdd lsp register --repo acme/home --lang rust --bin /usr/bin/true >/dev/null
surface --repo acme/home; assert_ok "surface ok after registering rust"
jchk "rust covered"             '.covered|index("rust")'        "$OUT"
jchk "rust NOT missing"         '(.missing|index("rust"))|not'  "$OUT"

# (d) a BROKEN rust lsp (missing binary, upsert) -> rust missing again
atdd lsp register --repo acme/home --lang rust --bin /nonexistent/ra >/dev/null
surface --repo acme/home; assert_ok "surface ok with broken rust lsp"
jchk "broken binary -> rust missing again" '.missing|index("rust")' "$OUT"

# (e) a coverage gap is ADVISORY: the recipe still exits 0
assert_rc "missing lsp is advisory (exit 0)" 0
gh_clean
teardown_repo
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo build --manifest-path ../atdd-cli/Cargo.toml && bash skills/atdd-plan/recipes/tests/run.sh`
Expected: FAIL in the `== lsp-surface ==` section — `surface` cannot find `skills/lsp-surface.sh` (the recipe does not exist yet), so the `assert_ok`/`jchk` lines fail.

- [ ] **Step 3: Write the recipe**

Create `skills/lsp-surface.sh` with exactly:

```bash
#!/usr/bin/env bash
# lsp-surface.sh — surface any language used in this repo that lacks a working
# LSP in the atdd stack registry. ADVISORY: a coverage gap never fails (exit 0).
#
# Both the Root Agent (skills/atdd/SKILL.md) and the Notes Agent
# (skills/atdd-plan/CORE.md) run this at bootstrap, right after ensure-atdd.sh.
# It is the DETERMINISTIC half of "bootstrap LSP surfacing" (Phase C):
#   1. detect the symbol-precise languages used in the repo (manifests + files),
#   2. cross-check `atdd lsp list` (status=="ok" == a working binary),
#   3. emit the gap as JSON on stdout; a human-readable summary on stderr.
# The AGENT does the rest (ask the human, install, `atdd lsp register`).
#
# Usage:
#   lsp-surface.sh [--repo <owner/repo>] [--path <dir>]
#     --repo  atdd repo slug to scope the registry to. Default: derived from the
#             git origin (github), else the nearest .atdd/manifest.json home_repo.
#     --path  repo working tree to scan. Default: the git toplevel of cwd.
#
# stdout: {"repo":<slug|null>,"path":<dir>,"detected":[..],"covered":[..],"missing":[..]}
# exit:   0 always (advisory). Hard errors (bad args / no git / no jq) exit 2.
set -euo pipefail

log() { printf '[lsp-surface] %s\n' "$*" >&2; }
die() { printf '[lsp-surface] ERROR: %s\n' "$*" >&2; exit 2; }

command -v jq  >/dev/null 2>&1 || die "jq not found on PATH"
command -v git >/dev/null 2>&1 || die "git not found on PATH"

REPO_SLUG=""; SCAN_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO_SLUG="${2:-}"; shift 2 ;;
    --path) SCAN_DIR="${2:-}"; shift 2 ;;
    *) die "unknown arg: $1 (usage: lsp-surface.sh [--repo owner/repo] [--path dir])" ;;
  esac
done

# scan dir = explicit --path, else the git toplevel of cwd
if [[ -z "$SCAN_DIR" ]]; then
  SCAN_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die "not inside a git repo and no --path given"
fi
[[ -d "$SCAN_DIR" ]] || die "scan path does not exist: $SCAN_DIR"

# derive the repo slug if not given: git origin (github) -> manifest home_repo
origin_nwo() {
  local url; url="$(git -C "$SCAN_DIR" remote get-url origin 2>/dev/null)" || return 1
  url="${url%.git}"
  case "$url" in
    *github.com:*) printf '%s\n' "${url##*github.com:}" ;;
    *github.com/*) printf '%s\n' "${url##*github.com/}" ;;
    *) return 1 ;;
  esac
}
[[ -n "$REPO_SLUG" ]] || REPO_SLUG="$(origin_nwo || true)"
if [[ -z "$REPO_SLUG" && -f "${SCAN_DIR}/.atdd/manifest.json" ]]; then
  REPO_SLUG="$(jq -r '.home_repo // empty' "${SCAN_DIR}/.atdd/manifest.json" 2>/dev/null || true)"
fi

# detect symbol-precise languages: a manifest-file signal OR a source-extension
# signal. Shell/markdown are intentionally absent (file-granularity downgrade).
_has_file() { [[ -e "${SCAN_DIR}/$1" ]]; }
_has_ext()  { find "$SCAN_DIR" -path "${SCAN_DIR}/.git" -prune -o -type f -name "$1" -print -quit 2>/dev/null | grep -q .; }
detect_langs() {
  local found=()
  if _has_file Cargo.toml      || _has_ext '*.rs';                 then found+=(rust); fi
  if _has_file pyproject.toml  || _has_file setup.py || _has_ext '*.py'; then found+=(python); fi
  if _has_file tsconfig.json   || _has_ext '*.ts'    || _has_ext '*.tsx'; then found+=(typescript); fi
  if _has_file package.json    || _has_ext '*.js'    || _has_ext '*.jsx'; then found+=(javascript); fi
  if _has_file go.mod          || _has_ext '*.go';                 then found+=(go); fi
  printf '%s\n' "${found[@]:-}"
}
mapfile -t DETECTED < <(detect_langs | sed '/^$/d' | sort -u)

# covered langs = status=="ok" registry rows for this repo (empty if list fails)
COVERED_JSON='[]'
if [[ -n "$REPO_SLUG" ]]; then
  if LIST="$(atdd lsp list --repo "$REPO_SLUG" 2>/dev/null)"; then
    COVERED_JSON="$(jq -c '[.lsps[]? | select(.status=="ok") | .lang]' <<<"$LIST" 2>/dev/null || echo '[]')"
  else
    log "could not list lsps for ${REPO_SLUG} (repo not registered to the project yet?) — treating all detected langs as uncovered"
  fi
else
  log "repo slug unknown (no github origin, no manifest home_repo) — registry not scoped; treating all detected langs as uncovered"
fi

# missing = detected - covered; emit the report
DETECTED_JSON="$(printf '%s\n' "${DETECTED[@]:-}" | sed '/^$/d' | jq -R . | jq -sc .)"
REPORT="$(jq -nc \
  --argjson detected "$DETECTED_JSON" \
  --argjson covered  "$COVERED_JSON" \
  --arg     repo     "${REPO_SLUG:-}" \
  --arg     path     "$SCAN_DIR" '
  ($detected - $covered) as $missing
  | { repo: ($repo | if . == "" then null else . end),
      path: $path, detected: $detected, covered: $covered, missing: $missing }')"
printf '%s\n' "$REPORT"

# human summary on stderr; advisory exit 0 regardless of the gap
if [[ "$(jq -r '.missing | length' <<<"$REPORT")" -gt 0 ]]; then
  log "MISSING LSP for: $(jq -r '.missing | join(", ")' <<<"$REPORT") (repo ${REPO_SLUG:-<unknown>})"
  log "advisory only — provisioning is the agent's job: ask the human -> install -> atdd lsp register"
else
  log "all detected languages have a working LSP (or no symbol-precise language detected)"
fi
exit 0
```

- [ ] **Step 4: Make it executable**

Run: `chmod +x skills/lsp-surface.sh`

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash skills/atdd-plan/recipes/tests/run.sh`
Expected: PASS — every assertion in `== lsp-surface ==` is green (`detected []`/`missing []` on empty; `rust` detected+missing after `Cargo.toml`; `rust` covered after `/usr/bin/true`; `rust` missing again after the broken upsert; exit 0). Also confirm `bash -n` (the harness's syntax pass) covers the new recipe — it globs `${RECIPES_DIR}/*.sh`, which does NOT include `skills/lsp-surface.sh`, so add an explicit syntax check in the same section is unnecessary; instead verify by hand: `bash -n skills/lsp-surface.sh` exits 0.

- [ ] **Step 6: Commit**

```bash
git add skills/lsp-surface.sh skills/atdd-plan/recipes/tests/run.sh
git commit -m "feat(lsp): add advisory lsp-surface recipe + hermetic test"
```

---

### Task 2: Wire surfacing into the Root Agent bootstrap

**Files:**
- Modify: `skills/atdd/SKILL.md` (end of Bootstrap step 0, after the `ensure-atdd.sh` paragraph)
- Test: `skills/atdd-plan/recipes/tests/run.sh` (the no-LLM wiring gate added in Step 1)

**Interfaces:**
- Consumes: `skills/lsp-surface.sh` from Task 1 (the `--repo`/`--path` CLI and its JSON output).
- Produces: a Root bootstrap step that runs the recipe and provisions on a gap.

- [ ] **Step 1: Write the failing wiring gate**

Append this section to `skills/atdd-plan/recipes/tests/run.sh`, immediately before the final `summary` line (after Task 1's section):

```bash
# ────────────────────────────────────────────────────────────────────────────
echo "== bootstrap wiring (no-LLM coordination gate) =="
SKILLS_DIR="$(cd -- "${RECIPES_DIR}/../.." && pwd)"
grep -q 'lsp-surface.sh' "${SKILLS_DIR}/atdd/SKILL.md" \
  && pass "Root SKILL.md wires lsp-surface.sh" \
  || fail "Root SKILL.md wires lsp-surface.sh" "no reference to lsp-surface.sh"
grep -q 'lsp-surface.sh' "${SKILLS_DIR}/atdd-plan/CORE.md" \
  && pass "Notes CORE.md wires lsp-surface.sh" \
  || fail "Notes CORE.md wires lsp-surface.sh" "no reference to lsp-surface.sh"
```

- [ ] **Step 2: Run the gate to verify it fails**

Run: `bash skills/atdd-plan/recipes/tests/run.sh`
Expected: FAIL — "Root SKILL.md wires lsp-surface.sh" fails (and "Notes CORE.md…" fails too; that one is fixed in Task 3).

- [ ] **Step 3: Add the Root bootstrap step**

In `skills/atdd/SKILL.md`, find the end of Bootstrap step 0 — the paragraph that ends:

```
It installs/updates the local `atdd` binary every recipe depends on — downloading the matching build from the public agent-tdd Release if missing. Do **not** proceed until it succeeds and `atdd ping` works.
```

Insert this paragraph immediately after it (still inside step 0, before the `---` that precedes step 1):

```markdown

   **Then surface LSP coverage (advisory — never blocks).** Run `bash ${CLAUDE_SKILL_DIR}/../lsp-surface.sh` and read the JSON it prints (`detected` / `covered` / `missing`). It detects the common symbol-precise languages this repo uses and cross-checks the `atdd` stack registry; a `missing` entry is a language with no working LSP. **Treat `detected` as a floor, not the final word (hybrid):** the recipe checks a fixed set (rust, python, typescript, javascript, go) by file pattern — add any *other* symbol-precise language you can see the repo really uses (e.g. java, ruby, c/c++) to the set you act on, and quietly skip an entry that is plainly a stray tool/config file rather than real code. Then, for each language in the refined `missing` set, tell the human in one line which languages lack an LSP and offer to provision each: detect the right server, ask the human which to install, install it, and register it with `atdd lsp register --repo <owner/repo> --lang <lang> --bin <path>` (`<owner/repo>` is the `repo` field of the JSON, or the SubIssue's repo in orchestrated mode). This is **advisory**: never block Wave 0 on it — if the human declines, note it in `.atdd/<root-id>/feedback.md` once you have a state dir and proceed.
```

- [ ] **Step 4: Run the gate to verify the Root half passes**

Run: `bash skills/atdd-plan/recipes/tests/run.sh`
Expected: "Root SKILL.md wires lsp-surface.sh" → PASS. ("Notes CORE.md…" still FAILS — fixed in Task 3.)

- [ ] **Step 5: Commit**

```bash
git add skills/atdd/SKILL.md skills/atdd-plan/recipes/tests/run.sh
git commit -m "feat(lsp): wire advisory LSP surfacing into Root bootstrap"
```

---

### Task 3: Wire surfacing into the Notes Agent bootstrap

**Files:**
- Modify: `skills/atdd-plan/CORE.md` (§2 Bootstrap, after step 1 pins the project)
- Modify: `skills/atdd-fix/SKILL.md` (Bootstrap — one pointer line)
- Test: `skills/atdd-plan/recipes/tests/run.sh` (the wiring gate from Task 2 Step 1)

**Interfaces:**
- Consumes: `skills/lsp-surface.sh` from Task 1; the manifest JSON's `home_repo` (printed by `manifest-ensure.sh` in CORE.md §2 step 1).
- Produces: a Notes bootstrap step that surfaces + provisions, scoped to the resolved project's `home_repo`.

- [ ] **Step 1: Add the CORE.md surfacing step**

In `skills/atdd-plan/CORE.md` §2 "Bootstrap", find the boundary between step 1 and step 2 — step 1 ends:

```
re-asked on later runs; to switch deliberately, run `project-set.sh <other-slug>` (or set
     `ATDD_PROJECT`). Every recipe scopes its `atdd` calls to this project automatically.
```

and step 2 begins `2. **Read the NotebookIssue body**`. Insert this new step between them (renumbering is not required — the marker text below is self-describing):

```markdown
1b. **Surface LSP coverage (advisory — never blocks).** Now that the project is pinned and the
   home repo is registered, run `bash ${CLAUDE_SKILL_DIR}/../lsp-surface.sh --repo <home_repo>`
   (the `home_repo` is in the manifest JSON from step 1). Read its `missing` array: each entry is
   a symbol-precise language the repo uses with no working LSP in the stack registry. **Treat
   `detected` as a floor, not the final word (hybrid):** the recipe checks a fixed set (rust,
   python, typescript, javascript, go) by file pattern — add any *other* symbol-precise language
   you can see the repo really uses (e.g. java, ruby, c/c++), and quietly skip an entry that is
   plainly a stray tool/config file. Then, for each language in the refined `missing` set, tell
   the human in one line which languages lack an LSP and offer to provision each — detect the
   server, ask which to install, install it, then
   `atdd lsp register --repo <home_repo> --lang <lang> --bin <path>`. This is **advisory**: never
   block planning on it. For a multi-repo project, repeat per member repo you actually plan into
   (use that member's `owner/repo` as `--repo`). The provisioning detail belongs in the
   NotebookIssue, not the human dialogue.

```

- [ ] **Step 2: Add the atdd-fix pointer line**

In `skills/atdd-fix/SKILL.md` "## Bootstrap", find the line:

```
Then follow CORE.md §2 immediately:
```

Insert this line immediately before it:

```markdown
CORE.md §2 also **surfaces missing LSPs** (step 1b) once the project is pinned — handle its advisory provisioning prompt there; never block planning on a coverage gap.

```

- [ ] **Step 3: Run the gate to verify it passes**

Run: `cargo build --manifest-path ../atdd-cli/Cargo.toml && bash skills/atdd-plan/recipes/tests/run.sh`
Expected: the full suite is green — both `== lsp-surface ==` and `== bootstrap wiring ==` ("Root SKILL.md…" and "Notes CORE.md…") PASS, and the final line reads `ALL PASS`.

- [ ] **Step 4: Verify the contracts read cleanly cold**

Read the inserted steps in `skills/atdd/SKILL.md`, `skills/atdd-plan/CORE.md`, and `skills/atdd-fix/SKILL.md` as if you were the agent receiving them with no other context. Confirm each says: run the recipe → read `missing` → on a gap, surface + offer to install + `atdd lsp register` → never block. Fix wording if any step is ambiguous about the advisory (non-blocking) nature.

- [ ] **Step 5: Commit**

```bash
git add skills/atdd-plan/CORE.md skills/atdd-fix/SKILL.md
git commit -m "feat(lsp): wire advisory LSP surfacing into Notes bootstrap"
```

---

## Self-Review

**1. Spec coverage** (against `../atdd-cli/PHASE_2.md` §8 "Bootstrap lsp surfacing" + the agreed mental model):
- "run `atdd lsp list` and read each row's `status`" → Task 1 recipe (`status=="ok"` cross-check). ✓
- "a missing/not_executable binary is surfaced (advisory, not blocking)" → recipe exits 0 on a gap; `missing` includes broken rows (test (d)). ✓
- "prompts the agent to provision (detect → ask the human → install → `atdd lsp register`)" → Task 2/3 contract steps. ✓
- "both Note/RootAgent wire this" (locked answer Q1) → Task 2 (Root) + Task 3 (Notes). ✓
- "detect the languages used in the working repo; always aware of any missing lsp" (locked answer Q2) → recipe detects from the repo's own files; a never-registered language has no row, so it appears in `missing` (test (b)). ✓
- "`--repo` is just the repo you're in" (locked answer Q3) → derived from git origin / manifest, overridable; callers pass the slug they already know. ✓
- Testable without a live LLM → the hermetic `== lsp-surface ==` gate (real `atdd`, no language server) + the grep wiring gate. ✓
- Not in this plan (deliberately deferred, surfaced for review): the `stack init` skeleton recipe and the mandatory end-of-task zoom-in (the other two Phase C pieces). This plan is scoped to surfacing only, per the narrowed request.

**2. Placeholder scan:** No "TBD"/"handle edge cases"/"similar to Task N" — every step shows the exact recipe body, the exact insertion text with its anchor, and exact commands with expected output.

**3. Type/name consistency:** `lsp-surface.sh` flags `--repo`/`--path`; JSON keys `repo`/`path`/`detected`/`covered`/`missing` are identical in the recipe, the tests, and both contracts. `covered` is defined once as `status=="ok"` langs and consumed the same way everywhere. `missing == detected - covered` holds in the recipe and in every test assertion.

## Decisions

**RESOLVED — detection ownership: option C (hybrid).** The recipe is the deterministic, always-on **floor** (testable in the no-LLM gate); the **agent refines** on top (adds symbol-precise languages outside the recipe's fixed set, skips obvious stray-file over-detections) before provisioning. The recipe is unchanged by this; the refinement lives in the Root + Notes contract steps (Tasks 2–3).

**Still open (confirm or adjust):**

1. **Recipe's floor set** — `rust, python, typescript, javascript, go` (shell/markdown excluded by design). Under hybrid the exact set matters less (the agent can add others), but adding a common language to the floor makes it testable + guaranteed. Add/remove any?
2. **Root hook placement** — surfacing runs at the end of Bootstrap step 0 (right after `ensure-atdd.sh`), before `init-root`. For a free-form `/atdd` in a repo not yet registered to a project, `lsp list` fails and the recipe degrades to "all detected = missing" (it still surfaces). Acceptable, or should the Root hook move to after `init-root` (project known)?

---

## Post-final-review amendment — A′ (implemented)

The final whole-branch review found one Important issue (and a related second): the Root ran the
recipe with **no `--repo`**, so in a **local-only repo (the Root's normal case)** the slug resolved
empty → `repo: null` → the contract told the agent to `register --repo null`, and coverage came back
as a full false "everything missing". The human chose fix **A′**; it is implemented in commit
`98ae377`. Authoritative spec: `.git/sdd/fix-aprime-brief.md`.

**What A′ changed:**

- **Recipe slug resolution is never null and never asks the human.** Chain, in order:
  `--repo` → git origin (github) → `.atdd/manifest.json` `home_repo` → **atdd's own registry matched
  by this path** (`atdd repo list` → match `localPath` to the scan dir / its realpath) →
  **`local/<folder>` floor**. The old `if . == "" then null` emission is gone.
- **Recipe also emits `repo_registered`** (is the slug registered to the active atdd project?).
  Coverage (`atdd lsp list --repo`) is only queried when registered; otherwise coverage is reported
  as all-missing with a stderr note. The recipe stays **read-only + advisory (exit 0)** — it runs only
  `atdd repo list` / `atdd lsp list`; no mutations.
- **Final recipe stdout:** `{"repo":<slug, never null>,"repo_registered":<bool>,"path":<dir>,
  "detected":[..],"covered":[..],"missing":[..]}`.
- **Both contracts (Root `SKILL.md`, Notes `CORE.md`) now provision correctly:** use the JSON `repo`
  (always set; never ask the human for it), and **if `repo_registered` is `false`, run
  `atdd repo register <repo> <abs-path>` first**, then `atdd lsp register …`. The hybrid "floor"
  refine instruction is unchanged.
- **Tests:** the `== lsp-surface ==` gate gained (f) manifest-derived slug, (g) registry path-match
  after manifest removal, (h) `local/<folder>` fallback + `repo_registered:false` on an unregistered
  dir. Suite ALL PASS (142 assertions).

**This also resolves the plan's two previously-open decisions:**

1. **Root hook placement (was open):** A′ makes the slug never-null wherever the hook sits, so the
   hook **stays at Bootstrap step 0** (option B — moving it after `init-root` — is no longer needed).
2. **Recipe floor set:** unchanged (`rust, python, typescript, javascript, go`); the agent refines on
   top per hybrid (decision C).

**Known non-blocking notes (from the re-review, for any future follow-up):**

- The `(g)` test assumes `git rev-parse --show-toplevel` and `atdd repo list`'s stored `localPath`
  agree as strings; on a platform where `/tmp` is a symlink (e.g. macOS) only the recipe's
  `pwd -P` (`CANON_DIR`) match-arm saves it. The recipe is robust (dual-path match); the test is the
  system-specific part.
- `_has_ext` prunes only a top-level `.git` and does not skip `node_modules`/`vendor`/`target` →
  can over-detect, but it is advisory noise by design.
