#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# MSYS Bash cannot see its native Pi parent through ps or kill. Query the native
# process table with one shared PowerShell program so both ownership and liveness
# require the same exact Pi process shape.
fm_pi_windows_process_pid() {
  local pid=$1 result
  case "$pid" in ''|*[!0-9]*|0) return 1 ;; esac
  command -v powershell.exe >/dev/null 2>&1 || return 1
  result=$(FM_PI_PROCESS_PID=$pid powershell.exe -NoProfile -NonInteractive -Command - 2>/dev/null <<'POWERSHELL'
$targetPid = [int]$env:FM_PI_PROCESS_PID
$p = Get-CimInstance Win32_Process -Filter "ProcessId = $targetPid" -ErrorAction SilentlyContinue
$nodePattern = '(^|[\s\\/\"])@earendil-works[\\/]pi-coding-agent[\\/]dist[\\/]cli\.js([\s\"]|$)'
$matched = if ($p -and (($p.Name -ieq 'pi.exe') -or (($p.Name -ieq 'node.exe') -and $p.CommandLine -match $nodePattern))) { $p.ProcessId } else { '' }
Write-Output "pid:$matched"
POWERSHELL
) || return 1
  [ "$result" = "pid:$pid" ] || return 1
  printf '%s\n' "$pid"
}

# Pi's session_start handler binds these inherited values to its own process and
# exact session id. Do not accept them from Unix, Claude, or another harness.
fm_pi_windows_session_pid() {
  local pid
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) ;; *) return 1 ;; esac
  [ "${PI_CODING_AGENT:-}" = true ] || return 1
  [ -z "${CLAUDECODE:-}" ] || return 1
  [ -n "${PI_SESSION_ID:-}" ] && [ "$PI_SESSION_ID" = "${FM_PI_SESSION_ID:-}" ] || return 1
  pid=${FM_PI_PROCESS_PID:-}
  fm_pi_windows_process_pid "$pid"
}

# True if a native Windows Pi process is live. This deliberately does not use the
# bound session id: a different live Pi session must still keep its existing lock.
fm_pi_windows_pid_alive() {
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) ;; *) return 1 ;; esac
  fm_pi_windows_process_pid "$1" >/dev/null
}

# MSYS/Git-Bash's ps has no -o custom-format support and its ppid chain does
# not cross the boundary from a native Windows parent into a Cygwin-tracked
# child, so the generic ancestry walk below never finds Claude's host process
# either; query the native Windows process table the same way as Pi above.
fm_claude_windows_process_pid() {
  local pid=$1 result
  case "$pid" in ''|*[!0-9]*|0) return 1 ;; esac
  command -v powershell.exe >/dev/null 2>&1 || return 1
  result=$(FM_CLAUDE_PROCESS_PID=$pid powershell.exe -NoProfile -NonInteractive -Command - 2>/dev/null <<'POWERSHELL'
$targetPid = [int]$env:FM_CLAUDE_PROCESS_PID
$p = Get-CimInstance Win32_Process -Filter "ProcessId = $targetPid" -ErrorAction SilentlyContinue
$matched = if ($p -and ($p.Name -ieq 'claude.exe')) { $p.ProcessId } else { '' }
Write-Output "pid:$matched"
POWERSHELL
) || return 1
  [ "$result" = "pid:$pid" ] || return 1
  printf '%s\n' "$pid"
}

# Claude Code sets CLAUDECODE=1 and CLAUDE_PID (its native host process's real
# Windows pid) on every process it spawns. Unlike Pi's markers, these are the
# live harness's own inherited environment, not a value read back from a disk
# marker, so no separate session-id cross-check is needed to guard against a
# stale binding.
fm_claude_windows_session_pid() {
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) ;; *) return 1 ;; esac
  [ "${CLAUDECODE:-}" = "1" ] || return 1
  fm_claude_windows_process_pid "${CLAUDE_PID:-}"
}

# True if a native Windows Claude Code host process is live. Mirrors
# fm_pi_windows_pid_alive: checks the literal target pid, not the caller's own
# identity, so a different live Claude session's lock is still preserved.
fm_claude_windows_pid_alive() {
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) ;; *) return 1 ;; esac
  fm_claude_windows_process_pid "$1" >/dev/null
}

# Walk the current process ancestry (up to 8 hops) and print the first pid whose
# command looks like a verified harness. The harness pid lives as long as the
# session, unlike the transient subshell pid of any one tool call.
fm_harness_ancestry_pid() {
  fm_pi_windows_session_pid && return 0
  fm_claude_windows_session_pid && return 0
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$FM_HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$FM_HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  fm_pi_windows_pid_alive "$pid" && return 0
  fm_claude_windows_pid_alive "$pid" && return 0
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  if printf '%s' "$(basename "$comm")" | grep -qE "$FM_HARNESS_RE"; then
    return 0
  fi
  case "$comm" in
    *node*|*python*)
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"
      ;;
    *) return 1 ;;
  esac
}

# True when state dir $1 holds a session lock whose pid is the harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. A missing lock, a lock held by another live harness, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid my_pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  my_pid=$(fm_harness_ancestry_pid) || return 1
  [ "$my_pid" = "$lock_pid" ]
}
