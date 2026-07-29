#!/usr/bin/env bash
# tests/fm-spawn-pi-herdr-e2e.test.sh - opt-in real Pi proof for Herdr's
# execution-acknowledged two-shell spawn path plus an isolated tmux control.
# Every Herdr lifecycle and task call is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

case "${FM_HERDR_PI_SPAWN_E2E:-}" in
  1|true|yes|on) : ;;
  *) echo "skip: set FM_HERDR_PI_SPAWN_E2E=1 for the real Pi Herdr/tmux spawn proof"; exit 0 ;;
esac
for tool in herdr jq treehouse pi tmux; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-spawn-pi-herdr-e2e.XXXXXX")
HELPER="$ROOT/bin/fm-herdr-lab.sh"
SESSION=$("$HELPER" name fm-spawn-pi-herdr-e2e) || fail "could not generate Herdr lab name"
LAB_LIVE=0
TMUX_LABEL="fm-pi-control-$$"
TMUX_LIVE=0
REAL_PATH=$PATH
cleanup() {
  local status=$?
  [ "$TMUX_LIVE" -eq 0 ] || tmux -L "$TMUX_LABEL" kill-server >/dev/null 2>&1 || true
  [ "$LAB_LIVE" -eq 0 ] || "$HELPER" teardown "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
  trap - EXIT
  exit "$status"
}
trap cleanup EXIT

ZDOTDIR="$TMP_ROOT/zdot"
mkdir -p "$ZDOTDIR"
cat > "$ZDOTDIR/.zshrc" <<'ZSH'
# Deterministic foreground startup child for both the initial and treehouse zsh.
sleep 1
PS1='fm-e2e% '
ZSH
export ZDOTDIR

"$HELPER" provision "$SESSION" || fail "could not provision guarded Herdr lab"
LAB_LIVE=1

SHIM="$TMP_ROOT/herdr-shim"
mkdir -p "$SHIM"
cat > "$SHIM/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ]; then
  [ "${args[$((n-1))]}" = "${FM_E2E_HERDR_SESSION:?}" ] || exit 97
  unset 'args[$((n-1))]' 'args[$((n-2))]'
fi
PATH="${FM_E2E_REAL_PATH:?}" exec "${FM_E2E_HERDR_HELPER:?}" run \
  "${FM_E2E_HERDR_SESSION:?}" "${args[@]}"
SH
chmod +x "$SHIM/herdr"
export FM_E2E_HERDR_SESSION="$SESSION" FM_E2E_HERDR_HELPER="$HELPER" FM_E2E_REAL_PATH="$REAL_PATH"

PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT"
git -C "$PROJECT" init -q
printf 'fixture\n' > "$PROJECT/file.txt"
git -C "$PROJECT" add file.txt
git -C "$PROJECT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm fixture

write_home() {  # <home> <id>
  local home=$1 id=$2
  mkdir -p "$home/data/$id" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<EOF
You are a bounded Firstmate launch canary. Do not inspect or modify the repository. Use bash once to append exactly 'done: Pi processed the launch canary' to '$home/state/$id.status', then stop and wait.
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Launch canary

No unresolved captain decisions.
EOF
}

wait_for_pi_canary() {  # <backend> <target> <home> <id> <tmux-env>
  local backend=$1 target=$2 home=$3 id=$4 tmux_env=${5:-} capture trust=0
  for _ in $(seq 1 120); do
    if grep -Fx 'done: Pi processed the launch canary' "$home/state/$id.status" >/dev/null 2>&1; then
      return 0
    fi
    if [ "$backend" = herdr ]; then
      capture=$("$HELPER" run "$SESSION" pane read "$target" --source recent --lines 200 2>/dev/null || true)
      if [ "$trust" -eq 0 ] && printf '%s' "$capture" | grep -F 'Trust project folder?' >/dev/null; then
        trust=1
        "$HELPER" run "$SESSION" pane send-keys "$target" down >/dev/null
        "$HELPER" run "$SESSION" pane send-keys "$target" down >/dev/null
        "$HELPER" run "$SESSION" pane send-keys "$target" enter >/dev/null
      fi
    else
      capture=$(TMUX="$tmux_env" tmux capture-pane -p -t "$target" -S -200 2>/dev/null || true)
      if [ "$trust" -eq 0 ] && printf '%s' "$capture" | grep -F 'Trust project folder?' >/dev/null; then
        trust=1
        TMUX="$tmux_env" tmux send-keys -t "$target" Down Down Enter
      fi
    fi
    sleep 1
  done
  return 1
}

finish_scout() {  # <home> <id> <extra-env...>
  local home=$1 id=$2
  shift 2
  FM_HOME="$home" "$ROOT/bin/fm-decision-hold.sh" complete "$id" --none >/dev/null \
    || fail "could not complete $id decision inventory"
  env "$@" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" "$id" >/dev/null \
    || fail "could not clean $id"
  [ ! -f "$home/state/$id.meta" ] || fail "$id metadata survived cleanup"
}

# Real Herdr path: auto-detection, deterministic startup delay at both zsh
# boundaries, real Pi trust/agent boundary, brief processing, and cleanup.
HERDR_HOME="$TMP_ROOT/herdr-home"
HERDR_ID=pi-herdr-canary
write_home "$HERDR_HOME" "$HERDR_ID"
env -u TMUX -u FM_BACKEND PATH="$SHIM:$REAL_PATH" HERDR_ENV=1 HERDR_SESSION="$SESSION" \
  FM_HOME="$HERDR_HOME" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" "$HERDR_ID" "$PROJECT" --harness pi --effort xhigh --scout \
  > "$TMP_ROOT/herdr-spawn.out" 2> "$TMP_ROOT/herdr-spawn.err" \
  || fail "real Pi Herdr spawn failed: $(cat "$TMP_ROOT/herdr-spawn.err")"
HERDR_META="$HERDR_HOME/state/$HERDR_ID.meta"
[ -f "$HERDR_META" ] || fail "real Pi Herdr spawn published no metadata"
HERDR_PANE=$(grep '^herdr_pane_id=' "$HERDR_META" | cut -d= -f2-)
wait_for_pi_canary herdr "$HERDR_PANE" "$HERDR_HOME" "$HERDR_ID" \
  || fail "real Pi did not process the Herdr canary"
finish_scout "$HERDR_HOME" "$HERDR_ID" PATH="$SHIM:$REAL_PATH" HERDR_SESSION="$SESSION"
if "$HELPER" run "$SESSION" pane get "$HERDR_PANE" >/dev/null 2>&1; then
  fail "Herdr canary pane survived task cleanup"
fi
pass "real Pi/Herdr: auto-detected spawn waited through both delayed shells, started Pi, processed the brief, and cleaned the task"

# Equivalent isolated tmux control with the same project, Pi launch, effort,
# session-only trust handling, and canary acceptance condition.
TMUX_HOME="$TMP_ROOT/tmux-home"
TMUX_ID=pi-tmux-canary
write_home "$TMUX_HOME" "$TMUX_ID"
ZDOTDIR="$ZDOTDIR" tmux -L "$TMUX_LABEL" new-session -d -s control -c "$PROJECT"
TMUX_LIVE=1
TMUX_SOCKET=$(tmux -L "$TMUX_LABEL" display-message -p '#{socket_path}')
TMUX_PID=$(tmux -L "$TMUX_LABEL" display-message -p '#{pid}')
TMUX_ENV="$TMUX_SOCKET,$TMUX_PID,0"
TMUX="$TMUX_ENV" FM_HOME="$TMUX_HOME" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" "$TMUX_ID" "$PROJECT" --harness pi --effort xhigh --backend tmux --scout \
  > "$TMP_ROOT/tmux-spawn.out" 2> "$TMP_ROOT/tmux-spawn.err" \
  || fail "real Pi tmux control failed: $(cat "$TMP_ROOT/tmux-spawn.err")"
TMUX_TARGET=$(grep '^window=' "$TMUX_HOME/state/$TMUX_ID.meta" | cut -d= -f2-)
wait_for_pi_canary tmux "$TMUX_TARGET" "$TMUX_HOME" "$TMUX_ID" "$TMUX_ENV" \
  || fail "real Pi did not process the tmux control canary"
finish_scout "$TMUX_HOME" "$TMUX_ID" TMUX="$TMUX_ENV"
pass "real Pi/tmux control: equivalent isolated launch processed the brief and cleaned the task"

tmux -L "$TMUX_LABEL" kill-server
TMUX_LIVE=0
"$HELPER" teardown "$SESSION" || fail "Herdr lab teardown or default-session tripwire failed"
LAB_LIVE=0
trap - EXIT
rm -rf "$TMP_ROOT"
pass "real Pi spawn E2E: isolated tmux server and named Herdr lab removed; default Herdr session unchanged"
