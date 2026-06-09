#!/usr/bin/env bash
# ensure-atdd.sh — make sure the `atdd` CLI matching this plugin version is on PATH.
#
# The agent-tdd inner flow runs on the local `atdd` tool (like `gh`, but local).
# The CLI source is private; its prebuilt binaries are published as assets on the
# PUBLIC agent-tdd GitHub Release, so this downloads the right one (no auth needed).
# Idempotent: a no-op when the correct version is already installed.
#
# Run this once at the start of every entry skill (see INIT_SETUP.md).
set -euo pipefail

REPO="Positive-LLC/agent-tdd"
INSTALL_DIR="${HOME}/.local/bin"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '[ensure-atdd] %s\n' "$*" >&2; }
die() { printf '[ensure-atdd] ERROR: %s\n' "$*" >&2; exit 1; }

# Version to install = this plugin's version (kept in lockstep with the CLI).
VERSION="$(tr -d '[:space:]' < "${SCRIPT_DIR}/VERSION" 2>/dev/null || true)"
[[ -n "$VERSION" ]] || die "cannot read plugin version from ${SCRIPT_DIR}/VERSION"

# 1) Already the right version? -> done.
if command -v atdd >/dev/null 2>&1; then
  cur="$(atdd --version 2>/dev/null | awk '{print $NF}')"
  if [[ "$cur" == "$VERSION" ]]; then
    log "atdd ${VERSION} already installed ($(command -v atdd))"
    atdd ping >/dev/null 2>&1 || true
    exit 0
  fi
  log "found atdd ${cur:-unknown}; need ${VERSION} — updating"
fi

# 2) Detect platform -> asset name (matches the build matrix: linux/darwin x86_64/arm64).
os="$(uname -s)"; arch="$(uname -m)"
case "$os" in
  Linux)  os=linux ;;
  Darwin) os=darwin ;;
  *) die "unsupported OS '$os' — atdd ships linux + macOS only (the daemon uses a Unix socket)" ;;
esac
case "$arch" in
  x86_64|amd64)   arch=x86_64 ;;
  aarch64|arm64)  arch=arm64 ;;
  *) die "unsupported architecture '$arch'" ;;
esac
asset="atdd-${os}-${arch}"
base="https://github.com/${REPO}/releases/download/v${VERSION}"

command -v curl >/dev/null 2>&1 || die "curl is required to download the atdd binary"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
log "downloading ${asset} (v${VERSION}) from ${REPO}"
curl -fsSL "${base}/${asset}" -o "${tmp}/atdd" \
  || die "download failed: ${base}/${asset} — does Release v${VERSION} have asset ${asset}?"

# 3) Verify checksum if the release ships SHA256SUMS (best-effort).
if curl -fsSL "${base}/SHA256SUMS" -o "${tmp}/SHA256SUMS" 2>/dev/null; then
  want="$(awk -v a="$asset" '($2==a)||($2=="*"a){print $1}' "${tmp}/SHA256SUMS" | head -1)"
  if [[ -n "$want" ]]; then
    if   command -v sha256sum >/dev/null 2>&1; then got="$(sha256sum "${tmp}/atdd" | awk '{print $1}')"
    elif command -v shasum    >/dev/null 2>&1; then got="$(shasum -a 256 "${tmp}/atdd" | awk '{print $1}')"
    else got="" ; fi
    [[ -z "$got" || "$got" == "$want" ]] || die "checksum mismatch for ${asset}"
    [[ -n "$got" ]] && log "checksum ok"
  fi
fi

# 4) Install.
mkdir -p "$INSTALL_DIR"
chmod +x "${tmp}/atdd"
mv -f "${tmp}/atdd" "${INSTALL_DIR}/atdd"
log "installed ${INSTALL_DIR}/atdd"

# 5) PATH + dependency checks + warm the daemon.
case ":${PATH}:" in
  *":${INSTALL_DIR}:"*) ;;
  *) log "WARNING: ${INSTALL_DIR} is not on PATH — add it so recipes can find atdd: export PATH=\"${INSTALL_DIR}:\$PATH\"" ;;
esac
command -v jq  >/dev/null 2>&1 || log "WARNING: 'jq' not found — the recipes need it (install jq)."
command -v git >/dev/null 2>&1 || log "WARNING: 'git' not found — the workflow needs it."
"${INSTALL_DIR}/atdd" --version >/dev/null 2>&1 || die "installed atdd is not runnable (platform mismatch?)"
"${INSTALL_DIR}/atdd" ping >/dev/null 2>&1 || true
log "atdd ${VERSION} ready"
