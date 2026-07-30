<!-- STACK-USAGE-SYNC: v6  (shared drift marker — bump in BOTH files when either's
     SUBSTANCE changes; tests/stack-usage-sync.sh fails until they match. The two docs
     are NOT byte-identical by design, so this marker — not a diff — is the sync gate.) -->

# atdd stack — Build Layers, wire Pipelines, verify against live code

## 0. TL;DR

The stack model has **Layers** and **Interfaces** arranged in a tree, with
**Anchors** (resolvable source-code locations) locking each entity to real
files/symbols, and **Pipelines** describing vertical cross-layer flows.

**FOR THE AGENT — your job, in order:**
1. Get `atdd` working (§1).
2. Register the target repo.
3. Create top-level **Layers** and connect them with **Interfaces** (§2).
4. Add **Anchors** to layers/interfaces so they point at real code (§3).
5. Create **Pipelines** between adjacent Anchors (§4).
6. Add **messages** to Pipelines describing what flows along them.
7. Navigate: `atdd stack roots` → `atdd stack zoom <id>` (§5).
8. **Verify** anchors against live code: `atdd stack verify` (§6).
9. Read drift state: `atdd stack drift` (§6).

---

## 1. Get `atdd` working

```bash
atdd --version
# If "command not found": build with `cargo build`, then use the absolute path.
```

- The **daemon autostarts** on first use — never start it yourself.
- **Isolate into a project:**

```bash
atdd project create <slug>
```

- ⚠️ **Pass `--project <slug>` on EVERY command.**

---

## 2. Create Layers and Interfaces

A Layer is a unit of architecture tied to a repo. An Interface sits between an
**upper** and a **lower** Layer, describing the contract across the boundary.

### Create a top-level Layer with an anchor

```bash
# Register the repo first
atdd repo register OWNER/REPO /abs/path/to/repo

# Create a Layer, optionally with an anchor in one shot
atdd layer add <id> --repo OWNER/REPO --name "Layer Name" \
  --at "OWNER/REPO:path/to/file.rs#symbolName"
```

- `--at` creates an Anchor automatically: `repo:path#symbol`
- `--parent <parent-id>` places the new layer under an existing one

### Create child layers (zoom deeper)

```bash
# A sub-layer under an existing parent
atdd layer add <parent>/<child> --parent <parent> --name "Child" \
  --at "OWNER/REPO:src/child.rs"
```

### Create an Interface between two Layers

```bash
atdd interface add <id> --name "Interface Name" \
  --upper <upper-layer-id> --lower <lower-layer-id> \
  --at "OWNER/REPO:path/to/file.rs#symbol"
```

### Show, list, edit

```bash
atdd layer show <id>        # full detail including anchors + lastVerified
atdd layer list             # all layers
atdd layer edit <id> --name "New Name" --summary "updated"

atdd interface show <id>
atdd interface list
atdd interface edit <id> --name "New Name"
```

---

## 3. Add Anchors (lock entities to real code)

Each Layer or Interface can carry one or more Anchors. An Anchor points at a
real file or symbol via LSP-resolvable coordinates.

**Anchors are added within a zoom session.** First zoom into the entity, then
add the anchor:

```bash
# Navigate to the entity
atdd stack zoom <layer-or-interface-id>

# Add an anchor to the current entity
atdd stack anchor-add --repo OWNER/REPO --path src/main.rs

# With a symbol (LSP-resolvable)
atdd stack anchor-add --repo OWNER/REPO --path src/main.rs --symbol main

# With line range
atdd stack anchor-add --repo OWNER/REPO --path src/server.ts \
  --symbol appRouter --line-start 10 --line-end 80
```

```bash
atdd stack anchor-rm <id>          # remove by anchor id
atdd stack anchor-edit <id> --path new/path.rs --symbol newName
```

**Anchor grammar** (`--path`): `path/to/file` · `path/to/dir/`.
With `--symbol`: `Module::name` (Rust) or `export function name` (TS).
Line range: `--line-start N --line-end M`.

---

## 4. Create Pipelines (vertical cross-layer flows)

A Pipeline connects two Anchors on **structurally adjacent** entities — one
Layer and one Interface connected to it (the 1-unit distance rule).

```bash
# Pipeline from a Layer to an Interface
atdd pipeline add --id gql-to-gateway --name "Query Flow" \
  --from-anchor <anchor-on-layer> --to-anchor <anchor-on-interface>

# Add messages describing what flows
atdd pipeline message add --pipeline gql-to-gateway \
  --body "GraphQL query string parsed and validated"

atdd pipeline message add --pipeline gql-to-gateway \
  --body "Resolved field names matched to resolver map"
```

Pipelines chain via **shared Anchors**: Pipeline 1's `to` Anchor can be
Pipeline 2's `from` Anchor, forming longer flows.

```bash
atdd pipeline list
atdd pipeline show <id>
atdd pipeline rm <id>
```

---

## 5. Navigate (zoom-based session)

The stack navigation is session-based — you zoom into an entity, then
operations apply to the current position.

```bash
# Entry point: top-level Layers as stubs
atdd stack roots

# Zoom one level — see the entity's neighborhood (anchors, interfaces, pipelines, child layers)
atdd stack zoom <id>

# Ascend one level
atdd stack back

# Print current breadcrumb
atdd stack current
```

The dashboard provides the bird's-eye view:

```bash
atdd dashboard --open
```

---

## 6. Verify and Drift

### Verify anchors against live code

`atdd stack verify` resolves every anchored layer/interface against today's
code. For file-only anchors, it checks `Path::exists()`. For `#symbol`
anchors in symbol-precise languages (Rust, Python, TypeScript), it spawns the
registered LSP and semantically resolves the symbol.

```bash
# Verify all anchored entities
atdd stack verify

# Scope to a specific layer's subtree
atdd stack verify --layer <layer-id>

# Resolve against a worktree (e.g. pre-merge Impl branch)
atdd stack verify --layer <layer-id> --worktree /path/to/worktree
```

Exits non-zero on drift. Output buckets:

| Status | Meaning |
|---|---|
| `verified` | File present / symbol found in same spot |
| `drifted` | File missing / symbol moved or deleted |
| `blocked` | `#symbol` in symbol-precise language with no registered LSP |
| `unverifiable` | LSP was unreachable (not evidence of drift) |

### Read persisted drift state

```bash
atdd stack drift
```

Lists non-clean nodes from the last `stack verify` without re-resolving:
`contradicted`, `versionChanged`, `blocked`, `unverifiable`, `unverified`.
Exits non-zero when the gate is present.

---

## 7. Link entities to work-items

```bash
atdd pipeline link --pipeline <id> --issue OWNER/REPO#42
atdd pipeline unlink --pipeline <id> --issue OWNER/REPO#42
```

---

## 8. Verb quick-reference

```
project     create <slug> | list
repo        register <owner/repo> <local-path>

layer       add <id> --repo <r> --name <n> [--at <repo:path#symbol>] [--parent <pid>]
            show <id> | list
            edit <id> [--name <n>] [--summary <s>] [--repo <r>]

interface   add <id> --name <n> --upper <uid> --lower <lid> [--at <repo:path#symbol>]
            show <id> | list
            edit <id> [--name <n>] [--summary <s>]

anchor      add --repo <r> --path <p> [--symbol <s>] [--line-start N] [--line-end M]
              (must be zoomed into a layer/interface first)
            edit <id> [--path <p>] [--symbol <s>]
            rm <id>

pipeline    add --id <id> --name <n> --from-anchor <id> --to-anchor <id>
            list | show <id> | rm <id>
            link --pipeline <id> --issue <ref>
            unlink --pipeline <id> --issue <ref>
            message add --pipeline <id> --body <text> [--anchor <id>]

stack       roots             # top-level Layers as stubs
            zoom <id>         # zoom layer/interface/process/pipeline
            back              # ascend one level (not yet wired)
            current           # print breadcrumb (not yet wired)
            verify            # resolve Anchors via LSP
              [--layer <id>] [--worktree <path>]
            drift             # read persisted drift state
              [--worktree <path>]
            bootstrap --size 2|3 --name <id> --top-name <n> --bottom-name <n>
              --top-mid-name <n> [--middle-name <n>] [--mid-bot-name <n>]
            expand --size 2|3 --name <id> --top-name <n> --bottom-name <n>
              --top-mid-name <n> [--entity-layer <id>|--entity-interface <id>]
            collapse [--entity-layer <id>|--entity-interface <id>]
            anchor-add --repo <r> --path <p> [--symbol <s>]
              [--entity-layer <id>|--entity-interface <id>]
            anchor-edit <id> [--path <p>] [--symbol <s>]
            anchor-rm <id>

lsp         register --repo <r> --lang <lang> --bin <path> [--version <v>]
            list [--repo <r>]

dashboard   [--open]
```

*(Output is JSON — pipe to `jq`.)*
