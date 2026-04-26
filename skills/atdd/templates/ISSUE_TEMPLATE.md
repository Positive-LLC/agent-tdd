<!--
Agent TDD issue template (§5.2 of PROTOCOL.md).

Root copies this file, replaces the `<...>` placeholders, and feeds it to
`gh issue create --body-file <path>`.

Section rules:
  - Subject Under Test: repo-root-relative POSIX path, optionally `path:identifier`.
    No `./` prefix. Forward slashes. Examples: `src/auth.ts`, `src/auth.ts:validateToken`.
  - Behavior: one sentence, present tense, describing the contract.
  - Type: exactly one of: unit | integration | property | regression.
  - Provenance: where the issue came from. For Wave 1 issues, "From Wave 0 spec discussion."
  - Test Branch: leave the placeholder; the test agent fills it in.
  - Needs Clarification: include this section ONLY if Root has a question that must be
    answered before the test agent starts. The test agent will pause and ask via .paused
    status; Root will edit the issue to remove this section once resolved.

Do not delete the section headings; tooling and dedup rely on them.
-->

## Subject Under Test
<path or path:identifier>

## Behavior
<one-sentence description of the contract>

## Type
<unit | integration | property | regression>

## Provenance
<e.g. "From Wave 0 spec discussion." OR "Spawned from #<parent> during Wave <N> by Root <id>. Reason: <why>.">

## Test Branch (filled in by test agent)
`issue-<N>-tests` @ <commit-sha>
