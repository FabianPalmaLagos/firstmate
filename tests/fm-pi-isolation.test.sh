#!/usr/bin/env bash
# Isolation-boundary tests for the cross-platform Pi launchers, bin/fm-pi.sh and
# bin/fm-pi.ps1, plus the package-free tracked project settings they rely on.
#
# These never launch a real Pi session: a real launch writes authentication,
# trust, and session state into the profile under test. The POSIX launcher is
# exercised behaviorally against a copy in a throwaway root with a fake `pi` on
# PATH, and the PowerShell launcher, which is outside ShellCheck's and this
# runner's execution scope, is asserted statically against the same boundary.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SH_LAUNCHER="$ROOT/bin/fm-pi.sh"
PS_LAUNCHER="$ROOT/bin/fm-pi.ps1"
SETTINGS="$ROOT/.pi/settings.json"
INVENTORY="$ROOT/docs/documentation-audiences.json"
SETUP_DOC="docs/isolated-pi-setup.md"

TMP_ROOT=$(fm_test_tmproot fm-pi-isolation)

# Build a throwaway firstmate root containing only the launcher, so a passing
# root resolution proves the script located itself rather than reading the
# caller's working directory or the real repository.
fake_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/bin"
  cp "$SH_LAUNCHER" "$home/bin/fm-pi.sh"
  chmod +x "$home/bin/fm-pi.sh"
  printf '%s\n' "$home"
}

# A fake `pi` that records the environment, working directory, and arguments it
# was handed, then exits with a distinctive status the launcher must forward.
fake_pi_bin() {
  local bin="$TMP_ROOT/$1"
  mkdir -p "$bin"
  cat > "$bin/pi" <<'SH'
#!/usr/bin/env bash
{
  printf 'dir=%s\n' "${PI_CODING_AGENT_DIR:-unset}"
  printf 'cwd=%s\n' "$(pwd)"
  printf 'argc=%s\n' "$#"
  for arg in "$@"; do printf 'arg=%s\n' "$arg"; done
} > "$FM_FAKE_PI_LOG"
exit 41
SH
  chmod +x "$bin/pi"
  printf '%s\n' "$bin"
}

# The caller's PATH with every directory that provides a `pi` executable
# removed. Dropping only those entries keeps the ordinary system tools the
# launcher itself needs, so the refusal is proven to come from the missing `pi`
# rather than from an environment stripped bare.
path_without_pi() {
  local dir stripped='' IFS=:
  for dir in $PATH; do
    [ -n "$dir" ] || continue
    case "$dir" in
      *"$TMP_ROOT"*) continue ;;
    esac
    if [ -x "$dir/pi" ] || [ -x "$dir/pi.exe" ] || [ -x "$dir/pi.cmd" ] || [ -x "$dir/pi.bat" ]; then
      continue
    fi
    stripped="${stripped:+$stripped:}$dir"
  done
  printf '%s\n' "$stripped"
}

test_launchers_exist_and_are_paired() {
  assert_present "$SH_LAUNCHER" "bin/fm-pi.sh is missing"
  assert_present "$PS_LAUNCHER" "bin/fm-pi.ps1 is missing"
  [ -x "$SH_LAUNCHER" ] || fail "bin/fm-pi.sh must be executable"
  assert_grep 'bin/fm-pi.ps1' "$SH_LAUNCHER" "bin/fm-pi.sh must name its Windows counterpart"
  assert_grep 'bin/fm-pi.sh' "$PS_LAUNCHER" "bin/fm-pi.ps1 must name its POSIX counterpart"
  pass "both launchers ship and cross-reference each other"
}

test_root_is_resolved_from_script_location() {
  assert_grep 'BASH_SOURCE[0]' "$SH_LAUNCHER" \
    "bin/fm-pi.sh must resolve its root from its own location"
  assert_grep '$PSScriptRoot' "$PS_LAUNCHER" \
    "bin/fm-pi.ps1 must resolve its root from its own location"
  assert_no_grep 'Get-Location' "$PS_LAUNCHER" \
    "bin/fm-pi.ps1 must not derive its root from the caller's working directory"
  pass "both launchers resolve the repository root from the script's own location"
}

test_profile_points_under_the_resolved_root() {
  assert_grep 'PI_AGENT_DIR="$ROOT/data/pi-agent"' "$SH_LAUNCHER" \
    "bin/fm-pi.sh must place the profile under the resolved root's data/"
  assert_grep 'export PI_CODING_AGENT_DIR="$PI_AGENT_DIR"' "$SH_LAUNCHER" \
    "bin/fm-pi.sh must export PI_CODING_AGENT_DIR"
  assert_grep "Join-Path \$repoRoot 'data/pi-agent'" "$PS_LAUNCHER" \
    "bin/fm-pi.ps1 must place the profile under the resolved root's data/"
  assert_grep '$env:PI_CODING_AGENT_DIR = $piAgentDir' "$PS_LAUNCHER" \
    "bin/fm-pi.ps1 must set PI_CODING_AGENT_DIR"
  pass "both launchers point PI_CODING_AGENT_DIR at <root>/data/pi-agent"
}

test_no_launcher_references_the_global_profile() {
  local launcher needle
  for launcher in "$SH_LAUNCHER" "$PS_LAUNCHER"; do
    for needle in '.pi/agent' '.pi\agent' '/.pi' 'USERPROFILE' 'HOMEPATH' '$HOME'; do
      assert_no_grep "$needle" "$launcher" \
        "$(basename "$launcher") must never reference the global Pi profile ($needle)"
    done
  done
  pass "neither launcher reads, writes, or points at the global Pi profile"
}

test_arguments_are_forwarded_unchanged() {
  assert_grep 'exec pi "$@"' "$SH_LAUNCHER" \
    "bin/fm-pi.sh must forward every caller argument to pi"
  assert_grep '& pi @args' "$PS_LAUNCHER" \
    "bin/fm-pi.ps1 must forward every caller argument to pi"
  assert_grep 'exit $LASTEXITCODE' "$PS_LAUNCHER" \
    "bin/fm-pi.ps1 must forward pi's own exit status"
  pass "both launchers forward arguments and pi's exit status"
}

test_posix_launcher_isolates_and_forwards_at_runtime() {
  local home bin log rc out
  home=$(fake_home posix-run)
  bin=$(fake_pi_bin posix-run-bin)
  log="$TMP_ROOT/posix-run.log"

  set +e
  (
    cd "$TMP_ROOT" || exit 1
    FM_FAKE_PI_LOG="$log" PATH="$bin:$PATH" "$home/bin/fm-pi.sh" \
      --provider openai-codex "two words"
  )
  rc=$?
  set -e
  expect_code 41 "$rc" "bin/fm-pi.sh must exit with pi's own status"

  out=$(cat "$log")
  assert_contains "$out" "dir=$home/data/pi-agent" \
    "launcher pointed PI_CODING_AGENT_DIR outside its own root"
  assert_contains "$out" "cwd=$home" \
    "launcher must run pi from the resolved repository root"
  assert_contains "$out" "argc=3" "launcher altered the argument count"
  assert_contains "$out" "arg=--provider" "launcher dropped a flag argument"
  assert_contains "$out" "arg=two words" "launcher split an argument containing a space"
  assert_present "$home/data/pi-agent" "launcher did not create the isolated profile directory"
  pass "bin/fm-pi.sh isolates the profile, runs from its own root, and forwards arguments verbatim"
}

test_posix_launcher_accepts_no_arguments() {
  local home bin log rc
  home=$(fake_home posix-noargs)
  bin=$(fake_pi_bin posix-noargs-bin)
  log="$TMP_ROOT/posix-noargs.log"

  set +e
  (
    cd "$TMP_ROOT" || exit 1
    FM_FAKE_PI_LOG="$log" PATH="$bin:$PATH" "$home/bin/fm-pi.sh"
  )
  rc=$?
  set -e
  expect_code 41 "$rc" "bin/fm-pi.sh must launch pi with no arguments"
  assert_grep 'argc=0' "$log" "no-argument launch must reach pi with an empty argument list"
  pass "bin/fm-pi.sh launches cleanly with no arguments under set -u"
}

test_posix_launcher_refuses_without_pi() {
  local home stripped rc out
  home=$(fake_home posix-nopi)
  stripped=$(path_without_pi)
  PATH="$stripped" command -v dirname >/dev/null 2>&1 \
    || fail "cannot build a pi-free PATH that still provides the launcher's own tools"
  ! PATH="$stripped" command -v pi >/dev/null 2>&1 \
    || fail "pi is still resolvable after stripping its PATH entries"

  set +e
  out=$(
    cd "$TMP_ROOT" || exit 1
    PATH="$stripped" "$home/bin/fm-pi.sh" 2>&1
  )
  rc=$?
  set -e
  expect_code 127 "$rc" "a missing pi must stop the launcher"
  assert_contains "$out" "pi not found on PATH" \
    "the missing-pi failure must say what is missing"
  assert_absent "$home/data/pi-agent" \
    "the launcher must not create a profile when it cannot launch pi"
  pass "bin/fm-pi.sh reports a missing pi and stops instead of launching something else"
}

test_project_settings_declare_no_packages() {
  assert_present "$SETTINGS" ".pi/settings.json must be tracked project settings"
  git -C "$ROOT" ls-files --error-unmatch .pi/settings.json >/dev/null 2>&1 \
    || fail ".pi/settings.json must be tracked so every teammate shares the same baseline"
  assert_no_grep 'npm:' "$SETTINGS" ".pi/settings.json must declare no npm package source"
  assert_no_grep 'autoload' "$SETTINGS" \
    ".pi/settings.json must not carry a package delta over an inherited global package"
  assert_grep '"packages": []' "$SETTINGS" \
    ".pi/settings.json must declare an explicitly empty package list"
  pass "tracked project settings are package-free"
}

test_setup_documentation_is_classified_and_routed() {
  assert_present "$ROOT/$SETUP_DOC" "the isolated Pi setup guide is missing"
  python3 - "$INVENTORY" "$SETUP_DOC" <<'PY' \
    || fail "the setup guide must be a classified operator-current README setup target"
import json
import sys

inventory_path, doc = sys.argv[1:3]
with open(inventory_path, encoding="utf-8") as handle:
    data = json.load(handle)
classified = {entry["path"]: entry["audience"] for entry in data["surfaces"]}
assert classified.get(doc) == "operator-current", f"audience is {classified.get(doc)!r}"
assert doc in data["readmeSetupTargets"], "not registered as a README setup target"
assert classified[doc] in data["setupAudiences"], "setup target has a non-setup audience"
PY
  assert_grep "$SETUP_DOC" "$ROOT/README.md" \
    "README.md must route teammates to the setup guide"
  pass "the setup guide is classified, routed through README, and machine-checked"
}

test_launchers_exist_and_are_paired
test_root_is_resolved_from_script_location
test_profile_points_under_the_resolved_root
test_no_launcher_references_the_global_profile
test_arguments_are_forwarded_unchanged
test_posix_launcher_isolates_and_forwards_at_runtime
test_posix_launcher_accepts_no_arguments
test_posix_launcher_refuses_without_pi
test_project_settings_declare_no_packages
test_setup_documentation_is_classified_and_routed
