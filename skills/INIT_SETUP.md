# INIT_SETUP — ensure the `atdd` binary is installed

**Every entry skill runs this first.** The Agent TDD inner flow runs on the local
`atdd` CLI (it replaces `gh` — work-items, labels, sub-issues, dependencies, the
notebook, the green/merge seam all live in a local store, no GitHub in the inner flow).
The recipes call `atdd` as a bare command, so the binary must be on your `PATH` before
anything else runs.

The `atdd` source lives in a private repo; its prebuilt binaries are published as assets
on the **public** `Positive-LLC/agent-tdd` GitHub Release for the matching version, so any
host can download the right one with no authentication.

## Do this (one command)

Run, before any recipe or protocol step:

```bash
bash "${CLAUDE_SKILL_DIR}/../ensure-atdd.sh"
```

It is idempotent — a no-op if the correct `atdd` version is already installed; otherwise
it detects your OS/arch, downloads the matching binary from the Release, installs it to
`~/.local/bin/atdd`, verifies it, and warms the daemon. **Do not proceed until `atdd ping`
succeeds.** If it prints a `WARNING` that `~/.local/bin` is not on `PATH`, add it
(`export PATH="$HOME/.local/bin:$PATH"`) — or tell the human — and re-check `command -v atdd`.

## Manual fallback (unusual host, or the script failed)

The version is in `skills/VERSION` (read it as `VERSION`). Map your platform and download:

```bash
VERSION="$(cat "${CLAUDE_SKILL_DIR}/../VERSION")"          # e.g. 1.1.0
os=$(uname -s);  case "$os" in Linux) os=linux;; Darwin) os=darwin;; esac
arch=$(uname -m); case "$arch" in x86_64|amd64) arch=x86_64;; aarch64|arm64) arch=arm64;; esac
mkdir -p ~/.local/bin
curl -fsSL "https://github.com/Positive-LLC/agent-tdd/releases/download/v${VERSION}/atdd-${os}-${arch}" -o ~/.local/bin/atdd
chmod +x ~/.local/bin/atdd
~/.local/bin/atdd --version    # should print: atdd ${VERSION}
```

Assets are named `atdd-<os>-<arch>` for `os ∈ {linux, darwin}` and `arch ∈ {x86_64, arm64}`
(Linux binaries are musl-static; there is **no Windows build** — the daemon uses a Unix
socket). Each Release also ships `SHA256SUMS`.

## Other prerequisites

The recipes also need **`jq`** and **`git`** on `PATH` (`ensure-atdd.sh` warns if missing).
These are system tools — install them via your package manager if absent.
