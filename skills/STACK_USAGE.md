<!-- CANONICAL agent-facing copy. Mirrors atdd-cli/STACK_USAGE.md (the tool repo);
     keep the two in sync. All four Agent-TDD agents read THIS file (one source,
     many references) via ${CLAUDE_SKILL_DIR}/../STACK_USAGE.md — never paste it. -->
<!-- STACK-USAGE-SYNC: v3  (shared drift marker — bump in BOTH files when either's
     SUBSTANCE changes; atdd-cli/tests/stack-usage-sync.sh fails until they match. The
     two docs are NOT byte-identical by design, so this marker — not a diff — is the gate.) -->

# atdd Stack — build & maintain a verified architecture model

> ## 🚧 atdd-cli is ALPHA — capture friction as you go
>
> The `atdd` tool is **early alpha**: rough edges, confusing output, and outright bugs are
> expected. When a Stack verb confuses you, errors out, behaves unexpectedly, or makes you
> wish it did something — **drop a quick note** (don't push through silently and lose it):
>
> ```bash
> # Same path prefix you use for stack-zoom.sh: ${PLUGIN_DIR}/recipes (Test/Impl) or
> # ${CLAUDE_SKILL_DIR}/../atdd/recipes (Root/Notes). Add --role test|impl|root|notes.
> printf 'exact command + output, and what you expected\n' \
>   | bash "<recipes>/drop-feedback.sh" --role <r> --summary "<one-line gist>"
> ```
>
> This is a **side channel** — it must NOT derail your real task. One quick note, then move on.

This is how an Agent-TDD agent drives atdd-cli's **Stack** engine: declare a repo's
architecture (Layers / Interfaces / Processes / Pipelines), **verify it against the real
code**, and navigate it one level at a time. Use it when you build or touch the architecture
model for the repo you're working in (e.g. the end-of-task zoom-in, or to understand a layer
before changing it).

> **LSP is mandatory for symbol-precise languages.** A `#symbol` anchor in a language that has
> a real LSP (Rust, …) MUST have that LSP registered — `stack verify` **blocks** it otherwise
> (never a silent "verified"). This is non-negotiable; see §4. shell / markdown / config have no
> symbol LSP and stay at file granularity (never blocked).

There is **no** `atdd` command that builds a Stack from a repo — *you* are the intelligence:
you read the code, decide the Layers / Interfaces / Processes, run the verbs, and the daemon
verifies your claims against the code.

---

## 1. Mental model (read once)

- **One Stack per project.** Each registered repo is a **top Layer** (`parent_id == null`).
- **Structural axis (zoom):** `Stack → Layer / Interface → child Stack`. Recursion lives in Layer
  nesting (`--parent`), to any depth. Zooming a Layer shows its direct children + its boundary
  interfaces — **one level at a time**.
- **Behavioral axis (projection):** **Process / Pipeline** is *not* a deeper structural level — it
  is the "what happens / what flows" overlay attributed to a Layer. A **Process** = 1 trigger →
  1..n outputs; a **Pipeline** = an ordered chain of processes.
- **Interface** = the typed boundary between an upper and a lower Layer, realized by one
  **communication type** (`request_response | callback | persistent | brokered`); an `owner`
  side publishes it.
- Every box carries **provenance** (`by`: lsp|llm|human), **confidence** (proposed|verified), an
  optional **anchor** (a code location), and a persisted **drift** state set by `stack verify`.
- **Reading = navigate, not dump:** start at `stack roots`, then `stack zoom <id>` one level at a
  time. There is no whole-graph command for agents (the dashboard has the human bird's-eye).

## 2. Before you build

- `ensure-atdd.sh` (run at wave bootstrap) put the matching `atdd` on PATH; the **daemon
  autostarts** — never start it yourself.
- **Pass `--project <slug>` on EVERY command.** Each tool call is a fresh shell, so
  `export ATDD_PROJECT=…` does NOT persist between calls — an un-scoped command silently writes
  to the `default` project. The wave's bootstrap already pinned the project; use that slug.
- **The repo's LSP must already be registered** for any symbol-precise language it uses — the
  bootstrap gate (`stack-preflight.sh`) enforces this before work starts (§4).

## 3. Build (declare the architecture)

Replace `OWNER/REPO` with the repo's atdd slug and `/abs/path` with its path.

```bash
# register the repo (gives anchors a real path so verify can resolve files)
atdd --project <slug> repo register OWNER/REPO /abs/path

# TOP layers — one per major area (as many as the system genuinely has; most are 3–8)
atdd --project <slug> layer add api  --repo OWNER/REPO --name "API"  --summary "http handlers" --at 'OWNER/REPO:src/api'
atdd --project <slug> layer add core --repo OWNER/REPO --name "Core" --summary "domain logic"  --at 'OWNER/REPO:src/core'

# sub-layers (recursive zoom) where it matters
atdd --project <slug> layer add api/auth --parent api --name "Auth" --at 'OWNER/REPO:src/api/auth.rs#Authenticator'

# interfaces across boundaries + processes (behavior)
atdd --project <slug> interface add --id api-core --upper api --lower core --comm request-response --owner upper --summary "service calls"
atdd --project <slug> process add --layer api --id handle-login --name "Handle login" --trigger "POST /login" --in "credentials" --out "session token"
# bind a process port to the interface its I/O crosses → the process then shows as a
# *hosted process* under `stack zoom api-core`
atdd --project <slug> process port --process handle-login --direction out --interface api-core --descriptor "session token"

# pipelines (ordered process chains)
atdd --project <slug> pipeline add --id login-flow --name "Login flow" --steps handle-login,issue-token
```

**Anchor grammar** (`--at`): `OWNER/REPO:path/to/file` · `OWNER/REPO:path#Qualified::name`
(symbol) · `OWNER/REPO:path/to/dir/` (directory). Point anchors at **real** files/symbols so
verify is meaningful.

## 4. LSP is MANDATORY (do not skip — this is the point)

`stack verify` resolves anchors against today's code:
- **File/dir anchors** → a file-exists check (no LSP needed).
- **`#symbol` anchors in a symbol-precise language (Rust, …)** → resolved **semantically by the
  registered LSP**. With **no LSP registered**, such an anchor is **`blocked`** — it flips `ok`,
  `stack verify`/`stack drift` exit non-zero, and it is **never** reported as a silent `verified`.

So for any symbol-precise repo you MUST register its LSP first:

```bash
atdd --project <slug> lsp register --repo OWNER/REPO --lang rust --bin "$(command -v rust-analyzer)"
```

shell / markdown / config have no symbol LSP → they stay at file granularity, never blocked. The
wave bootstrap's `stack-preflight.sh` gate refuses to start work on a symbol-precise repo whose
LSP is missing — provision it (ask the human → install → `atdd repo register` if needed →
`atdd lsp register`) before proceeding. **Never treat the LSP as optional.**

## 5. Verify + read

```bash
atdd --project <slug> stack verify            # all anchored nodes (or --layer <slug> for a subtree)
atdd --project <slug> stack roots             # the top layers (the navigation entry point)
atdd --project <slug> stack zoom <id>         # one node's 1-level neighborhood; echo back any id it returns
atdd --project <slug> stack drift             # persisted drift state, no re-resolve
```

**`verify` reports five outcomes — don't conflate them:**
- `verified` — file present / symbol resolved in place. Clean.
- `drifted` — file missing / symbol moved / renamed / deleted. Real drift; flips `ok`.
- `blocked` — a `#symbol` in a symbol-precise language with **no registered LSP** (§4). Flips `ok`;
  close it by registering the LSP, not by re-running.
- `unverifiable` — a **registered** LSP was unreachable (timeout/crash). NOT drift; `ok` stays;
  re-run once it's back.
- `unverified` / `skipped` — a node with **no anchor** is never checked; it's counted in the
  `skipped` total (never silently dropped) and listed under `unverified` by `stack drift`.

**`stack zoom` returns exactly one level** (no `--depth`); to go deeper, zoom a neighbor's id.
**Pipelines are navigable:** `stack zoom <pipeline-id>` returns the pipeline + its ordered step
processes, and a pipeline also surfaces as a stub under each layer/process it touches — so you
reach it by normal `roots → zoom` (you never need its id ahead of time).

## 6. Gotchas

- **Ids are unique across kinds** — a `layer`, `interface`, `process`, and `pipeline` can't share
  an id. Convention: layers are path slugs (`api/auth`); interfaces/processes/pipelines are names
  (`api-core`, `handle-login`, `login-flow`).
- **Made a mistake? remove it:** `layer rm <slug>` / `interface rm <id>` / `process rm <id>` /
  `pipeline rm <id>`. Ids can't be renamed — `rm` then re-`add`.
- `--comm` ∈ `request-response | callback | persistent | brokered`; `--owner` ∈ `upper | lower`.
- A passing `verify` stamps `last_verified` + `drift`, but does **not** change `confidence`
  (confidence is what *you* assert via `--confidence`; drift is whether the anchor is fresh).
- Output is JSON on stdout (pipe to `jq`); diagnostics/errors are on stderr; a non-zero exit means
  drift/blocked/error — gate on the exit code, not on grepping text.
- Human bird's-eye of the whole graph: `atdd dashboard` (prints the URL). Agents use roots + zoom.

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
`--layer` is **optional** — omit it to verify the whole Stack, or pass it to scope the verify to the
one layer you touched.

## 7. Verb quick-reference

```
project   create <slug> | list
repo      register <owner/repo> <local-path>
layer     add <slug> [--parent][--repo][--at][--by lsp|llm|human][--confidence proposed|verified][--summary]
          list | show <slug> | edit <slug> … | rm <slug> | at <owner/repo:path>
interface add --id <id> --upper <l> --lower <l> --comm <type> [--owner upper|lower][--variant][--at][--summary]
          list | show <id> | edit <id> … | rm <id>
process   add --layer <l> --id <id> --name <n> [--trigger][--in …][--out …][--at][--summary]
          port --process <pid> --direction <trigger|in|out> --descriptor <d> [--interface <iid>]
          group --parent <pid> --members a,b,c | list | show <id> | edit <id> … | rm <id>
pipeline  add --id <id> --name <n> [--steps p1,p2,p3] | list | show <id> | rm <id>
lsp       register --repo <owner/repo> --lang <l> --bin <path> [--args][--protocol][--kind][--version] | list
stack     roots | zoom <id> | verify [--layer <slug>] | drift
dashboard [--open]
```

*(Every command is scoped to the pinned project — pass `--project <slug>` on each call.)*
