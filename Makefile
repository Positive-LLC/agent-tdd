# Makefile — keep the plugin + CLI version in lockstep across all five files.
#
#   make set-version VERSION=1.1.2          # set every file to 1.1.2
#   make set-version VERSION=1.2.0-snapshot # prerelease suffix is allowed too
#   make show-version                       # print the version each file currently holds
#
# Four files live in this repo; the CLI's Cargo.toml lives in the sibling
# atdd-cli repo. Override the sibling path if your layout differs:
#   make set-version VERSION=1.1.2 ATDD_CLI=/path/to/atdd-cli

SHELL := bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

ATDD_CLI   ?= ../atdd-cli
CARGO_TOML := $(ATDD_CLI)/atdd/Cargo.toml

PKG          := package.json
PLUGIN       := .claude-plugin/plugin.json
CODEX        := .codex-plugin/plugin.json
VERSION_FILE := skills/VERSION

# Local dev-binary swap targets (see the bottom of this file).
ATDD_INSTALL_DIR ?= $(HOME)/.local/bin
DEV_ATDD         := $(abspath $(ATDD_CLI))/target/release/atdd

# OpenCode installed plugin path (for dev-plugin swap).
OPENCODE_PLUGIN  := $(HOME)/.cache/opencode/packages/@positivegrid/agent-tdd@latest/node_modules/@positivegrid/agent-tdd

.PHONY: help set-version show-version use-dev-atdd use-release-atdd build-dev-atdd atdd-status use-dev-plugin restore-plugin sync-deepcode-skills

help:
	@echo "make set-version VERSION=X.Y.Z   set the version in all 5 files (lockstep)"
	@echo "make show-version                show the version each file holds"
	@echo "make use-dev-atdd                symlink installed atdd -> local v2 dev build (no release)"
	@echo "make use-release-atdd            restore the real release binary (or re-download)"
	@echo "make build-dev-atdd              cargo build --release in the sibling atdd-cli"
	@echo "make atdd-status                 show which atdd is active + versions"
	@echo "make use-dev-plugin              sync repo -> installed OpenCode plugin (npm files only)"
	@echo "make restore-plugin              print command to re-install published plugin from npm"
	@echo "make sync-deepcode-skills        symlink all skills into ~/.agents/skills/ for Deep Code discovery"

set-version:
	@if [ -z "$(VERSION)" ]; then
	  echo "usage: make set-version VERSION=X.Y.Z" >&2; exit 1
	fi
	# Accept strict X.Y.Z or an optional prerelease suffix (e.g. 1.2.0-snapshot).
	if ! echo "$(VERSION)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$$'; then
	  echo "error: VERSION '$(VERSION)' is not X.Y.Z or X.Y.Z-suffix (e.g. 1.1.2, 1.2.0-snapshot)" >&2; exit 1
	fi
	if [ ! -f "$(CARGO_TOML)" ]; then
	  echo "error: $(CARGO_TOML) not found — set ATDD_CLI=/path/to/atdd-cli" >&2; exit 1
	fi
	# Surgical, format-preserving edits (sed -> temp -> mv is GNU/BSD portable). The
	# leading indentation is outside the match, so tabs vs spaces are left untouched.
	# The version capture accepts a trailing -prerelease suffix in every file.
	# package.json — the top-level "version" key
	t=$$(mktemp); sed -E 's/"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?"/"version": "$(VERSION)"/' "$(PKG)"    > "$$t" && mv "$$t" "$(PKG)"
	# .claude-plugin/plugin.json — same key (tab-indented; indentation preserved)
	t=$$(mktemp); sed -E 's/"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?"/"version": "$(VERSION)"/' "$(PLUGIN)" > "$$t" && mv "$$t" "$(PLUGIN)"
	# .codex-plugin/plugin.json — same key
	t=$$(mktemp); sed -E 's/"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?"/"version": "$(VERSION)"/' "$(CODEX)"  > "$$t" && mv "$$t" "$(CODEX)"
	# skills/VERSION — whole file
	printf '%s\n' "$(VERSION)" > "$(VERSION_FILE)"
	# atdd/Cargo.toml — the [package] version (anchored at column 0; dep versions are indented/inline)
	t=$$(mktemp); sed -E 's/^version = "[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?"/version = "$(VERSION)"/' "$(CARGO_TOML)" > "$$t" && mv "$$t" "$(CARGO_TOML)"
	echo "set version $(VERSION) in 5 files:"
	$(MAKE) --no-print-directory show-version

show-version:
	@printf '  %-32s %s\n' "$(PKG)"          "$$(jq -r .version "$(PKG)")"
	printf '  %-32s %s\n' "$(PLUGIN)"       "$$(jq -r .version "$(PLUGIN)")"
	printf '  %-32s %s\n' "$(CODEX)"        "$$(jq -r .version "$(CODEX)")"
	printf '  %-32s %s\n' "$(VERSION_FILE)" "$$(tr -d '[:space:]' < "$(VERSION_FILE)")"
	printf '  %-32s %s\n' "$(CARGO_TOML)"   "$$(grep -E '^version = ' "$(CARGO_TOML)" | head -1 | sed -E 's/.*"(.*)".*/\1/')"

# ---------------------------------------------------------------------------
# Local dev-binary swap (no release needed).
#
# Point the installed `atdd` at the locally-built v2 dev binary via a SYMLINK,
# so the `lsp`/`stack` verbs are available WITHOUT cutting a snapshot/prerelease,
# and so future `cargo build --release` rebuilds are live immediately.
#
# Safe vs skills/ensure-atdd.sh: that script only re-downloads when skills/VERSION
# contains a `-` (snapshot) OR the installed `--version` differs from skills/VERSION.
# The dev binary's version must equal skills/VERSION (both 1.1.2 today) so the
# bootstrap stays a no-op and the swap survives every entry-skill run. If you bump
# one, bump the other (make set-version) or ensure-atdd.sh will overwrite the swap.
#
#   make use-dev-atdd       # symlink installed atdd -> dev build (backs up the real one)
#   make use-release-atdd   # restore the real release binary (or re-download it)
#   make build-dev-atdd     # cargo build --release in the sibling atdd-cli
#   make atdd-status        # show which atdd is active + versions
# ---------------------------------------------------------------------------

build-dev-atdd:
	@cd "$(ATDD_CLI)" && cargo build --release
	echo "built: $(DEV_ATDD)"

use-dev-atdd:
	@dev="$(DEV_ATDD)"
	if [ ! -x "$$dev" ]; then
	  echo "error: dev binary not found/executable: $$dev" >&2
	  echo "  build it first:  make build-dev-atdd   (or: cd $(ATDD_CLI) && cargo build --release)" >&2
	  exit 1
	fi
	if ! "$$dev" lsp --help >/dev/null 2>&1; then
	  echo "error: $$dev has no 'lsp' verb — is this really the v2 build?" >&2; exit 1
	fi
	ver="$$(tr -d '[:space:]' < "$(VERSION_FILE)")"
	case "$$ver" in
	  *-*) echo "WARNING: skills/VERSION='$$ver' is a snapshot — ensure-atdd.sh will re-download and OVERWRITE this swap on the next bootstrap. Use a plain X.Y.Z to keep it." >&2 ;;
	esac
	installed="$$(command -v atdd || true)"
	[ -n "$$installed" ] || installed="$(ATDD_INSTALL_DIR)/atdd"
	mkdir -p "$$(dirname "$$installed")"
	if [ -e "$$installed" ] && [ ! -L "$$installed" ]; then
	  if [ ! -e "$$installed.release-backup" ]; then
	    mv "$$installed" "$$installed.release-backup"
	    echo "backed up release binary -> $$installed.release-backup"
	  else
	    rm -f "$$installed"
	  fi
	fi
	ln -sf "$$dev" "$$installed"
	echo "swapped: $$installed -> $$dev"
	echo "  version : $$("$$installed" --version 2>&1)"
	echo "  lsp verb: $$("$$installed" lsp --help >/dev/null 2>&1 && echo present || echo MISSING)"
	echo "Dev rebuilds are now live automatically (symlink). Restore with: make use-release-atdd"

use-release-atdd:
	@installed="$$(command -v atdd || true)"
	[ -n "$$installed" ] || installed="$(ATDD_INSTALL_DIR)/atdd"
	if [ -e "$$installed.release-backup" ]; then
	  rm -f "$$installed"
	  mv "$$installed.release-backup" "$$installed"
	  echo "restored release binary: $$installed ($$("$$installed" --version 2>&1))"
	else
	  if [ -L "$$installed" ]; then rm -f "$$installed"; fi
	  echo "no backup found — re-downloading the release binary via ensure-atdd.sh"
	  bash "$(CURDIR)/skills/ensure-atdd.sh"
	fi

atdd-status:
	@installed="$$(command -v atdd || true)"
	[ -n "$$installed" ] || installed="$(ATDD_INSTALL_DIR)/atdd"
	echo "installed atdd : $$installed"
	if [ -L "$$installed" ]; then
	  echo "  kind         : symlink -> $$(readlink "$$installed")"
	elif [ -e "$$installed" ]; then
	  echo "  kind         : real file"
	else
	  echo "  kind         : (not present)"
	fi
	if [ -e "$$installed" ]; then
	  echo "  version      : $$("$$installed" --version 2>&1)"
	  echo "  has lsp verb : $$("$$installed" lsp --help >/dev/null 2>&1 && echo yes || echo no)"
	fi
	[ -e "$$installed.release-backup" ] && echo "  backup       : $$installed.release-backup" || true
	echo "dev build      : $(DEV_ATDD)"
	if [ -x "$(DEV_ATDD)" ]; then echo "  version      : $$("$(DEV_ATDD)" --version 2>&1)"; fi
	echo "skills/VERSION : $$(tr -d '[:space:]' < "$(VERSION_FILE)")"

# ---------------------------------------------------------------------------
# Dev-plugin swap: sync this repo into the installed OpenCode plugin path.
#
# Only the files that npm publishes are synced (matching package.json "files"):
#   index.js, skills/, .claude-plugin/, .codex-plugin/, package.json, README.md
#
#   make use-dev-plugin     # rsync repo -> installed plugin (npm files only)
#   make restore-plugin     # print the command to re-install from npm
# ---------------------------------------------------------------------------

use-dev-plugin:
	@if [ ! -d "$(OPENCODE_PLUGIN)" ]; then
	  echo "error: installed plugin not found: $(OPENCODE_PLUGIN)" >&2
	  echo "  install it first:  opencode install @positivegrid/agent-tdd" >&2
	  exit 1
	fi
	rsync -av --delete \
	  --include='index.js' \
	  --include='skills/' --include='skills/**' \
	  --include='.claude-plugin/' --include='.claude-plugin/**' \
	  --include='.codex-plugin/' --include='.codex-plugin/**' \
	  --include='package.json' \
	  --include='README.md' \
	  --exclude='*' \
	  ./ "$(OPENCODE_PLUGIN)/"
	@echo "synced: $(CURDIR) -> $(OPENCODE_PLUGIN)"

restore-plugin:
	@echo "Re-install the published package to restore:"
	@echo "  opencode install @positivegrid/agent-tdd@latest"

# ---------------------------------------------------------------------------
# Deep Code skill sync: symlink every skill directory into ~/.agents/skills/
# so Deep Code discovers them. Idempotent — re-running fixes broken links,
# skips existing ones that are already correct.
#
#   make sync-deepcode-skills
#
# After this, configure Deep Code env vars in ~/.deepcode/settings.json:
#   "CLAUDE_SKILL_DIR": "<repo-root>/skills/atdd",
#   "AGENT_TDD_CLI":    "deepcode"
# ---------------------------------------------------------------------------

DEEPCODE_SKILLS_DIR := $(HOME)/.agents/skills
SKILL_DIRS := atdd atdd-compact atdd-feature atdd-fix atdd-from-issue atdd-plan

sync-deepcode-skills:
	@mkdir -p "$(DEEPCODE_SKILLS_DIR)"
	@added=0; skipped=0; fixed=0
	@for d in $(SKILL_DIRS); do \
	  src="$(CURDIR)/skills/$$d"; \
	  dst="$(DEEPCODE_SKILLS_DIR)/$$d"; \
	  if [ -L "$$dst" ]; then \
	    cur="$$(readlink "$$dst")"; \
	    if [ "$$cur" = "$$src" ]; then \
	      skipped=$$((skipped + 1)); \
	      printf '  skip  %s -> %s (already correct)\n' "$$dst" "$$src"; \
	    else \
	      rm -f "$$dst"; \
	      ln -s "$$src" "$$dst"; \
	      fixed=$$((fixed + 1)); \
	      printf '  fixed %s -> %s (was %s)\n' "$$dst" "$$src" "$$cur"; \
	    fi; \
	  elif [ -e "$$dst" ]; then \
	    printf '  WARN  %s exists but is not a symlink — skipping (remove it first)\n' "$$dst"; \
	  else \
	    ln -s "$$src" "$$dst"; \
	    added=$$((added + 1)); \
	    printf '  add   %s -> %s\n' "$$dst" "$$src"; \
	  fi; \
	done; \
	printf '\n%s added, %s skipped, %s fixed\n' "$$added" "$$skipped" "$$fixed"
