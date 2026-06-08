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

summary
