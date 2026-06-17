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

.PHONY: help set-version show-version

help:
	@echo "make set-version VERSION=X.Y.Z   set the version in all 5 files (lockstep)"
	@echo "make show-version                show the version each file holds"

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
