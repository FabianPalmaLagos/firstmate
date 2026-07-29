# fm-pi.ps1 - launch Pi for this firstmate home against an isolated Pi profile.
#
# Usage:
#   .\bin\fm-pi.ps1 [pi arguments...]
#   powershell -ExecutionPolicy Bypass -File bin\fm-pi.ps1 [pi arguments...]
#
# Resolves the firstmate repository root from this script's own location, points
# PI_CODING_AGENT_DIR at <root>/data/pi-agent, changes to that root, and runs pi
# with every caller argument unchanged. The captain's ordinary Pi profile is never
# read, written, or pointed at, so packages, credentials, trust decisions, model
# defaults, caches, and sessions all stay private to this home. data/ is
# gitignored, so the profile never becomes tracked content.
#
# bin/fm-pi.sh is the macOS and POSIX counterpart and must stay behaviorally
# identical. docs/isolated-pi-setup.md owns prerequisites, authentication, project
# trust, and the isolation verification checklist for both platforms.
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$piAgentDir = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'data/pi-agent'))

if (-not (Get-Command pi -ErrorAction SilentlyContinue)) {
  [Console]::Error.WriteLine('fm-pi.ps1: pi not found on PATH; install Pi first (see docs/isolated-pi-setup.md).')
  exit 127
}

# Native symlink creation for the repository's tracked symlinks, matching the
# MSYS-shell branch in bin/fm-pi.sh.
$env:MSYS = 'winsymlinks:nativestrict'

New-Item -ItemType Directory -Force -Path $piAgentDir | Out-Null

$env:PI_CODING_AGENT_DIR = $piAgentDir
Set-Location $repoRoot

# Pi's own non-zero exit is an ordinary result to forward, not a terminating
# error, so the strict preference above is released before handing off.
$ErrorActionPreference = 'Continue'
& pi @args
exit $LASTEXITCODE
