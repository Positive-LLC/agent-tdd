#!/usr/bin/env bash
# run.sh — run all recipe tests. Usage: bash tests/run.sh
set -uo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# ────────────────────────────────────────────────────────────────────────────
echo "== bash -n (syntax) over every recipe =="
for f in "${RECIPES_DIR}"/*.sh; do
  if bash -n "$f" 2>/dev/null; then pass "syntax $(basename "$f")"
  else fail "syntax $(basename "$f")"; fi
done

# ────────────────────────────────────────────────────────────────────────────
echo "== sub-adopt.sh =="
setup_repo
run sub-adopt.sh 'not-a-repo' 42 'acme/home#10';   assert_fail "rejects bad target-repo"
reset_mock
run sub-adopt.sh 'acme/otc' 'x' 'acme/home#10';     assert_fail "rejects non-numeric issue#"
reset_mock
run sub-adopt.sh 'acme/otc' 42 'acme/home';         assert_fail "rejects bad root-ref"
reset_mock
# happy path: parent is a root, child is a plain loose issue
fixture GET repos/acme/home/issues/10 <<<'{"id":10,"labels":[{"name":"atdd:root"}]}'
fixture GET repos/acme/otc/issues/42  <<<'{"id":42042,"labels":[]}'
run sub-adopt.sh 'acme/otc' 42 'acme/home#10'
assert_ok        "happy path exits 0"
assert_out       "prints child ref" "acme/otc#42"
assert_called    "labels child atdd:sub"      "issue edit 42 -R acme/otc --add-label atdd:sub"
assert_called    "POSTs native sub-issue link" "-X POST repos/acme/home/issues/10/sub_issues"
assert_called    "link uses child db id"       "sub_issue_id=42042"
assert_called    "adds child to project"       "project item-add 7"
reset_mock
# guard: parent not a RootIssue
fixture GET repos/acme/home/issues/10 <<<'{"id":10,"labels":[]}'
fixture GET repos/acme/otc/issues/42  <<<'{"id":42042,"labels":[]}'
run sub-adopt.sh 'acme/otc' 42 'acme/home#10';      assert_fail "rejects parent without atdd:root"
reset_mock
# guard: child is itself a RootIssue
fixture GET repos/acme/home/issues/10 <<<'{"id":10,"labels":[{"name":"atdd:root"}]}'
fixture GET repos/acme/otc/issues/42  <<<'{"id":42042,"labels":[{"name":"atdd:root"}]}'
run sub-adopt.sh 'acme/otc' 42 'acme/home#10';      assert_fail "refuses to adopt a RootIssue as a sub"
reset_mock
# idempotency: already labelled + already linked -> no mutating label/link calls
fixture GET repos/acme/home/issues/10 <<<'{"id":10,"labels":[{"name":"atdd:root"}]}'
fixture GET repos/acme/otc/issues/42  <<<'{"id":42042,"labels":[{"name":"atdd:sub"}]}'
fixture GET repos/acme/home/issues/10/sub_issues <<<'[{"id":42042}]'
run sub-adopt.sh 'acme/otc' 42 'acme/home#10'
assert_ok          "idempotent re-run exits 0"
assert_not_called  "skips re-labelling"  "--add-label atdd:sub"
assert_not_called  "skips re-linking"    "-X POST repos/acme/home/issues/10/sub_issues"
teardown_repo

# ────────────────────────────────────────────────────────────────────────────
echo "== issue-edit.sh =="
setup_repo
run issue-edit.sh 'bad-ref' --title X;              assert_fail "rejects bad ref"
reset_mock
run issue-edit.sh 'acme/home#10';                   assert_fail "rejects no --title/--body-file"
reset_mock
fixture GET repos/acme/home/issues/10 <<<'{"id":10,"labels":[{"name":"atdd:root"}]}'
run issue-edit.sh 'acme/home#10' --title 'New Title'
assert_ok      "edit title exits 0"
assert_called  "calls gh issue edit --title" "issue edit 10 -R acme/home --title New Title"
reset_mock
# guard: unmanaged issue
fixture GET repos/acme/home/issues/10 <<<'{"id":10,"labels":[]}'
run issue-edit.sh 'acme/home#10' --title X;         assert_fail "refuses unmanaged issue"
reset_mock
# body via stdin "-"
fixture GET repos/acme/otc/issues/42 <<<'{"id":42042,"labels":[{"name":"atdd:sub"}]}'
STDIN_DATA='brand new body text' run issue-edit.sh 'acme/otc#42' --body-file -
assert_ok      "edit body from stdin exits 0"
assert_called  "passes new body to gh" "brand new body text"
STDIN_DATA=""
teardown_repo

# ────────────────────────────────────────────────────────────────────────────
echo "== issue-close.sh =="
setup_repo
run issue-close.sh 'bad-ref';                       assert_fail "rejects bad ref"
reset_mock
run issue-close.sh 'acme/home#10' --reason bogus;   assert_fail "rejects bad --reason"
reset_mock
fixture GET repos/acme/otc/issues/42 <<<'{"id":42042,"state":"open","labels":[{"name":"atdd:sub"}]}'
run issue-close.sh 'acme/otc#42'
assert_ok      "close open issue exits 0"
assert_called  "calls gh issue close" "issue close 42 -R acme/otc --reason completed"
reset_mock
fixture GET repos/acme/otc/issues/42 <<<'{"id":42042,"state":"closed","labels":[{"name":"atdd:sub"}]}'
run issue-close.sh 'acme/otc#42'
assert_ok          "already-closed exits 0"
assert_not_called  "no close call when already closed" "issue close 42"
reset_mock
fixture GET repos/acme/home/issues/10 <<<'{"id":10,"state":"closed","labels":[{"name":"atdd:root"}]}'
run issue-close.sh 'acme/home#10' --reopen
assert_ok      "reopen closed issue exits 0"
assert_called  "calls gh issue reopen" "issue reopen 10 -R acme/home"
reset_mock
fixture GET repos/acme/otc/issues/42 <<<'{"id":42042,"state":"open","labels":[{"name":"atdd:sub"}]}'
run issue-close.sh 'acme/otc#42' --reason not_planned
assert_called  "maps not_planned -> 'not planned'" "--reason not planned"
teardown_repo

# ────────────────────────────────────────────────────────────────────────────
echo "== sub-unlink.sh =="
setup_repo
run sub-unlink.sh 'bad' 'acme/home#10';             assert_fail "rejects bad sub-ref"
reset_mock
run sub-unlink.sh 'acme/otc#42' 'bad';              assert_fail "rejects bad root-ref"
reset_mock
fixture GET repos/acme/home/issues/10 <<<'{"id":10,"labels":[{"name":"atdd:root"}]}'
fixture GET repos/acme/otc/issues/42  <<<'{"id":42042,"labels":[{"name":"atdd:sub"}]}'
fixture GET repos/acme/home/issues/10/sub_issues <<<'[{"id":42042}]'
run sub-unlink.sh 'acme/otc#42' 'acme/home#10'
assert_ok      "unlink exits 0"
assert_called  "DELETEs sub_issue (singular path)" "-X DELETE repos/acme/home/issues/10/sub_issue"
assert_called  "delete uses child db id"           "sub_issue_id=42042"
reset_mock
# idempotency: not currently linked
fixture GET repos/acme/home/issues/10 <<<'{"id":10,"labels":[{"name":"atdd:root"}]}'
fixture GET repos/acme/otc/issues/42  <<<'{"id":42042,"labels":[{"name":"atdd:sub"}]}'
run sub-unlink.sh 'acme/otc#42' 'acme/home#10'
assert_ok          "noop when not linked exits 0"
assert_not_called  "no DELETE when not linked" "-X DELETE repos/acme/home/issues/10/sub_issue"
teardown_repo

# ────────────────────────────────────────────────────────────────────────────
echo "== root-undepend.sh =="
setup_repo
run root-undepend.sh 'x' 11;                        assert_fail "rejects non-numeric"
reset_mock
run root-undepend.sh 10 10;                         assert_fail "rejects self-edge"
reset_mock
fixture GET repos/acme/home/issues/10 <<<'{"id":10,"labels":[{"name":"atdd:root"}]}'
fixture GET repos/acme/home/issues/11 <<<'{"id":11011,"labels":[{"name":"atdd:root"}]}'
fixture GET repos/acme/home/issues/10/dependencies/blocked_by <<<'[{"id":11011}]'
run root-undepend.sh 10 11
assert_ok      "remove existing edge exits 0"
assert_called  "DELETEs the dependency edge by db id" "-X DELETE repos/acme/home/issues/10/dependencies/blocked_by/11011"
reset_mock
# idempotency: edge absent
fixture GET repos/acme/home/issues/10 <<<'{"id":10,"labels":[{"name":"atdd:root"}]}'
fixture GET repos/acme/home/issues/11 <<<'{"id":11011,"labels":[{"name":"atdd:root"}]}'
run root-undepend.sh 10 11
assert_ok          "noop when edge absent exits 0"
assert_not_called  "no DELETE when edge absent" "dependencies/blocked_by/11011"
teardown_repo

# ────────────────────────────────────────────────────────────────────────────
echo "== ready-unmark.sh =="
setup_repo
run ready-unmark.sh 'bad-ref';                      assert_fail "rejects bad ref"
reset_mock
fixture GET repos/acme/home/issues/10 <<<'{"id":10,"labels":[{"name":"atdd:root"}]}'
run ready-unmark.sh 'acme/home#10';                 assert_fail "refuses non-SubIssue"
reset_mock
fixture GET repos/acme/otc/issues/42 <<<'{"id":42042,"labels":[{"name":"atdd:sub"},{"name":"atdd:ready"}]}'
run ready-unmark.sh 'acme/otc#42'
assert_ok      "unmark ready exits 0"
assert_called  "removes ready label" "issue edit 42 -R acme/otc --remove-label atdd:ready"
reset_mock
# idempotency: not marked ready
fixture GET repos/acme/otc/issues/42 <<<'{"id":42042,"labels":[{"name":"atdd:sub"}]}'
run ready-unmark.sh 'acme/otc#42'
assert_ok          "noop when not ready exits 0"
assert_not_called  "no remove-label when not ready" "--remove-label atdd:ready"
teardown_repo

# ────────────────────────────────────────────────────────────────────────────
echo "== manifest-ensure.sh (owner-agnostic lookup; user-owned project regression) =="
setup_repo
# fast path: manifest exists -> pure read, no project lookup
run manifest-ensure.sh
assert_ok         "fast path: prints existing manifest"
assert_not_called "fast path makes no project lookup" "project view"
reset_mock
# bootstrap against a USER-owned project (regression: org-only GraphQL died here)
rm -f "${WORK}/.agent-tdd/manifest.json"
fixture_cmd project view <<<'{"id":"PVT_kwHO_user","title":"Cooksy"}'
fixture_cmd issue list   <<<'[]'
fixture_cmd issue create <<<'https://github.com/hn12404988/cooksy-hil/issues/9'
run manifest-ensure.sh 'https://github.com/users/hn12404988/projects/2' 'hn12404988/cooksy-hil'
assert_ok         "user-owned bootstrap exits 0"
assert_called     "resolves via owner-agnostic gh project view" "project view 2 --owner hn12404988 --format json"
assert_not_called "no org-only GraphQL lookup" "organization(login:"
got="$(jq -r '.project.id + " " + .project.title + " " + .project.owner' "${WORK}/.agent-tdd/manifest.json" 2>/dev/null)"
[[ "$got" == "PVT_kwHO_user Cooksy hn12404988" ]] \
  && pass "manifest stores id+title+owner from lookup" \
  || fail "manifest stores id+title+owner from lookup" "got: ${got}"
reset_mock
# bootstrap against an ORG-owned project goes through the same path
rm -f "${WORK}/.agent-tdd/manifest.json"
fixture_cmd project view <<<'{"id":"PVT_kwDO_org","title":"ACME Board"}'
fixture_cmd issue list   <<<'[]'
fixture_cmd issue create <<<'https://github.com/acme/home/issues/1'
run manifest-ensure.sh 'https://github.com/orgs/acme/projects/7' 'acme/home'
assert_ok         "org-owned bootstrap exits 0"
assert_called     "org lookup uses the same owner-agnostic path" "project view 7 --owner acme --format json"
reset_mock
# gh writing a notice to stderr on a SUCCESSFUL call must not poison parsed stdout
rm -f "${WORK}/.agent-tdd/manifest.json"
fixture_cmd project view <<<'{"id":"PVT_kwHO_user","title":"Cooksy"}'
fixture_cmd issue list   <<<'[]'
fixture_cmd issue create <<<'https://github.com/hn12404988/cooksy-hil/issues/9'
export MOCK_STDERR_NOISE='Notice: a new release of gh is available'
run manifest-ensure.sh 'https://github.com/users/hn12404988/projects/2' 'hn12404988/cooksy-hil'
unset MOCK_STDERR_NOISE
assert_ok         "stderr notice on success does not poison the lookup JSON"
reset_mock
# gh succeeds but returns shapeless JSON (no .id) -> die, no manifest
rm -f "${WORK}/.agent-tdd/manifest.json"
fixture_cmd project view <<<'{"title":"x"}'
run manifest-ensure.sh 'https://github.com/users/hn12404988/projects/2' 'hn12404988/cooksy-hil'
assert_fail       "dies when lookup returns no .id"
[[ ! -f "${WORK}/.agent-tdd/manifest.json" ]] \
  && pass "no manifest written on shapeless lookup" \
  || fail "no manifest written on shapeless lookup"
reset_mock
# valid JSON but no .title -> diagnostic die, not a silent set -e abort
rm -f "${WORK}/.agent-tdd/manifest.json"
fixture_cmd project view <<<'{"id":"PVT_x2"}'
run manifest-ensure.sh 'https://github.com/users/hn12404988/projects/2' 'hn12404988/cooksy-hil'
assert_fail       "dies when lookup JSON has no .title"
grep -q 'could not resolve project title' "${WORK}/err" \
  && pass "missing-title die carries a diagnostic" \
  || fail "missing-title die carries a diagnostic" "stderr: $(tail -1 "${WORK}/err" 2>/dev/null)"
reset_mock
# lookup failure -> clean die, no manifest written
rm -f "${WORK}/.agent-tdd/manifest.json"
export MOCK_FAIL_GLOB='project view *'
run manifest-ensure.sh 'https://github.com/users/hn12404988/projects/2' 'hn12404988/cooksy-hil'
assert_fail       "dies when project lookup fails"
[[ ! -f "${WORK}/.agent-tdd/manifest.json" ]] \
  && pass "no manifest written on failed lookup" \
  || fail "no manifest written on failed lookup"
unset MOCK_FAIL_GLOB
teardown_repo

# ────────────────────────────────────────────────────────────────────────────
echo "== _graph.sh (owner-agnostic node(id:) query; user-owned project regression) =="
setup_repo
fixture GET graphql <<'JSON'
{"data":{"node":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"content":{"number":10,"title":"Root A","state":"OPEN","createdAt":"2026-05-28T01:23:45Z","id":"I_a","repository":{"nameWithOwner":"acme/home"},"labels":{"nodes":[{"name":"atdd:root"}]},"blockedBy":{"nodes":[]},"blocking":{"nodes":[{"number":12,"repository":{"nameWithOwner":"acme/home"},"state":"OPEN"}]}}},
  {"content":{"number":12,"title":"Root B","state":"OPEN","createdAt":"2026-05-29T01:23:45Z","id":"I_c","repository":{"nameWithOwner":"acme/home"},"labels":{"nodes":[{"name":"atdd:root"}]},"blockedBy":{"nodes":[{"number":10,"repository":{"nameWithOwner":"acme/home"},"state":"OPEN"}]},"blocking":{"nodes":[]}}},
  {"content":{"number":11,"title":"Loose issue","state":"OPEN","createdAt":"2026-05-28T02:00:00Z","id":"I_b","repository":{"nameWithOwner":"acme/home"},"labels":{"nodes":[]},"blockedBy":{"nodes":[]},"blocking":{"nodes":[]}}}
]}}}}
JSON
run _graph.sh
assert_ok         "graph fetch exits 0"
assert_called     "queries by project node id from the manifest (owner-agnostic)" "pid=PVT_x"
assert_not_called "no org-only GraphQL query" "organization(login:"
refs="$(jq -c '[.issues[].ref] | sort' <<<"$OUT" 2>/dev/null)"
[[ "$refs" == '["acme/home#10","acme/home#12"]' ]] \
  && pass "emits RootIssues only, parsed from node(id:) response shape" \
  || fail "emits RootIssues only, parsed from node(id:) response shape" "got: ${refs}"
tbc="$(jq -r '.issues[] | select(.ref=="acme/home#10") | .transitive_blocking_count' <<<"$OUT" 2>/dev/null)"
[[ "$tbc" == "1" ]] \
  && pass "transitive_blocking_count computed from new shape" \
  || fail "transitive_blocking_count computed from new shape" "got: ${tbc}"
teardown_repo

# ────────────────────────────────────────────────────────────────────────────
echo "== notebook-head-get.sh (Bug 1 regression: must return body, not empty) =="
setup_repo
fixture GET 'repos/acme/home/issues/1/comments?per_page=100&page=1' <<'JSON'
[{"id":555,"body":"<!-- atdd-head: acme/home#10 -->\n\nNotes line 1\nNotes line 2"}]
JSON
run notebook-head-get.sh 'acme/home#10'
assert_ok   "reads head comment exits 0"
assert_out  "returns full body minus marker (regression: not empty)" $'Notes line 1\nNotes line 2'
reset_mock
# no matching comment -> empty output, still exit 0
fixture GET 'repos/acme/home/issues/1/comments?per_page=100&page=1' <<<'[{"id":1,"body":"unrelated"}]'
run notebook-head-get.sh 'acme/home#10'
assert_ok   "no-match exits 0"
assert_out  "no-match prints empty" ""
teardown_repo

summary
