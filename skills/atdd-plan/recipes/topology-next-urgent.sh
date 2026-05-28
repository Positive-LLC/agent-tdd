#!/usr/bin/env bash
# topology-next-urgent.sh — emit the single most-urgent open RootIssue.
#
# "Most urgent" = first item of topology-available (highest transitive
# blocking-count; oldest as tie-break). Emits a JSON array of length 0 or 1.
#
# Usage:  topology-next-urgent.sh

set -euo pipefail

die() { printf '[topology-next-urgent] ERROR: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/topology-available.sh" | jq '.[0:1]'
