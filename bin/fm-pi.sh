#!/usr/bin/env bash
# fm-pi.sh - launch Pi for this firstmate home against an isolated Pi profile.
#
# Usage:
#   bin/fm-pi.sh [pi arguments...]
#
# Resolves the firstmate repository root from this script's own location, points
# PI_CODING_AGENT_DIR at <root>/data/pi-agent, changes to that root, and execs pi
# with every caller argument unchanged. The captain's ordinary Pi profile is never
# read, written, or pointed at, so packages, credentials, trust decisions, model
# defaults, caches, and sessions all stay private to this home. data/ is
# gitignored, so the profile never becomes tracked content.
#
# bin/fm-pi.ps1 is the Windows PowerShell counterpart and must stay behaviorally
# identical. docs/isolated-pi-setup.md owns prerequisites, authentication, project
# trust, and the isolation verification checklist for both platforms.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_AGENT_DIR="$ROOT/data/pi-agent"

if ! command -v pi >/dev/null 2>&1; then
  printf 'fm-pi.sh: pi not found on PATH; install Pi first (see docs/isolated-pi-setup.md).\n' >&2
  exit 127
fi

# Git Bash and other MSYS-derived shells need native symlink creation for the
# repository's tracked symlinks. The setting is meaningless elsewhere, so it is
# applied only where a Windows shell actually consumes it.
case "$(uname -s 2>/dev/null || printf 'unknown')" in
  MINGW*|MSYS*|CYGWIN*) export MSYS=winsymlinks:nativestrict ;;
esac

mkdir -p "$PI_AGENT_DIR" || {
  printf 'fm-pi.sh: cannot create the isolated Pi profile directory: %s\n' "$PI_AGENT_DIR" >&2
  exit 1
}

export PI_CODING_AGENT_DIR="$PI_AGENT_DIR"
cd "$ROOT" || exit 1

# Branch on the empty argument list rather than relying on "$@" under `set -u`:
# Bash builds older than 4.4, including the stock macOS 3.2 shell this repository
# stays compatible with, can treat an empty "$@" as an unbound variable.
if [ "$#" -eq 0 ]; then
  exec pi
fi
exec pi "$@"
