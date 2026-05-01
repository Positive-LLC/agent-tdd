---
name: atdd-demo
description: Run a short Agent TDD demo against a tiny utility task in the current repo, so the human can see the wave-based workflow end-to-end before committing to a real task. Use when the human types `/agent-tdd:atdd-demo` to evaluate or learn the plugin.
disable-model-invocation: true
user-invocable: true
allowed-tools: Bash Read Write Edit Grep Glob Agent
argument-hint: (optional — leave blank to use the default canned demo task)
---

# You are Root (demo mode)

Thin wrapper around `/atdd`. Read `${CLAUDE_SKILL_DIR}/../atdd/SKILL.md` and `${CLAUDE_SKILL_DIR}/../atdd/PROTOCOL.md` and operate as if `/atdd` had been invoked, with the three deltas below. All ten hard invariants from `/atdd` apply unchanged.

**Path remapping:** `${CLAUDE_SKILL_DIR}` here points to `skills/atdd-demo/`, but every recipe, role, and protocol file lives under `skills/atdd/`. Throughout this run, treat every `${CLAUDE_SKILL_DIR}/...` reference in atdd's docs as `${CLAUDE_SKILL_DIR}/../atdd/...`.

## Demo deltas

1. **Pre-seed Wave 0.** If `$ARGUMENTS` is blank, propose a tiny standalone utility in a NEW file under `demo/` in the repo root, in the repo's primary language (detect from existing source extensions; ask if ambiguous). Default suggestion: `is_palindrome(s) -> bool` covering empty string, single char, even/odd length, mixed case, non-alphanumeric. Human can substitute any equally small alternative. One Wave-1 issue only.

2. **Pass `true` as the 4th arg to `init-root.sh`** at Wave 0 step 7. The recipe writes `meta.json:demo = true` and caps `max_waves` to 1.

3. **At §8, skip the final-merge prompt.** When `meta.json:demo == true`: do not run §8 step 1; instead print `"Demo complete. To clean up: git branch -D agent-tdd/<task> && git push origin --delete agent-tdd/<task> && rm -rf demo/."`. Then proceed with §8 steps 3–6. The demo never merges into `<base>`.

`meta.json:demo` is your durable signal across compaction — re-check it at every phase boundary.
