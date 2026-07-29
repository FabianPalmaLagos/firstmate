#!/usr/bin/env bash
# tests/fm-spawn-herdr-readiness.test.sh - deterministic fm-spawn coverage for
# Herdr's two execution-acknowledged shell-readiness boundaries, one-line launch
# handoff, and bounded abort cleanup.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-readiness)
export FM_GATE_REFUSE_BYPASS=1

make_fakebin() {  # <dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb" "$dir/herdr-state"
  : > "$dir/herdr.log"
  : > "$dir/treehouse.log"
  printf '0\n' > "$dir/herdr-state/workspace"
  printf '0\n' > "$dir/herdr-state/task"
  printf '0\n' > "$dir/herdr-state/seeded"
  printf '0\n' > "$dir/herdr-state/ready-acks"
  printf '0\n' > "$dir/herdr-state/launched"
  printf '0\n' > "$dir/herdr-state/pane-get-count"
  : > "$dir/herdr-state/output"
  printf '%s\n' "$FM_FAKE_PROJECT" > "$dir/herdr-state/cwd"

  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_FAKE_HERDR_STATE:?}
log=${FM_FAKE_HERDR_LOG:?}
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for arg in "$@"; do printf '\x1f%s' "$arg"; done
  printf '\n'
} >> "$log"

cmd=${1:-}; sub=${2:-}
case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.7.5","protocol":17},"server":{"running":true}}\n'
    exit 0
    ;;
  "workspace list")
    if [ "$(cat "$state/workspace")" = 1 ]; then
      printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}\n'
    else
      printf '{"result":{"workspaces":[]}}\n'
    fi
    exit 0
    ;;
  "workspace create")
    printf '1\n' > "$state/workspace"
    printf '1\n' > "$state/seeded"
    printf '{"result":{"workspace":{"workspace_id":"w1"},"tab":{"tab_id":"w1:t1"},"root_pane":{"pane_id":"w1:p1"}}}\n'
    exit 0
    ;;
  "tab list")
    tabs=
    if [ "$(cat "$state/seeded")" = 1 ]; then
      tabs='{"tab_id":"w1:t1","label":"1","workspace_id":"w1"}'
    fi
    if [ "$(cat "$state/task")" = 1 ]; then
      [ -z "$tabs" ] || tabs="$tabs,"
      tabs="${tabs}{\"tab_id\":\"w1:t2\",\"label\":\"fm-${FM_FAKE_ID}\",\"workspace_id\":\"w1\"}"
    fi
    printf '{"result":{"tabs":[%s]}}\n' "$tabs"
    exit 0
    ;;
  "tab create")
    printf '1\n' > "$state/task"
    printf '%s\n' "$FM_FAKE_PROJECT" > "$state/cwd"
    printf '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}\n'
    exit 0
    ;;
  "pane list")
    panes=
    if [ "$(cat "$state/seeded")" = 1 ]; then
      panes='{"pane_id":"w1:p1","tab_id":"w1:t1"}'
    fi
    if [ "$(cat "$state/task")" = 1 ]; then
      [ -z "$panes" ] || panes="$panes,"
      panes="${panes}{\"pane_id\":\"w1:p2\",\"tab_id\":\"w1:t2\"}"
    fi
    printf '{"result":{"panes":[%s]}}\n' "$panes"
    exit 0
    ;;
  "pane process-info")
    pane=${4:-}
    [ "$pane" = w1:p2 ] && [ "$(cat "$state/task")" = 1 ] || exit 1
    cwd=$(cat "$state/cwd")
    if [ "$(cat "$state/launched")" = 1 ]; then
      if [ "${FM_FAKE_HANDOFF_MODE:-raw}" = pi ]; then
        printf '{"result":{"process_info":{"foreground_processes":[{"pid":20,"name":"node","cmdline":"node /opt/pi --thinking xhigh","cwd":"%s"}]}}}\n' "$cwd"
      elif [ "${FM_FAKE_HANDOFF_MODE:-raw}" = wrong-agent ]; then
        printf '{"result":{"process_info":{"foreground_processes":[{"pid":20,"name":"node","cmdline":"node /opt/pi --thinking xhigh","cwd":"%s"}]}}}\n' "$cwd"
      else
        printf '{"result":{"process_info":{"foreground_processes":[{"pid":20,"name":"sh","cmdline":"sh -c fixture","cwd":"%s"}]}}}\n' "$cwd"
      fi
    else
      printf '{"result":{"process_info":{"foreground_processes":[{"pid":10,"name":"zsh","cmdline":"-zsh","cwd":"%s"}]}}}\n' "$cwd"
    fi
    exit 0
    ;;
  "pane run")
    pane=${3:-}; line=${4:-}
    [ "$pane" = w1:p2 ] || exit 1
    case "$line" in
      *"__fm_ready_"*)
        count=$(( $(cat "$state/ready-acks") + 1 ))
        printf '%s\n' "$count" > "$state/ready-acks"
        limit=${FM_FAKE_READY_ACK_LIMIT:-2}
        if [ "$count" -le "$limit" ]; then
          token=$(printf '%s' "$line" | grep -Eo '__fm_ready_[A-Za-z0-9_]+__' | head -1)
          [ -z "$token" ] || printf '%s\n' "$token" >> "$state/output"
        fi
        ;;
      "treehouse get")
        printf '%s\n' "$FM_FAKE_WORKTREE" > "$state/cwd"
        ;;
      *"__fm_launch_"*)
        token=$(printf '%s' "$line" | grep -Eo '__fm_launch_[A-Za-z0-9_]+__' | head -1)
        [ -z "$token" ] || printf '%s\n' "$token" >> "$state/output"
        [ "${FM_FAKE_HANDOFF_MODE:-raw}" = none ] || printf '1\n' > "$state/launched"
        ;;
    esac
    exit 0
    ;;
  "pane read")
    cat "$state/output"
    exit 0
    ;;
  "pane get")
    pane=${3:-}
    if [ "$pane" != w1:p2 ] || [ "$(cat "$state/task")" != 1 ]; then
      if [ "${FM_FAKE_PANE_PROBE_UNKNOWN:-0}" = 1 ]; then
        printf '{"error":{"code":"internal_error"}}\n' >&2
      else
        printf '{"error":{"code":"pane_not_found"}}\n' >&2
      fi
      exit 1
    fi
    cwd=$(cat "$state/cwd")
    if [ "$cwd" = "$FM_FAKE_WORKTREE" ]; then
      count=$(( $(cat "$state/pane-get-count") + 1 ))
      printf '%s\n' "$count" > "$state/pane-get-count"
      if [ "${FM_FAKE_CWD_FAIL_AFTER:-0}" -gt 0 ] && [ "$count" -gt "$FM_FAKE_CWD_FAIL_AFTER" ]; then
        printf '{"error":{"code":"internal_error"}}\n' >&2
        exit 1
      elif [ "$count" -le "${FM_FAKE_TRANSIENT_CWD_READS:-0}" ]; then
        cwd=${FM_FAKE_TRANSIENT_CWD:-/}
      fi
    fi
    printf '{"result":{"pane":{"pane_id":"w1:p2","foreground_cwd":"%s"}}}\n' "$cwd"
    exit 0
    ;;
  "agent get")
    pane=${3:-}
    if [ "$pane" = w1:p2 ] && [ "$(cat "$state/launched")" = 1 ] && [ "${FM_FAKE_HANDOFF_MODE:-raw}" = pi ]; then
      printf '{"result":{"agent":{"agent":"pi","agent_status":"working"}}}\n'
    elif [ "$pane" = w1:p2 ] && [ "$(cat "$state/launched")" = 1 ] && [ "${FM_FAKE_HANDOFF_MODE:-raw}" = wrong-agent ]; then
      printf '{"result":{"agent":{"agent":"claude","agent_status":"working"}}}\n'
    else
      printf '{"error":{"code":"agent_not_found"}}\n'
    fi
    exit 0
    ;;
  "pane close")
    pane=${3:-}
    case "$pane" in
      w1:p1) printf '0\n' > "$state/seeded" ;;
      w1:p2) printf '0\n' > "$state/task" ;;
    esac
    exit 0
    ;;
  "tab close")
    [ "${3:-}" = w1:t1 ] && printf '0\n' > "$state/seeded"
    exit 0
    ;;
esac
exit 0
SH

  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:?}"
if [ "${FM_FAKE_TREEHOUSE_RETURN_FAIL:-0}" = 1 ]; then
  exit 1
fi
touch "${FM_FAKE_TREEHOUSE_RETURNED:?}"
exit 0
SH
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/herdr" "$fb/treehouse" "$fb/sleep"
  printf '%s\n' "$fb"
}

make_fixture() {  # <name>
  FIXTURE="$TMP_ROOT/$1"
  PROJECT="$FIXTURE/project"
  WORKTREE="$FIXTURE/worktree"
  STATE="$FIXTURE/home/state"
  DATA="$FIXTURE/home/data"
  CONFIG="$FIXTURE/home/config"
  ID="$1"
  mkdir -p "$PROJECT" "$STATE" "$DATA/$ID" "$CONFIG"
  git -C "$PROJECT" init -q
  printf 'fixture\n' > "$PROJECT/file.txt"
  git -C "$PROJECT" add file.txt
  git -C "$PROJECT" commit -qm fixture
  git -C "$PROJECT" worktree add -q --detach "$WORKTREE"
  printf 'readiness fixture\n' > "$DATA/$ID/brief.md"
  export FM_FAKE_PROJECT="$PROJECT" FM_FAKE_WORKTREE="$WORKTREE" FM_FAKE_ID="$ID"
  export FM_FAKE_HERDR_STATE="$FIXTURE/herdr-state" FM_FAKE_HERDR_LOG="$FIXTURE/herdr.log"
  export FM_FAKE_TREEHOUSE_LOG="$FIXTURE/treehouse.log" FM_FAKE_TREEHOUSE_RETURNED="$FIXTURE/treehouse-returned"
  FAKEBIN=$(make_fakebin "$FIXTURE")
}

make_unrelated_checkout() {
  UNRELATED="$FIXTURE/unrelated"
  mkdir -p "$UNRELATED"
  git -C "$UNRELATED" init -q
  printf 'unrelated\n' > "$UNRELATED/file.txt"
  git -C "$UNRELATED" add file.txt
  git -C "$UNRELATED" commit -qm unrelated
}

run_spawn() {  # <raw-launch-or-harness>
  local launch=$1
  shift
  env -u TMUX PATH="$FAKEBIN:$PATH" HERDR_ENV=1 HERDR_SESSION=fmtest \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_PROJECTS_OVERRIDE="$FIXTURE/unused-projects" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND_HERDR_READY_POLLS=2 \
    FM_BACKEND_HERDR_READY_STABLE_POLLS=2 FM_BACKEND_HERDR_READY_POLL_SLEEP=0 \
    FM_BACKEND_HERDR_HANDOFF_POLLS=2 "$@" \
    "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" "$launch" --backend herdr --scout
}

test_success_uses_two_readiness_acks_and_one_launch_line() {
  local ready1 tree ready2 launch log out
  make_fixture readiness-success
  out=$(FM_FAKE_READY_ACK_LIMIT=2 FM_FAKE_HANDOFF_MODE=raw FM_FAKE_TRANSIENT_CWD_READS=1 run_spawn "sh -c 'echo ok'") \
    || fail "Herdr readiness success fixture failed: $out"
  log=$(cat "$FIXTURE/herdr.log")
  ready1=$(grep -n $'\x1f''pane'$'\x1f''run'$'\x1f''w1:p2'$'\x1f' "$FIXTURE/herdr.log" | grep '__fm_ready_' | sed -n '1s/:.*//p')
  ready2=$(grep -n $'\x1f''pane'$'\x1f''run'$'\x1f''w1:p2'$'\x1f' "$FIXTURE/herdr.log" | grep '__fm_ready_' | sed -n '2s/:.*//p')
  tree=$(grep -n $'\x1f''pane'$'\x1f''run'$'\x1f''w1:p2'$'\x1f''treehouse get' "$FIXTURE/herdr.log" | cut -d: -f1)
  launch=$(grep -n $'\x1f''pane'$'\x1f''run'$'\x1f''w1:p2'$'\x1f' "$FIXTURE/herdr.log" | grep '__fm_launch_' | cut -d: -f1)
  [ -n "$ready1" ] && [ -n "$tree" ] && [ -n "$ready2" ] && [ -n "$launch" ] \
    || fail "Herdr readiness command trace is incomplete: $log"
  [ "$ready1" -lt "$tree" ] && [ "$tree" -lt "$ready2" ] && [ "$ready2" -lt "$launch" ] \
    || fail "Herdr did not acknowledge shell readiness before treehouse and again before launch"
  assert_contains "$log" "export GOTMPDIR=" "Herdr launch line did not carry GOTMPDIR"
  assert_not_contains "$log" $'\x1f''pane'$'\x1f''send-text' "Herdr launch still used split send-text"
  assert_not_contains "$log" $'\x1f''pane'$'\x1f''send-keys' "Herdr launch still used split Enter"
  [ -f "$STATE/$ID.meta" ] || fail "successful Herdr spawn did not publish metadata"
  assert_contains "$out" "spawned $ID" "successful Herdr spawn did not report success"
  [ "$(cat "$FIXTURE/herdr-state/pane-get-count")" -ge 2 ] \
    || fail "Herdr spawn accepted a transient non-worktree cwd before the real isolated root"
  pass "fm-spawn Herdr: transient cwd is ignored and exact readiness acknowledgement runs at both shell boundaries before one witnessed launch line"
}

test_first_readiness_failure_closes_only_task_pane() {
  local out
  make_fixture readiness-first-fail
  if out=$(FM_FAKE_READY_ACK_LIMIT=0 FM_FAKE_HANDOFF_MODE=raw run_spawn "sh -c 'echo never'" 2>&1); then
    fail "Herdr spawn accepted a missing first-shell execution acknowledgement"
  fi
  assert_contains "$out" "did not acknowledge execution" "first readiness failure was not reported"
  [ "$(cat "$FIXTURE/herdr-state/task")" = 0 ] || fail "first readiness failure left the task pane open"
  [ ! -f "$STATE/$ID.meta" ] || fail "first readiness failure left task metadata"
  [ ! -e "$FIXTURE/treehouse-returned" ] || fail "first readiness failure returned a worktree that was never acquired"
  pass "fm-spawn Herdr abort: first-shell readiness failure closes the exact task pane and publishes no task"
}

test_second_readiness_failure_returns_worktree_and_closes_pane() {
  local out
  make_fixture readiness-second-fail
  if out=$(FM_FAKE_READY_ACK_LIMIT=1 FM_FAKE_HANDOFF_MODE=raw run_spawn "sh -c 'echo never'" 2>&1); then
    fail "Herdr spawn accepted a missing second-shell execution acknowledgement"
  fi
  assert_contains "$out" "did not acknowledge execution" "second readiness failure was not reported"
  [ -e "$FIXTURE/treehouse-returned" ] || fail "second readiness failure did not return its acquired worktree"
  [ "$(cat "$FIXTURE/herdr-state/task")" = 0 ] || fail "second readiness failure left the task pane open"
  [ ! -f "$STATE/$ID.meta" ] || fail "second readiness failure left task metadata after successful cleanup"
  pass "fm-spawn Herdr abort: second-shell readiness failure returns the worktree, closes the pane, and removes temporary state"
}

test_launch_handoff_failure_cleans_published_artifacts() {
  local out
  make_fixture readiness-handoff-fail
  if out=$(FM_FAKE_READY_ACK_LIMIT=2 FM_FAKE_HANDOFF_MODE=none run_spawn pi 2>&1); then
    fail "Herdr spawn accepted a witnessed launch with no Pi process or agent"
  fi
  assert_contains "$out" "no pi process or agent handoff appeared" "launch handoff failure was not reported"
  [ -e "$FIXTURE/treehouse-returned" ] || fail "launch handoff failure did not return its acquired worktree"
  [ "$(cat "$FIXTURE/herdr-state/task")" = 0 ] || fail "launch handoff failure left the task pane open"
  [ ! -f "$STATE/$ID.meta" ] || fail "launch handoff failure left published metadata after successful abort cleanup"
  [ ! -e "/tmp/fm-$ID" ] || fail "launch handoff failure left its task temp root"
  pass "fm-spawn Herdr abort: missing verified worker handoff removes metadata/temp state and returns every owned resource"
}

test_agent_identity_must_match_requested_harness() {
  local out
  make_fixture readiness-agent-mismatch
  if out=$(FM_FAKE_READY_ACK_LIMIT=2 FM_FAKE_HANDOFF_MODE=wrong-agent run_spawn pi 2>&1); then
    fail "Herdr spawn accepted a Claude native-agent identity as Pi handoff evidence"
  fi
  assert_contains "$out" "no pi process or agent handoff appeared" "mismatched native-agent identity was not rejected"
  [ -e "$FIXTURE/treehouse-returned" ] || fail "identity mismatch did not return its acquired worktree"
  [ ! -f "$STATE/$ID.meta" ] || fail "identity mismatch left metadata after successful cleanup"
  pass "fm-spawn Herdr handoff: native-agent evidence must identify the requested harness"
}

test_candidate_worktree_is_returned_when_cwd_discovery_then_fails() {
  local out
  make_fixture readiness-cwd-discovery-fail
  if out=$(FM_FAKE_READY_ACK_LIMIT=1 FM_FAKE_HANDOFF_MODE=raw FM_FAKE_CWD_FAIL_AFTER=1 run_spawn "sh -c 'echo never'" 2>&1); then
    fail "Herdr spawn succeeded after cwd discovery stopped before worktree acceptance"
  fi
  assert_contains "$out" "did not enter a worktree" "cwd discovery failure was not reported"
  [ -e "$FIXTURE/treehouse-returned" ] || fail "known acquired worktree was orphaned when cwd discovery timed out"
  assert_contains "$(cat "$FIXTURE/treehouse.log")" "return --force $WORKTREE" "cleanup did not return the exact known candidate worktree"
  [ ! -f "$STATE/$ID.meta" ] || fail "successful candidate-worktree cleanup left recovery metadata"
  pass "fm-spawn Herdr abort: a validated acquisition candidate remains owned before ordinary cwd acceptance"
}

test_unrelated_checkout_is_never_claimed_for_cleanup() {
  local out
  make_fixture readiness-unrelated-cwd
  make_unrelated_checkout
  if out=$(FM_FAKE_READY_ACK_LIMIT=1 FM_FAKE_HANDOFF_MODE=raw \
    FM_FAKE_TRANSIENT_CWD_READS=1 FM_FAKE_TRANSIENT_CWD="$UNRELATED" \
    FM_FAKE_CWD_FAIL_AFTER=1 run_spawn "sh -c 'echo never'" 2>&1); then
    fail "Herdr spawn succeeded after seeing only an unrelated checkout"
  fi
  assert_contains "$out" "did not enter a worktree" "unrelated cwd discovery failure was not reported"
  assert_not_contains "$(cat "$FIXTURE/treehouse.log")" "$UNRELATED" \
    "cleanup claimed an unrelated checkout from a transient cwd read"
  [ ! -f "$STATE/$ID.meta" ] || fail "unrelated cwd failure left recovery metadata for an unowned checkout"
  pass "fm-spawn Herdr abort: transient checkouts outside the project common directory are never claimed"
}

test_unqueryable_pane_preserves_recovery_metadata() {
  local out meta
  make_fixture readiness-pane-unknown
  if out=$(FM_FAKE_READY_ACK_LIMIT=0 FM_FAKE_HANDOFF_MODE=raw FM_FAKE_PANE_PROBE_UNKNOWN=1 run_spawn "sh -c 'echo never'" 2>&1); then
    fail "Herdr spawn succeeded after readiness and cleanup verification failed"
  fi
  assert_contains "$out" "could not prove task pane" "unqueryable pane cleanup was not reported"
  meta="$STATE/$ID.meta"
  [ -f "$meta" ] || fail "unqueryable pane cleanup deleted its recovery metadata"
  assert_contains "$(cat "$meta")" "abort_cleanup=failed" "unqueryable pane metadata lacks the cleanup-failure marker"
  assert_contains "$(cat "$meta")" "herdr_pane_id=w1:p2" "unqueryable pane metadata lost the exact pane id"
  pass "fm-spawn Herdr abort: only positive pane absence permits recovery-record deletion"
}

test_cleanup_failure_preserves_owned_metadata() {
  local out meta
  make_fixture readiness-cleanup-fail
  printf 'backend=herdr\nherdr_pane_id=stale:p9\n' > "$STATE/$ID.meta"
  if out=$(FM_FAKE_READY_ACK_LIMIT=1 FM_FAKE_HANDOFF_MODE=raw FM_FAKE_TREEHOUSE_RETURN_FAIL=1 run_spawn "sh -c 'echo never'" 2>&1); then
    fail "Herdr spawn succeeded despite second readiness and abort-return failures"
  fi
  meta="$STATE/$ID.meta"
  [ -f "$meta" ] || fail "failed abort cleanup did not preserve recovery metadata"
  assert_contains "$(cat "$meta")" "abort_cleanup=failed" "preserved metadata does not mark cleanup failure"
  assert_contains "$(cat "$meta")" "worktree=$WORKTREE" "preserved metadata lost the acquired worktree"
  assert_contains "$(cat "$meta")" "herdr_pane_id=w1:p2" "preserved metadata lost the new owned pane"
  assert_not_contains "$(cat "$meta")" "herdr_pane_id=stale:p9" "cleanup failure retained stale ownership instead of the new pane"
  pass "fm-spawn Herdr abort: cleanup failure preserves an owned recovery record instead of orphaning the task"
}

test_success_uses_two_readiness_acks_and_one_launch_line
test_first_readiness_failure_closes_only_task_pane
test_second_readiness_failure_returns_worktree_and_closes_pane
test_launch_handoff_failure_cleans_published_artifacts
test_agent_identity_must_match_requested_harness
test_candidate_worktree_is_returned_when_cwd_discovery_then_fails
test_unrelated_checkout_is_never_claimed_for_cleanup
test_unqueryable_pane_preserves_recovery_metadata
test_cleanup_failure_preserves_owned_metadata
