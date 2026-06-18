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
jchk "ERP Root visible under erp" 'map(.title)|index("ERP Root")' "$(atdd --project erp issue list --repo acme/home --label atdd:root)"
jchk "ERP Root INVISIBLE under default" '(map(.title)|index("ERP Root"))|not' "$(atdd --project default issue list --repo acme/home --label atdd:root)"
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
echo "== bootstrap wiring (no-LLM coordination gate) =="
SKILLS_DIR="$(cd -- "${RECIPES_DIR}/../.." && pwd)"
grep -q 'lsp-surface.sh' "${SKILLS_DIR}/atdd/SKILL.md" \
  && pass "Root SKILL.md wires lsp-surface.sh" \
  || fail "Root SKILL.md wires lsp-surface.sh" "no reference to lsp-surface.sh"
grep -q 'lsp-surface.sh' "${SKILLS_DIR}/atdd-plan/CORE.md" \
  && pass "Notes CORE.md wires lsp-surface.sh" \
  || fail "Notes CORE.md wires lsp-surface.sh" "no reference to lsp-surface.sh"

summary
