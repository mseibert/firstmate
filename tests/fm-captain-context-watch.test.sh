#!/usr/bin/env bash
# tests/fm-captain-context-watch.test.sh - the captain context watch
# (bin/fm-captain-context-watch.sh and bin/fm-captain-context-watch-arm.sh).
#
# The captain decided (2026-09-13) that the captain session restarts at 500k of
# context. Measurement settled which footer value carries that number: pi's `↓`
# is cumulative output, and the context value is the percent/window pair, so the
# watch measures context tokens by default and the threshold stays one config
# value. These tests pin the four contracts that make the mechanism safe:
#
#   1. The footer parser reads the pi shapes (idle window, another window,
#      unknown percent, an extension status line after the footer) and reports a
#      non-parseable capture as unmeasurable rather than guessing.
#   2. The restart gate: no answer means no restart, ever; a repeat trigger or a
#      stray answer cannot double-fire; a correlated answer produces exactly one
#      kill/start of ONLY the agent pid in the target pane; aftercare records the
#      new footer against a fresh watcher beat.
#   3. The registered check stays silent while healthy and prints one line when
#      the loop is dead, the persist request is unanswered, the footer is
#      unmeasurable, or a restart phase is stalled.
#   4. Arming installs the systemd --user unit with Restart=always and registers
#      the check shim; a re-arm is idempotent, a naked loop is replaced, and
#      disarm removes both without touching anything else.
#
# The state-machine section drives the real script against a disposable tmux
# server on its own socket with a stand-in `pi`, so the kill/start transaction
# and the aftercare beat check are exercised end to end without touching the
# host's sessions. The arm section drives a fake systemctl through the
# FM_CCW_SYSTEMCTL and FM_CCW_UNIT_DIR seams, so no real user manager is
# involved.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-captain-context-watch.sh"
ARM="$ROOT/bin/fm-captain-context-watch-arm.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-context-watch)

# The threshold's evidence fixtures: every footer shape the parser must know.
footer_file() {  # <name> <content...>
  local name=$1 file
  shift
  file="$TMP_ROOT/$name"
  printf '%s\n' "$*" > "$file"
  printf '%s\n' "$file"
}

measure_fixture() {  # <state-dir> <footer-file>
  env FM_STATE_OVERRIDE="$1/state" FM_CCW_FOOTER_FILE="$2" "$WATCH" measure
}

# --- 1. the footer parser ---------------------------------------------------

test_parser_reads_the_pi_footer_shapes() {
  local home footer out
  home="$TMP_ROOT/parser"
  mkdir -p "$home/state"

  footer=$(footer_file idle-footer \
    '↑4.9M ↓144k 26.1%/1.0M (auto)                                                                                                                           (vllm-firstmate) deepseek-v41-flash-max • medium')
  out=$(measure_fixture "$home" "$footer")
  assert_contains "$out" 'status=ok' "an idle 1.0M footer did not parse: $out"
  assert_contains "$out" 'percent=26.1' "the idle footer percent was not read"
  assert_contains "$out" 'window=1000000' "the 1.0M window was not read"
  assert_contains "$out" 'context=261000' "context tokens were not derived from percent and window"
  assert_contains "$out" 'output=144000' "the ↓ cumulative-output value was not read"
  assert_contains "$out" 'input=4900000' "the ↑ cumulative-input value was not read"

  # The captain's order read the ↓ value as the context. The same session's
  # JSONL showed ↓ was output, so the watch must keep them apart.
  assert_contains "$out" 'metric=context' "the default metric must be the context value"

  footer=$(footer_file small-window-footer \
    '↑1.2M ↓9.9k 49.9%/200k (auto) (vllm) model • low')
  out=$(measure_fixture "$home" "$footer")
  assert_contains "$out" 'context=99800' "a 200k window was not converted to context tokens"
  assert_contains "$out" 'window=200000' "the 200k window was not read"

  footer=$(footer_file unknown-percent-footer \
    '↑1.2M ↓9.9k ?/1.0M (auto) (vllm) model • low')
  out=$(measure_fixture "$home" "$footer")
  assert_contains "$out" 'status=no-percent' "an unknown percent must be reported, not guessed"

  footer=$(footer_file extension-line-after-footer \
    '↑1.2M ↓9.9k 61.2%/1.0M (auto) (vllm) model • low' \
    'extension status line that follows the footer')
  out=$(measure_fixture "$home" "$footer")
  assert_contains "$out" 'status=ok' "an extension status line after the footer broke the parse"
  assert_contains "$out" 'context=612000' "the footer above an extension status line was not read"

  footer=$(footer_file not-a-footer \
    'the captain session shows only transcript text here')
  out=$(measure_fixture "$home" "$footer")
  assert_contains "$out" 'status=no-footer' "a non-parseable capture must not be read as a footer"
  assert_contains "$out" 'context=' "a no-footer capture must not produce context tokens"

  pass "measure: reads the pi footer shapes and reports unmeasurable captures instead of guessing"
}

# --- 2. the restart gate against a disposable tmux session -------------------

TMUX_SOCKET=ccw-test-$$
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
SHIM_DIR=

tmux_available() {
  [ -n "$REAL_TMUX" ]
}

make_tmux_shim() {
  SHIM_DIR="$TMP_ROOT/fakebin"
  mkdir -p "$SHIM_DIR"
  cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$TMUX_SOCKET" "\$@"
SH
  cat > "$SHIM_DIR/pi" <<'SH'
#!/bin/sh
trap 'exit 0' TERM INT HUP
while :; do sleep 1; done
SH
  chmod +x "$SHIM_DIR/tmux" "$SHIM_DIR/pi"
  PATH="$SHIM_DIR:$PATH"
  export PATH
}

tmux_cleanup() {
  [ -n "$SHIM_DIR" ] || return 0
  tmux kill-server >/dev/null 2>&1 || true
}

make_session() {  # <session-name>; starts the stand-in pi in the pane
  local session=$1 deadline
  agent_pid=
  tmux new-session -d -s "$session" -x 160 -y 40 || return 1
  tmux send-keys -t "$session" "export PATH=$SHIM_DIR:\$PATH" Enter
  sleep 0.5
  tmux send-keys -t "$session" 'pi' Enter
  deadline=$(( $(date +%s) + 10 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    agent_pid=$(agent_pid_of "$session")
    [ -n "$agent_pid" ] && return 0
    sleep 0.2
  done
  return 1
}

agent_pid_of() {  # <target>; the newest live pi stand-in pid in the pane
  local pane
  pane=$(tmux display-message -p -t "$1" '#{pane_pid}' 2>/dev/null) || return 0
  [ -n "$pane" ] || return 0
  # Newest match, and never a not-yet-reaped zombie of the replaced agent.
  ps -axo pid=,ppid=,stat=,comm= 2>/dev/null \
    | awk -v p="$pane" '$2 == p && $4 == "pi" && $3 !~ /^Z/ { pid = $1 } END { if (pid) print pid }'
}

# The environment every state-machine step runs under: isolated state, the
# disposable target, a simulated footer, and short waits so the transaction is
# fast without weakening any of its guards.
watch_env() {  # <state-dir> <target> <footer-file>; then command args follow
  local state_dir=$1 target=$2 footer=$3
  shift 3
  FM_STATE_OVERRIDE="$state_dir" FM_CCW_TARGET="$target" FM_CCW_FOOTER_FILE="$footer" \
    FM_CCW_QUIESCE_WAIT=0 FM_CCW_RESTART_WAIT=15 FM_CCW_AFTERCARE_WAIT=10 \
    FM_CCW_COOLDOWN=0 FM_CCW_INTERVAL=1 \
    "$WATCH" "$@"
}

test_no_answer_never_restarts() {
  local home session state_dir footer pid_after count agent_pid
  home="$TMP_ROOT/no-answer"
  mkdir -p "$home/state"
  session=ccw-noanswer
  state_dir="$home/state"
  footer=$(footer_file no-answer-high \
    '↑9.2M ↓144k 51.9%/1.0M (auto) (vllm-firstmate) model • medium')
  make_session "$session" || { echo "skip: could not start the disposable tmux session"; return 0; }
  agent_pid=$(agent_pid_of "$session")

  watch_env "$state_dir" "$session" "$footer" step
  assert_grep "phase=awaiting-answer" "$state_dir/.captain-context-watch.state" \
    "a crossing did not open the persist gate"
  assert_present "$state_dir/.captain-context-watch.request" "the crossing wrote no persist request"

  # Four more steps with no answer: the agent must still be the same process.
  local i=0
  while [ "$i" -lt 4 ]; do
    watch_env "$state_dir" "$session" "$footer" step
    i=$((i + 1))
  done
  pid_after=$(agent_pid_of "$session")
  [ "$pid_after" = "$agent_pid" ] \
    || fail "the stand-in agent was replaced without any persist answer"
  count=$(grep -c 'phase=crossed ' "$state_dir/.captain-context-watch.log" 2>/dev/null || true)
  [ "$count" = 1 ] || fail "a repeat trigger opened a second request (crossed lines: $count)"
  local pending_corr
  pending_corr=$(sed -n 's/^corr=//p' "$state_dir/.captain-context-watch.state")
  [ -n "$pending_corr" ] || fail "the crossing minted no correlation id"
  grep -q "$pending_corr" "$state_dir/.captain-context-watch.request" \
    || fail "the persisted request does not name its correlation id"
  tmux_cleanup
  pass "no persist answer -> no restart, and a repeat trigger opens no second request"
}

test_answer_releases_exactly_one_restart_and_aftercare_records_the_new_footer() {
  local home session state_dir footer old_pid new_pid corr agent_pid
  home="$TMP_ROOT/release"
  mkdir -p "$home/state"
  session=ccw-release
  state_dir="$home/state"
  footer=$(footer_file release-high \
    '↑9.2M ↓144k 51.9%/1.0M (auto) (vllm-firstmate) model • medium')
  make_session "$session" || { echo "skip: could not start the disposable tmux session"; return 0; }
  old_pid=$(agent_pid_of "$session")

  watch_env "$state_dir" "$session" "$footer" step
  corr=$(sed -n 's/^corr=//p' "$state_dir/.captain-context-watch.state")
  [ -n "$corr" ] || fail "the crossing minted no correlation id"

  # A stray answer with the wrong correlation must not release anything.
  if watch_env "$state_dir" "$session" "$footer" answer --corr 0000000000000000 >/dev/null 2>&1; then
    fail "an answer with the wrong correlation id was accepted"
  fi
  [ "$(agent_pid_of "$session")" = "$old_pid" ] || fail "a wrong-correlation answer released the restart"

  watch_env "$state_dir" "$session" "$footer" answer --corr "$corr" --note 'unit test' >/dev/null \
    || fail "the correlated answer was refused"
  assert_grep "phase=answer corr=$corr" "$state_dir/.captain-context-watch.log" \
    "the answer was not journaled"

  # The restart transaction: the answer moves the machine through quiescing and
  # restarting, and the step that runs restarting performs the kill+start.
  watch_env "$state_dir" "$session" "$footer" step
  watch_env "$state_dir" "$session" "$footer" step
  watch_env "$state_dir" "$session" "$footer" step
  new_pid=$(agent_pid_of "$session")
  [ -n "$new_pid" ] || fail "no stand-in agent is running after the restart"
  [ "$new_pid" != "$old_pid" ] || fail "the agent was not actually replaced"
  kill -0 "$old_pid" 2>/dev/null && fail "the old agent pid is still alive after the restart"
  assert_grep "phase=restart-done old_pid=$old_pid new_pid=$new_pid" "$state_dir/.captain-context-watch.log" \
    "the journal does not record the old and new agent pids"
  [ "$(grep -c 'phase=restart-done' "$state_dir/.captain-context-watch.log")" = 1 ] \
    || fail "the restart executed more than once"

  # Aftercare: a fresh watcher beat plus the new footer, then back to idle.
  : > "$state_dir/.last-watcher-beat"
  footer=$(footer_file release-low \
    '↑0.1M ↓2k 0.4%/1.0M (auto) (vllm-firstmate) model • medium')
  watch_env "$state_dir" "$session" "$footer" step
  assert_grep "phase=idle" "$state_dir/.captain-context-watch.state" \
    "aftercare did not return the machine to idle"
  assert_grep "phase=aftercare-done" "$state_dir/.captain-context-watch.log" \
    "aftercare did not verify the watcher beat"
  assert_grep 'context=4000' "$state_dir/.captain-context-watch.log" \
    "aftercare did not record the new footer"
  assert_absent "$state_dir/.captain-context-watch.request" "the released request was not cleaned up"
  assert_absent "$state_dir/.captain-context-watch.answer" "the spent answer was not cleaned up"

  # A completed cycle re-arms: a later crossing opens a NEW correlation.
  footer=$(footer_file release-high-again \
    '↑9.2M ↓200k 55.0%/1.0M (auto) (vllm-firstmate) model • medium')
  watch_env "$state_dir" "$session" "$footer" step
  local new_corr
  new_corr=$(sed -n 's/^corr=//p' "$state_dir/.captain-context-watch.state")
  [ -n "$new_corr" ] || fail "a later crossing did not open a new request"
  [ "$new_corr" != "$corr" ] || fail "the later crossing reused the spent correlation id"
  tmux_cleanup
  pass "a correlated answer releases exactly one restart, aftercare records the new footer, and the gate re-arms"
}

# --- 3. the registered check ------------------------------------------------

check_env() {  # <state-dir>; command args follow
  local state_dir=$1
  shift
  FM_STATE_OVERRIDE="$state_dir" FM_CCW_REMIND_MAX="${FM_CCW_REMIND_MAX:-1}" \
    "$WATCH" check "$@"
}

test_check_is_silent_while_healthy_and_reports_the_gate_once() {
  local home state_dir out
  home="$TMP_ROOT/check"
  state_dir="$home/state"
  mkdir -p "$state_dir"

  # Healthy: a fresh loop beat and no pending phase -> silence.
  : > "$state_dir/.captain-context-watch-beat"
  out=$(check_env "$state_dir")
  [ -z "$out" ] || fail "the check spoke while the watch was healthy: $out"

  # A dead loop -> one line, and not again on the next sweep.
  rm -f "$state_dir/.captain-context-watch-beat"
  out=$(check_env "$state_dir")
  assert_contains "$out" 'watcher loop has never beaten' "a never-beaten loop was not reported"
  out=$(check_env "$state_dir")
  [ -z "$out" ] || fail "a persistently dead loop was re-reported without its repeat window: $out"

  # A pending persist request -> the release command once, then silence.
  cat > "$state_dir/.captain-context-watch.state" <<'EOF'
schema=fm-captain-context-watch-state-v1
phase=awaiting-answer
corr=0123456789abcdef
crossed_epoch=1
crossed_context=519000
phase_epoch=1
last_context=519000
EOF
  : > "$state_dir/.captain-context-watch-beat"
  out=$(check_env "$state_dir")
  assert_contains "$out" 'corr=0123456789abcdef' "the pending request was not announced"
  assert_contains "$out" 'fm-captain-context-watch.sh answer --corr 0123456789abcdef' \
    "the announcement does not name the exact release command"
  out=$(check_env "$state_dir")
  [ -z "$out" ] || fail "the pending request was re-announced on the next sweep: $out"

  # The bounded reminder ladder (FM_CCW_REMIND_MAX=1): backdate the last
  # emission, expect exactly one reminder, then silence once it is spent.
  sed -i 's/^persist_last_epoch=.*/persist_last_epoch=1/' "$state_dir/.captain-context-watch.notified"
  out=$(check_env "$state_dir")
  assert_contains "$out" 'still unanswered' "the reminder was not emitted after its window"
  sed -i 's/^persist_last_epoch=.*/persist_last_epoch=1/' "$state_dir/.captain-context-watch.notified"
  out=$(check_env "$state_dir")
  [ -z "$out" ] || fail "the reminder ladder never ended: $out"

  pass "check: silent while healthy, one line per alarm, bounded persist reminders"
}

test_check_reports_unmeasurable_footers_and_stalled_phases() {
  local home state_dir out
  home="$TMP_ROOT/check-alarms"
  state_dir="$home/state"
  mkdir -p "$state_dir"

  cat > "$state_dir/.captain-context-watch.state" <<'EOF'
schema=fm-captain-context-watch-state-v1
phase=idle
unreadable_streak=7
EOF
  : > "$state_dir/.captain-context-watch-beat"
  out=$(check_env "$state_dir")
  assert_contains "$out" 'footer unreadable for 7 consecutive samples' \
    "a persistently unmeasurable footer was not reported"

  cat > "$state_dir/.captain-context-watch.state" <<'EOF'
schema=fm-captain-context-watch-state-v1
phase=restarting
phase_epoch=1
old_pid=111
new_pid=
EOF
  rm -f "$state_dir/.captain-context-watch.notified"
  : > "$state_dir/.captain-context-watch-beat"
  out=$(check_env "$state_dir")
  assert_contains "$out" 'restart phase restarting unfinished' \
    "a stalled restart phase was not reported"

  pass "check: reports unmeasurable footers and stalled restart phases"
}

# --- 4. arming under a systemd --user unit ----------------------------------

UNIT_NAME=firstmate-captain-context-watch.service
FAKE_SYSTEMCTL=

make_home() {  # <name>
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

make_systemctl() {  # <home>; prints the fake systemctl path
  local home=$1 log active
  log="$home/systemctl.log"
  active="$home/unit-active"
  : > "$log"
  cat > "$home/fake-systemctl.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
shift
cmd=\$1
shift
case "\$cmd" in
  is-active)
    [ -f "$active" ] && printf 'active\n' || printf 'inactive\n'
    exit 0
    ;;
  daemon-reload)
    exit 0
    ;;
  enable|start)
    [ "\${1:-}" = --now ] && shift
    touch "$active"
    exit 0
    ;;
  disable|stop)
    [ "\${1:-}" = --now ] && shift
    rm -f "$active"
    exit 0
    ;;
  *)
    printf 'fake systemctl: unknown command %s\n' "\$cmd" >&2
    exit 1
    ;;
esac
SH
  chmod 0755 "$home/fake-systemctl.sh"
  printf '%s\n' "$home/fake-systemctl.sh"
}

run_arm() {  # <home> <out-file>
  local home=$1 out=$2
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CCW_SYSTEMCTL="$FAKE_SYSTEMCTL" FM_CCW_UNIT_DIR="$home/unit-dir" \
    "$ARM" arm >"$out" 2>&1
}

run_disarm() {  # <home> <out-file>
  local home=$1 out=$2
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CCW_SYSTEMCTL="$FAKE_SYSTEMCTL" FM_CCW_UNIT_DIR="$home/unit-dir" \
    "$ARM" disarm >"$out" 2>&1
}

test_arm_installs_restart_always_unit_and_registers_the_check() {
  local home out unit
  home=$(make_home arm)
  FAKE_SYSTEMCTL=$(make_systemctl "$home")
  unit="$home/unit-dir/$UNIT_NAME"
  out="$home/arm.out"

  run_arm "$home" "$out"
  expect_code 0 "$?" "arm exit"
  assert_present "$unit" "arm did not install the unit"
  assert_present "$home/state/captain-context-watch.check-trust" "arm did not register the check"
  grep -q "Restart=always" "$unit" \
    || fail "the installed unit lost Restart=always - the watch would die with a crash"
  grep -q "@FM_HOME@" "$unit" && fail "the installed unit still carries @FM_HOME@" || true
  grep -q "@FM_CCW_WATCH@" "$unit" && fail "the installed unit still carries @FM_CCW_WATCH@" || true
  grep -q "$WATCH run" "$unit" || fail "the installed unit does not run this home's watch"
  grep -q "FM_HOME=$home" "$unit" || fail "the installed unit does not pin this home"
  grep -q "enable --now $UNIT_NAME" "$home/systemctl.log" || fail "arm never enabled and started the unit"
  grep -q "daemon-reload" "$home/systemctl.log" || fail "arm never reloaded the daemon"
  assert_present "$home/state/.captain-context-watch-beat" "arm did not seed the loop beat"
  assert_grep "armed" "$out" "arm did not report the armed outcome"
  grep -q "$WATCH check" "$home/state/captain-context-watch.check.sh" \
    || fail "the registered shim does not dispatch the watch's check verb"
  local mode
  mode=$(stat -c %a "$home/state/captain-context-watch.check.sh" 2>/dev/null \
    || stat -f %Lp "$home/state/captain-context-watch.check.sh")
  [ "$mode" = 700 ] || fail "the check shim is not mode 700 (got $mode)"

  # Re-arm against an active unit: confirm, never start a second loop.
  run_arm "$home" "$out"
  expect_code 0 "$?" "re-arm exit"
  assert_grep "already armed" "$out" "a re-arm against an active unit did not confirm"
  [ "$(grep -c "enable --now $UNIT_NAME" "$home/systemctl.log")" = 1 ] \
    || fail "re-arm started the unit again - there would be two watch loops"

  # A symlink at the unit destination is refused, never followed.
  rm -f "$home/unit-active"
  rm -f "$unit"
  ln -s /dev/null "$unit"
  if run_arm "$home" "$out"; then
    fail "arm followed a symlink at the unit destination"
  fi
  [ -L "$unit" ] || fail "arm removed the symlink instead of refusing it"
  rm -f "$unit"

  pass "arm: Restart=always unit, registered check, idempotent re-arm, symlink refusal"
}

test_arm_replaces_a_naked_loop_and_disarm_removes_both() {
  local home out pid fake
  home=$(make_home naked)
  FAKE_SYSTEMCTL=$(make_systemctl "$home")
  out="$home/arm.out"
  fake="$home/fake-bin/fm-captain-context-watch.sh"
  mkdir -p "$home/fake-bin"
  cat > "$fake" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "$home/state/.captain-context-watch.lock"
trap 'rm -f -- "$home/state/.captain-context-watch.lock"; exit 0' TERM INT HUP
while :; do sleep 1; done
SH
  chmod 0755 "$fake"
  "$fake" &
  pid=$!
  sleep 0.3
  [ "$(cat "$home/state/.captain-context-watch.lock" 2>/dev/null)" = "$pid" ] \
    || fail "the naked loop did not record its own pid in the watch lock"

  run_arm "$home" "$out"
  expect_code 0 "$?" "arm with a naked loop exit"
  kill -0 "$pid" 2>/dev/null && fail "arm left the naked loop running next to the unit"
  assert_grep "armed" "$out" "arm did not report the outcome after replacing the naked loop"

  printf 'pending\n' > "$home/state/.captain-context-watch.request"
  printf 'answer\n' > "$home/state/.captain-context-watch.answer"
  printf 'schema=x\n' > "$home/state/.captain-context-watch.notified"
  run_disarm "$home" "$out"
  expect_code 0 "$?" "disarm exit"
  assert_absent "$home/unit-dir/$UNIT_NAME" "disarm left the unit installed"
  assert_absent "$home/state/captain-context-watch.check-trust" "disarm left the check registered"
  assert_absent "$home/state/.captain-context-watch.request" "disarm left a stale release gate"
  assert_absent "$home/state/.captain-context-watch.answer" "disarm left a stale answer"
  grep -q "disable --now $UNIT_NAME" "$home/systemctl.log" || fail "disarm never disabled the unit"

  pass "arm replaces only a verified naked loop; disarm removes the unit, the check, and the stale gate"
}

# --- run --------------------------------------------------------------------

test_parser_reads_the_pi_footer_shapes
if tmux_available; then
  make_tmux_shim
  trap 'tmux_cleanup; fm_test_cleanup' EXIT
  trap 'tmux_cleanup; fm_test_cleanup; exit 130' INT
  trap 'tmux_cleanup; fm_test_cleanup; exit 143' TERM
  test_no_answer_never_restarts
  test_answer_releases_exactly_one_restart_and_aftercare_records_the_new_footer
else
  echo "skip: tmux not found - state-machine e2e section skipped"
fi
test_check_is_silent_while_healthy_and_reports_the_gate_once
test_check_reports_unmeasurable_footers_and_stalled_phases
test_arm_installs_restart_always_unit_and_registers_the_check
test_arm_replaces_a_naked_loop_and_disarm_removes_both
