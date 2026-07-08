#!/usr/bin/env bash
# run.sh — run all atdd-plan recipe tests (Phase 1: atdd-backed). Usage: bash tests/run.sh
set -uo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# ────────────────────────────────────────────────────────────────────────────
echo "== bash -n (syntax) over every recipe =="
for f in "${RECIPES_DIR}"/*.sh; do
  if bash -n "$f" 2>/dev/null; then pass "syntax $(basename "$f")"
  else fail "syntax $(basename "$f")"; fi
done

# ────────────────────────────────────────────────────────────────────────────
echo "== root-create / sub-create / topology / depend =="
setup_repo
STDIN_DATA='Root A body' run root-create.sh 'Root A' -; assert_ok "root-create A"; ROOT_A="$OUT"
jchk "A is an OPEN RootIssue" '.state=="OPEN" and (.labels|index("atdd:root"))' "$(atdd issue view "$ROOT_A")"
STDIN_DATA='Root B body' run root-create.sh 'Root B' -; assert_ok "root-create B"; ROOT_B="$OUT"
STDIN_DATA='Sub body' run sub-create.sh acme/otc "$ROOT_A" 'Sub 1' -; assert_ok "sub-create under A"; SUB="$OUT"
jchk "sub linked to A" '.parentRef=="'"$ROOT_A"'"' "$(atdd issue view "$SUB")"
jchk "sub carries atdd:sub" '.labels|index("atdd:sub")' "$(atdd issue view "$SUB")"
run sub-create.sh acme/otc "$SUB" 'Bad parent' -; assert_fail "sub-create rejects non-root parent"
ANUM="${ROOT_A##*#}"; BNUM="${ROOT_B##*#}"
run root-depend.sh "$BNUM" "$ANUM"; assert_ok "root-depend: B blocked by A"
run _graph.sh; jchk "graph: A.transitive_blocking_count==1" \
  '.issues[]|select(.ref=="'"$ROOT_A"'")|.transitive_blocking_count==1' "$OUT"
run topology-available.sh; assert_ok "available ok"
jchk "available has A, not blocked B" \
  '(map(.ref)|index("'"$ROOT_A"'")) and ((map(.ref)|index("'"$ROOT_B"'"))|not)' "$OUT"
run topology-next-urgent.sh; jchk "next-urgent -> A" 'length==1 and .[0].ref=="'"$ROOT_A"'"' "$OUT"
run topology-blocking.sh "$ANUM"; jchk "A blocking -> B" 'map(.ref)|index("'"$ROOT_B"'")' "$OUT"
run topology-blocked-by.sh "$BNUM"; jchk "B blocked-by -> A" 'map(.ref)|index("'"$ROOT_A"'")' "$OUT"
run root-depend.sh "$ANUM" "$BNUM"; assert_fail "cycle rejected"
run root-depend.sh "$ANUM" "$ANUM"; assert_fail "self-loop rejected"
run root-undepend.sh "$BNUM" "$ANUM"; assert_ok "undepend"
run root-undepend.sh "$BNUM" "$ANUM"; assert_ok "undepend idempotent noop"
gh_clean
teardown_repo

# ────────────────────────────────────────────────────────────────────────────
echo "== sub-adopt (guards + idempotency) =="
setup_repo
STDIN_DATA='RA' run root-create.sh 'RA' -; ROOT="$OUT"
atdd issue create --repo acme/otc --title 'Loose' --porcelain >/dev/null   # acme/otc#1 (unlabelled)
run sub-adopt.sh 'not-a-repo' 1 "$ROOT";   assert_fail "rejects bad target-repo"
run sub-adopt.sh acme/otc x "$ROOT";       assert_fail "rejects non-numeric issue#"
run sub-adopt.sh acme/otc 1 'badref';      assert_fail "rejects bad root-ref"
run sub-adopt.sh acme/otc 1 "$ROOT";       assert_ok "adopt happy path"; assert_out "prints child ref" "acme/otc#1"
jchk "child labelled atdd:sub" '.labels|index("atdd:sub")' "$(atdd issue view acme/otc#1)"
jchk "child linked to root" '.parentRef=="'"$ROOT"'"' "$(atdd issue view acme/otc#1)"
run sub-adopt.sh acme/otc 1 "$ROOT";       assert_ok "adopt idempotent re-run"
NONROOT="$(atdd issue create --repo acme/home --title NR --porcelain)"
run sub-adopt.sh acme/otc 1 "$NONROOT";    assert_fail "rejects parent without atdd:root"
run sub-adopt.sh acme/home "${ROOT##*#}" "$ROOT"; assert_fail "refuses to adopt a RootIssue as a sub"
gh_clean
teardown_repo

# ────────────────────────────────────────────────────────────────────────────
echo "== issue-edit / issue-close / sub-unlink =="
setup_repo
STDIN_DATA='RA' run root-create.sh 'RA' -; ROOT="$OUT"
STDIN_DATA='SB' run sub-create.sh acme/otc "$ROOT" 'SB' -; SUB="$OUT"
run issue-edit.sh "$ROOT" --title 'New Title'; assert_ok "edit title"
jchk "title updated" '.title=="New Title"' "$(atdd issue view "$ROOT")"
run issue-edit.sh "$ROOT"; assert_fail "edit needs --title/--body-file"
run issue-edit.sh acme/home#999 --title X; assert_fail "edit missing issue"
LOOSE="$(atdd issue create --repo acme/home --title L --porcelain)"
run issue-edit.sh "$LOOSE" --title X; assert_fail "refuse unmanaged issue"
STDIN_DATA='new body text' run issue-edit.sh "$SUB" --body-file -; assert_ok "edit body via stdin"
jchk "body updated" '.body=="new body text"' "$(atdd issue view "$SUB")"
run issue-close.sh "$SUB"; assert_ok "close sub (completed)"
jchk "sub closed completed" '.state=="CLOSED" and .closeReason=="completed"' "$(atdd issue view "$SUB")"
run issue-close.sh "$SUB" --reopen; assert_ok "reopen"
jchk "sub reopened" '.state=="OPEN"' "$(atdd issue view "$SUB")"
run issue-close.sh "$SUB" --reason not_planned; assert_ok "close not_planned"
jchk "reason not_planned" '.closeReason=="not_planned"' "$(atdd issue view "$SUB")"
run issue-close.sh "$SUB" --reason bogus; assert_fail "bad reason rejected"
run issue-close.sh "$SUB" --reopen >/dev/null
run sub-unlink.sh "$SUB" "$ROOT"; assert_ok "unlink"
jchk "parent cleared" '.parentRef==null' "$(atdd issue view "$SUB")"
run sub-unlink.sh "$SUB" "$ROOT"; assert_ok "unlink idempotent noop"
gh_clean
teardown_repo

# ────────────────────────────────────────────────────────────────────────────
echo "== ready-mark / ready-unmark =="
setup_repo
STDIN_DATA='RA' run root-create.sh 'RA' -; ROOT="$OUT"
STDIN_DATA='SB' run sub-create.sh acme/otc "$ROOT" 'SB' -; SUB="$OUT"
run ready-mark.sh "$SUB"; assert_ok "ready-mark"
jchk "marked ready" '.labels|index("atdd:ready")' "$(atdd issue view "$SUB")"
run ready-mark.sh "$SUB"; assert_ok "ready-mark idempotent"
run ready-mark.sh "$ROOT"; assert_fail "refuse to mark a non-SubIssue ready"
run ready-unmark.sh "$SUB"; assert_ok "ready-unmark"
jchk "unmarked" '(.labels|index("atdd:ready"))|not' "$(atdd issue view "$SUB")"
run ready-unmark.sh "$SUB"; assert_ok "ready-unmark idempotent"
gh_clean
teardown_repo

# ────────────────────────────────────────────────────────────────────────────
echo "== notebook head-set/get + index-update =="
setup_repo
STDIN_DATA='RA' run root-create.sh 'RA' -; ROOT="$OUT"
STDIN_DATA=$'Notes line 1\nNotes line 2' run notebook-head-set.sh "$ROOT" -; assert_ok "head-set"
run notebook-head-get.sh "$ROOT"; assert_ok "head-get ok"
assert_out "head-get round-trips body" $'Notes line 1\nNotes line 2'
run notebook-head-get.sh acme/home#999; assert_ok "head-get missing ok"; assert_out "missing -> empty" ""
run notebook-index-update.sh; assert_ok "index-update"
gh_clean
teardown_repo

# ────────────────────────────────────────────────────────────────────────────
echo "== manifest member registry (--resolve-member / --register-member) =="
setup_repo
CLONE="${WORK}/clone-otc"; git init -q "$CLONE"; git -C "$CLONE" remote add origin 'git@github.com:acme/otc.git'
run manifest-ensure.sh --resolve-member acme/otc; assert_rc "resolve unregistered -> exit3" 3
run manifest-ensure.sh --register-member acme/otc "$CLONE"; assert_ok "register happy path"; assert_out "prints path" "$CLONE"
run manifest-ensure.sh --resolve-member acme/otc; assert_ok "resolve after register"; assert_out "prints recorded path" "$CLONE"
run manifest-ensure.sh --register-member acme/core "$CLONE"; assert_fail "refuse origin/repo mismatch"
git -C "$CLONE" remote set-url origin 'git@github.com:acme/different.git'
run manifest-ensure.sh --resolve-member acme/otc; assert_rc "stale clone -> exit3" 3
gh_clean
teardown_repo

# ────────────────────────────────────────────────────────────────────────────
echo "== project resolution (ask only when ambiguous) + isolation =="
setup_repo   # bootstraps acme/home into the "default" project (0-projects path)
jchk "bootstrap pinned project_slug=default" '.project_slug=="default"' "$(cat "${WORK}/.atdd/manifest.json")"
jchk "bootstrap created the per-project NotebookIssue" '.notebook_issue.number>0' "$(cat "${WORK}/.atdd/manifest.json")"
jchk "repo where home -> default" '.projects|index("default")' "$(atdd repo where acme/home)"
run project-resolve.sh; assert_ok "resolve: pinned -> exit 0"; assert_out "resolve prints default" "default"

# Put the home repo into a SECOND project, then UNPIN -> resolution is ambiguous.
atdd project create erp >/dev/null
atdd --project erp repo register acme/home "$WORK" --home >/dev/null
jchk "repo where home -> default AND erp" '(.projects|index("default")) and (.projects|index("erp"))' "$(atdd repo where acme/home)"
run project-resolve.sh; assert_ok "resolve: still pinned default (pin wins over ambiguity)"; assert_out "still default" "default"
( cd "$WORK" && jq 'del(.project_slug)' .atdd/manifest.json > .atdd/m.tmp && mv .atdd/m.tmp .atdd/manifest.json )
run project-resolve.sh; assert_rc "resolve: unpinned + 2 projects -> ambiguous (exit 11)" 11
grep -q '^default$' <<<"$OUT" && grep -q '^erp$' <<<"$OUT" && pass "ambiguous lists both candidates" || fail "ambiguous candidates" "OUT=$OUT"

# project-set switches the active project (+ re-resolves the per-project notebook).
run project-set.sh erp; assert_ok "project-set erp"
jchk "manifest now pinned to erp" '.project_slug=="erp"' "$(cat "${WORK}/.atdd/manifest.json")"
run project-resolve.sh; assert_ok "resolve: pinned erp -> exit 0"; assert_out "resolves erp" "erp"

# Isolation: a RootIssue created now is scoped to erp (manifest pin) and invisible in default.
STDIN_DATA='ERP root body' run root-create.sh 'ERP Root' -; assert_ok "root-create scoped to erp"; ERP_ROOT="$OUT"
jchk "ERP Root visible under erp" '.issues|map(.title)|index("ERP Root")' "$(atdd --project erp issue list --repo acme/home --label atdd:root)"
jchk "ERP Root INVISIBLE under default" '(.issues|map(.title)|index("ERP Root"))|not' "$(atdd --project default issue list --repo acme/home --label atdd:root)"
gh_clean
teardown_repo

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

# (f) slug auto-derived (no --repo): manifest home_repo, repo registered
surface; assert_ok "surface ok with no --repo (derives slug)"
jchk "repo derived == acme/home"        '.repo=="acme/home"'      "$OUT"
jchk "repo_registered true"             '.repo_registered==true'  "$OUT"

# (g) reverse-lookup: no manifest + no origin -> slug from atdd registry by path
rm -f "${WORK}/.atdd/manifest.json"
surface; assert_ok "surface ok with no manifest (registry path-match)"
jchk "repo from registry == acme/home"  '.repo=="acme/home"'      "$OUT"
jchk "repo_registered true (g)"         '.repo_registered==true'  "$OUT"

# (h) folder-name fallback: a fresh, unregistered dir -> repo=local/<folder>, never null
FRESH="${WORK}/freshsub"; mkdir -p "$FRESH"; : > "${FRESH}/go.mod"
surface --path "$FRESH"; assert_ok "surface ok on unregistered dir (folder fallback)"
jchk "repo == local/freshsub (never null)" '.repo=="local/freshsub"' "$OUT"
jchk "repo_registered false"               '.repo_registered==false' "$OUT"
jchk "go detected"                          '.detected|index("go")'  "$OUT"
jchk "go missing (unregistered)"            '.missing|index("go")'   "$OUT"
gh_clean
teardown_repo

# ────────────────────────────────────────────────────────────────────────────
echo "== stack-preflight (MANDATORY LSP gate #32/#33) =="
SKILLS_DIR="$(cd -- "${RECIPES_DIR}/../.." && pwd)"
PREFLIGHT="${SKILLS_DIR}/stack-preflight.sh"
setup_repo
preflight() { OUT="$( cd "$WORK" && bash "$PREFLIGHT" "$@" 2>"${WORK}/err" )" && RC=0 || RC=$?; }

# (a) no symbol-precise language -> gate PASSES (exit 0), nothing missing
preflight --repo acme/home; assert_rc "empty repo: gate passes (exit 0)" 0
jchk "empty repo -> missing []" '.missing==[]' "$OUT"

# (b) Cargo.toml + no lsp -> gate BLOCKS (exit 3); rust still named missing in the JSON
: > "${WORK}/Cargo.toml"
preflight --repo acme/home
[ "${RC}" -eq 3 ] && pass "rust + no lsp -> gate BLOCKS (exit 3)" || fail "rust + no lsp -> gate BLOCKS (exit 3)" "rc=${RC}"
jchk "blocked report still names rust missing" '.missing|index("rust")' "$OUT"
grep -q 'BLOCKED' "${WORK}/err" && pass "block message printed to stderr" || fail "block message to stderr" "no BLOCKED line"

# (c) register a WORKING rust lsp -> gate PASSES again (exit 0)
atdd lsp register --repo acme/home --lang rust --bin /usr/bin/true >/dev/null
preflight --repo acme/home; assert_rc "rust covered -> gate passes (exit 0)" 0
teardown_repo

# ----------------------------------------------------------------------------
echo "== bootstrap wiring (no-LLM coordination gate) =="
SKILLS_DIR="$(cd -- "${RECIPES_DIR}/../.." && pwd)"
grep -q 'stack-preflight.sh' "${SKILLS_DIR}/atdd/SKILL.md" \
  && pass "Root SKILL.md wires the mandatory LSP gate (stack-preflight.sh)" \
  || fail "Root SKILL.md wires stack-preflight.sh" "no reference"
grep -q 'stack-preflight.sh' "${SKILLS_DIR}/atdd-plan/CORE.md" \
  && pass "Notes CORE.md wires the mandatory LSP gate (stack-preflight.sh)" \
  || fail "Notes CORE.md wires stack-preflight.sh" "no reference"
# the single-source Stack guide is referenced by every agent that touches the model
for f in atdd/SKILL.md atdd-plan/CORE.md atdd/roles/IMPL_AGENT_ROLE.md atdd/roles/TEST_AGENT_ROLE.md; do
  grep -q 'STACK_USAGE.md' "${SKILLS_DIR}/${f}" \
    && pass "${f} references the Stack guide" \
    || fail "${f} references STACK_USAGE.md" "no reference"
done
[ -f "${SKILLS_DIR}/STACK_USAGE.md" ] && pass "STACK_USAGE.md (canonical guide) exists" \
  || fail "STACK_USAGE.md exists" "missing"
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
grep -q 'stack-zoom.sh' "${SKILLS_DIR}/atdd/PROTOCOL.md" \
  && pass "Root PROTOCOL wires the post-integrate zoom-in" || fail "Root PROTOCOL wires stack-zoom.sh" "no reference"
grep -q 'stack-zoom.sh' "${SKILLS_DIR}/atdd-plan/CORE.md" \
  && pass "Notes CORE wires Touch-1 (declare proposed shape)" || fail "Notes CORE wires stack-zoom.sh" "no reference"
grep -q 'stack-zoom.sh' "${SKILLS_DIR}/atdd-plan/ORCHESTRATE.md" \
  && pass "Notes ORCHESTRATE wires Touch-2 (verify before close)" || fail "Notes ORCHESTRATE wires stack-zoom.sh" "no reference"

# ────────────────────────────────────────────────────────────────────────────
echo "== STACK_USAGE.md sync marker (plugin <-> atdd-cli must not drift) =="
# The plugin guide and the atdd-cli alpha brief are NOT byte-identical by design;
# a shared `<!-- STACK-USAGE-SYNC: vN -->` marker (not a diff) is the drift gate.
# Bump it in BOTH when either's substance changes. SKIPs if the sibling atdd-cli
# repo is not checked out next to agent-tdd.
PLUGIN_DOC="${SKILLS_DIR}/STACK_USAGE.md"
CLI_DOC="$(cd -- "${RECIPES_DIR}/../../../.." && pwd)/atdd-cli/STACK_USAGE.md"
mk() { grep -oE 'STACK-USAGE-SYNC:[[:space:]]*v[0-9]+(\.[0-9]+)*' "$1" 2>/dev/null | head -1 | grep -oE 'v[0-9]+(\.[0-9]+)*'; }
if [[ ! -f "$CLI_DOC" ]]; then
  pass "SKIP sync marker — sibling atdd-cli not checked out ($CLI_DOC)"
else
  PV="$(mk "$PLUGIN_DOC")"; CV="$(mk "$CLI_DOC")"
  [[ -n "$PV" ]] && pass "plugin guide carries a sync marker ($PV)"  || fail "plugin guide carries a sync marker" "add <!-- STACK-USAGE-SYNC: v1 -->"
  [[ -n "$CV" ]] && pass "atdd-cli brief carries a sync marker ($CV)" || fail "atdd-cli brief carries a sync marker" "add <!-- STACK-USAGE-SYNC: v1 -->"
  if [[ -n "$PV" && -n "$CV" ]]; then
    [[ "$PV" == "$CV" ]] && pass "markers match ($PV) — declared in sync" || fail "markers match" "plugin=$PV vs atdd-cli=$CV — bump BOTH"
  fi
fi

# ────────────────────────────────────────────────────────────────────────────
echo "== stack-zoom (recipe: verify touched scope, write marker on clean) =="
setup_repo                      # temp git repo + isolated ATDD_HOME + atdd on PATH
SZ="$(cd -- "${RECIPES_DIR}/../.." && pwd)/atdd/recipes/stack-zoom.sh"
PROJ=zoomproj
atdd project create "$PROJ" --title 'zoom' >/dev/null
atdd --project "$PROJ" repo register acme/z "$WORK" >/dev/null
# a real file to anchor a clean layer at:
mkdir -p "${WORK}/src"; echo 'fn main(){}' > "${WORK}/src/lib.rs"; git -C "$WORK" add -A; git -C "$WORK" commit -qm src
atdd --project "$PROJ" layer add z/core --repo acme/z --name Core --at 'acme/z:src/lib.rs' --by llm --confidence verified >/dev/null
MK="${WORK}/issue-1.stack-zoom-impl"

# clean verify -> exit 0 + marker
( bash "$SZ" --project "$PROJ" --layer z/core --marker "$MK" >/dev/null 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && pass "stack-zoom exits 0 on a clean verify" || fail "stack-zoom clean exit" "rc=$rc"
[[ -f "$MK" ]] && pass "stack-zoom wrote the completion marker" || fail "marker written"

# drift -> exit 3 + NO marker
rm -f "$MK"
atdd --project "$PROJ" layer edit z/core --at 'acme/z:src/GONE.rs' >/dev/null
( bash "$SZ" --project "$PROJ" --layer z/core --marker "$MK" >/dev/null 2>&1 ); rc=$?
[[ $rc -eq 3 ]] && pass "stack-zoom exits 3 (BLOCKED) on drift" || fail "stack-zoom drift exit" "rc=$rc"
[[ ! -f "$MK" ]] && pass "stack-zoom withholds the marker on drift" || fail "marker withheld on drift"

# bad args -> exit 2
( unset ATDD_PROJECT; bash "$SZ" --marker "$MK" >/dev/null 2>&1 ); rc=$?     # missing --project (and no $ATDD_PROJECT)
[[ $rc -eq 2 ]] && pass "stack-zoom exits 2 on missing --project" || fail "stack-zoom bad-args exit" "rc=$rc"
teardown_repo

# ────────────────────────────────────────────────────────────────────────────
echo "== stack-zoom --worktree passthrough (forward to stack verify; doc §6b) =="
# Contract (issue #5): stack-zoom.sh gains --worktree <path> and forwards it to
# `atdd stack verify` — but ONLY when non-empty; without it, behavior is unchanged.
# We spy on `atdd` (a PATH shim that records its argv, then exits 0 = clean verify)
# so this is hermetic and does NOT depend on the real `atdd` yet accepting
# --worktree (that lands on the atdd-cli side). We assert on the argv the recipe
# forwards, not on the tool's behavior.
SZW="$(cd -- "${RECIPES_DIR}/../.." && pwd)/atdd/recipes/stack-zoom.sh"
bash -n "$SZW" && pass "syntax stack-zoom.sh" || fail "syntax stack-zoom.sh"
WT="$(mktemp -d)"; SPY="${WT}/bin"; mkdir -p "$SPY"; ALOG="${WT}/atdd-argv.log"
cat > "${SPY}/atdd" <<SPY
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${ALOG}"   # record full argv for the assertions below
exit 0                              # stack verify -> clean, so the recipe writes its marker
SPY
chmod +x "${SPY}/atdd"
WT_SAVED_PATH="$PATH"; export PATH="${SPY}:${PATH}"

# (a) --worktree present -> forwarded verbatim to `atdd ... stack verify`
: > "$ALOG"; MKW="${WT}/issue-5.stack-zoom-impl"
( bash "$SZW" --project wp --layer z/core --worktree /wt/xyz --marker "$MKW" >/dev/null 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && pass "stack-zoom exits 0 with --worktree (clean spy verify)" || fail "worktree clean exit" "rc=$rc"
{ grep -q 'stack verify' "$ALOG" && grep -q -- '--worktree /wt/xyz' "$ALOG"; } \
  && pass "stack-zoom forwards --worktree to stack verify" \
  || fail "stack-zoom forwards --worktree" "argv: $(cat "$ALOG" 2>/dev/null)"
[[ -f "$MKW" ]] && pass "stack-zoom writes the marker on clean verify (with --worktree)" || fail "marker written (worktree)"

# (b) --worktree ABSENT -> the recipe never passes --worktree (behavior unchanged)
: > "$ALOG"; MKN="${WT}/issue-5.nowt"
( bash "$SZW" --project wp --layer z/core --marker "$MKN" >/dev/null 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && pass "stack-zoom exits 0 without --worktree (unchanged)" || fail "no-worktree exit" "rc=$rc"
grep -q -- '--worktree' "$ALOG" \
  && fail "must NOT pass --worktree when absent" "argv: $(cat "$ALOG" 2>/dev/null)" \
  || pass "stack-zoom omits --worktree when not given (behavior unchanged)"

# (c) --worktree "" (empty) -> accepted, treated as absent, never forwarded as --worktree ""
: > "$ALOG"; MKE="${WT}/issue-5.emptywt"
( bash "$SZW" --project wp --layer z/core --worktree "" --marker "$MKE" >/dev/null 2>&1 ); rc=$?
[[ $rc -eq 0 ]] && pass "stack-zoom accepts an empty --worktree (exits 0)" || fail "empty-worktree exit" "rc=$rc"
grep -q -- '--worktree' "$ALOG" \
  && fail "must NOT forward an empty --worktree" "argv: $(cat "$ALOG" 2>/dev/null)" \
  || pass "stack-zoom omits --worktree when empty (no --worktree \"\")"

export PATH="$WT_SAVED_PATH"; rm -rf "$WT"

# doc §6b: the Impl guidance + the recipe example must document --worktree
SKILLS_DIR="$(cd -- "${RECIPES_DIR}/../.." && pwd)"
SUW="${SKILLS_DIR}/STACK_USAGE.md"
grep -q -- '--worktree' "$SUW" \
  && pass "STACK_USAGE.md §6b documents --worktree" \
  || fail "STACK_USAGE.md documents --worktree" "no --worktree in the guide"
grep -A2 'recipes/stack-zoom.sh' "$SUW" | grep -q -- '--worktree' \
  && pass "STACK_USAGE.md recipe example includes --worktree" \
  || fail "STACK_USAGE.md recipe example includes --worktree" "the stack-zoom.sh invocation example has no --worktree"

# ────────────────────────────────────────────────────────────────────────────
echo "== drop-feedback (recipe: writes a stamped alpha-feedback note; never aborts) =="
# No atdd/daemon needed — drop-feedback only writes a file. The automated bash -n loop
# (top of this file) globs only atdd-plan/recipes, so syntax-check this one explicitly.
DF="$(cd -- "${RECIPES_DIR}/../.." && pwd)/atdd/recipes/drop-feedback.sh"
bash -n "$DF" && pass "syntax drop-feedback.sh" || fail "syntax drop-feedback.sh"

# (a) happy path: ATDD_FEEDBACK_DIR override -> temp dir, rich body via stdin
FBD="$(mktemp -d)"
DFOUT="$(printf 'cmd: atdd stack verify\noutput: confusing\nexpected: clear msg\n' \
  | ATDD_FEEDBACK_DIR="$FBD" ATDD_ROLE=impl ATDD_PROJECT='acme/x' bash "$DF" --summary 'verify error unclear' 2>/dev/null)"; rc=$?
[[ $rc -eq 0 ]] && pass "drop-feedback exits 0 on a normal drop" || fail "drop-feedback exit" "rc=$rc"
DFFILE="$(ls "$FBD"/*.md 2>/dev/null | head -1)"
[[ -n "$DFFILE" ]] && pass "drop-feedback created a .md note" || fail "no note created"
case "$(basename "${DFFILE:-}")" in
  acme-x__impl__*Z__*.md) pass "note filename: slug(/→-) + role + UTC + rand" ;;
  *) fail "note filename pattern" "${DFFILE:-<none>}" ;;
esac
grep -q 'verify error unclear'  "${DFFILE:-/dev/null}" && pass "summary stamped"          || fail "summary missing"
grep -q 'cmd: atdd stack verify' "${DFFILE:-/dev/null}" && pass "stdin body stamped"        || fail "body missing"
grep -q 'acme-x'                "${DFFILE:-/dev/null}" && pass "project slug stamped"       || fail "slug missing"
[[ "$DFOUT" == "$DFFILE" ]] && pass "prints the note path to stdout" || fail "stdout != path" "out=$DFOUT file=$DFFILE"
rm -rf "$FBD"

# (b) bad args: missing --summary -> exit 2
( ATDD_FEEDBACK_DIR="$(mktemp -d)" bash "$DF" --role test </dev/null ) >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && pass "drop-feedback exits 2 on missing --summary" || fail "drop-feedback bad-args exit" "rc=$rc"

# (c) never-abort: an uncreatable feedback dir -> graceful no-op (exit 0, no crash, no junk)
( ATDD_FEEDBACK_DIR="/nonexistent-root-$$/x" bash "$DF" --summary 'should no-op' </dev/null ) >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && pass "drop-feedback no-ops (exit 0) when the dir can't be created" || fail "no-op exit" "rc=$rc"

# (d) all four agent contracts + the shared guide wire drop-feedback.sh (mirrors the stack-zoom greps)
grep -q 'drop-feedback.sh' "${SKILLS_DIR}/atdd/roles/TEST_AGENT_ROLE.md" && pass "TEST role wires drop-feedback"  || fail "TEST drop-feedback pointer"
grep -q 'drop-feedback.sh' "${SKILLS_DIR}/atdd/roles/IMPL_AGENT_ROLE.md" && pass "IMPL role wires drop-feedback"  || fail "IMPL drop-feedback pointer"
grep -q 'drop-feedback.sh' "${SKILLS_DIR}/atdd/SKILL.md"                 && pass "Root SKILL wires drop-feedback"  || fail "Root drop-feedback pointer"
grep -q 'drop-feedback.sh' "${SKILLS_DIR}/atdd-plan/CORE.md"             && pass "Notes CORE wires drop-feedback"  || fail "Notes drop-feedback pointer"
grep -q 'drop-feedback.sh' "${SKILLS_DIR}/STACK_USAGE.md"                && pass "STACK_USAGE documents drop-feedback" || fail "STACK_USAGE drop-feedback box"

# ────────────────────────────────────────────────────────────────────────────
echo "== stack-zoom hook (Stop-hook backstop for test/impl) =="
HK="$(cd -- "${RECIPES_DIR}/../../.." && pwd)/hooks/stack-zoom-stop.sh"   # plugin root = skills/..
HKDIR="$(mktemp -d)"; SD="${HKDIR}/status"; mkdir -p "$SD"

# (a) not an agent context -> no-op (exit 0, no output)
out="$(printf '{"stop_hook_active":false}' | bash "$HK")"; rc=$?
{ [[ $rc -eq 0 && -z "$out" ]]; } && pass "hook no-ops outside an agent context" || fail "hook no-op" "rc=$rc out=$out"

# (b) impl context, marker ABSENT -> block JSON
out="$(printf '{"stop_hook_active":false}' | ATDD_ROLE=impl ATDD_ISSUE=7 ATDD_STATUS_DIR="$SD" bash "$HK")"; rc=$?
{ [[ $rc -eq 0 ]] && jq -e '.hookSpecificOutput.decision=="block"' >/dev/null <<<"$out"; } \
  && pass "hook blocks impl with no marker" || fail "hook block" "rc=$rc out=$out"

# (c) impl context, marker PRESENT -> allow (exit 0, no output)
: > "${SD}/issue-7.stack-zoom-impl"
out="$(printf '{"stop_hook_active":false}' | ATDD_ROLE=impl ATDD_ISSUE=7 ATDD_STATUS_DIR="$SD" bash "$HK")"; rc=$?
{ [[ $rc -eq 0 && -z "$out" ]]; } && pass "hook allows impl once marker exists" || fail "hook allow" "rc=$rc out=$out"

# (d) loop guard: stop_hook_active=true -> allow even with no marker
out="$(printf '{"stop_hook_active":true}' | ATDD_ROLE=impl ATDD_ISSUE=9 ATDD_STATUS_DIR="$SD" bash "$HK")"; rc=$?
{ [[ $rc -eq 0 && -z "$out" ]]; } && pass "hook honors stop_hook_active (never locks out)" || fail "hook loop-guard" "rc=$rc out=$out"
rm -rf "$HKDIR"

# ────────────────────────────────────────────────────────────────────────────
echo "== ref-qualification (issue #9: atdd calls use \${REF}, never bare \${ISSUE_NUM}) =="
# Static grep gate over the role markdowns + spawn recipes. Self-contained
# (needs no atdd binary/daemon), so it is delegated to its own script here and
# recorded as issue #9's test-command. The top-of-file bash -n loop globs only
# atdd-plan/recipes/*.sh (not this tests/ dir), so syntax-check it explicitly.
REFQ="${THIS_DIR}/ref-qualification.sh"
bash -n "$REFQ" && pass "syntax ref-qualification.sh" || fail "syntax ref-qualification.sh"
if REFQ_OUT="$(bash "$REFQ" 2>&1)"; then
  pass "ref-qualification gate is green (all atdd calls qualified)"
else
  fail "ref-qualification gate failed" "$(printf '%s\n' "$REFQ_OUT" | sed 's/^/         /')"
fi

summary
