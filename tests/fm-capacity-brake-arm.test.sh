#!/usr/bin/env bash
# tests/fm-capacity-brake-arm.test.sh - the captain's capacity-brake hardening
# (bin/fm-capacity-brake-arm.sh): a tracked systemd --user unit with
# Restart=always, idempotent arming that replaces the naked loop, and a
# beat-age self-report so a dead brake loop surfaces as a check wake.
#
# The captain's finding (2026-09-07/08): the capacity brake ran as a naked bash
# pid with no systemd unit and no self-report, so the Paseo restart that emptied
# its cgroup left the brake dead for 17 hours without anyone seeing it. The
# watcher has a liveness beacon; the brake had none, and that asymmetry was the
# gap. These tests pin the hardening's four contracts hermetically through its
# executable interface:
#
#   1. Restart behavior: arm renders the tracked template and installs the
#      unit, so the artifact systemd loads still carries Restart=always - the
#      brake survives the next crash instead of dying silently.
#   2. Idempotent arming, no double processes: a re-arm against an active unit
#      confirms and never starts a second copy or touches the running process,
#      and arm replaces the naked loop (and only a process that really is the
#      capacity brake, never a stale or reused lock pid).
#   3. Beat-age self-report: state/capacity-brake.check.sh (the registered
#      custom watcher check) prints one line when the beat is older than the
#      grace or absent, and nothing while the beat is fresh; the armed shim
#      dispatches the real check.
#   4. Disarm and fail-closed: disarm stops, disables, and removes the unit and
#      unregisters the check; a symlink at the unit or shim destination is
#      refused rather than followed.
#
# systemd itself is driven through the FM_CAPACITY_BRAKE_SYSTEMCTL seam and the
# unit destination through FM_CAPACITY_BRAKE_UNIT_DIR, so the whole lifecycle is
# pinned deterministically without a real user manager.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ARM="$ROOT/bin/fm-capacity-brake-arm.sh"
TMP_ROOT=$(fm_test_tmproot fm-capacity-brake-arm)
UNIT_NAME=firstmate-capacity-brake.service

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# Fake systemctl: tracks one unit's active state in a marker file and logs every
# invocation, so a test can assert exactly how many starts a re-arm caused.
make_systemctl() {
  local home=$1 log active
  log="$home/systemctl.log"
  active="$home/unit-active"
  : > "$log"
  cat > "$home/fake-systemctl.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
shift   # --user
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

# The brake script itself: arm requires it to exist and be executable, and the
# naked-loop case runs it as the loop (it records its pid in the lock and then
# idles, the way the real brake owns its lock).
make_brake() {
  local home=$1 lock
  lock="$home/state/.capacity-brake.lock"
  cat > "$home/state/capacity-brake.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "$lock"
sleep 1000 &
sleep_pid=\$!
trap 'rm -f -- "$lock"; kill "\$sleep_pid" 2>/dev/null || true' EXIT HUP INT TERM
# Idle behind an interruptible wait builtin (a foreground sleep would defer a trapped
# TERM until it returned), and kill the sleep child in the trap so no orphan
# holds the runner's pipe open.
wait "\$sleep_pid"
SH
  chmod 0755 "$home/state/capacity-brake.sh"
}

run_arm() {
  local home=$1 out=$2 status=0
  shift 2
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CAPACITY_BRAKE_SYSTEMCTL="$SYSTEMCTL" \
    FM_CAPACITY_BRAKE_UNIT_DIR="$home/unit-dir" \
    "$@" "$ARM" arm >"$out" 2>&1 || status=$?
  return "$status"
}

run_disarm() {
  local home=$1 out=$2 status=0
  shift 2
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CAPACITY_BRAKE_SYSTEMCTL="$SYSTEMCTL" \
    FM_CAPACITY_BRAKE_UNIT_DIR="$home/unit-dir" \
    "$@" "$ARM" disarm >"$out" 2>&1 || status=$?
  return "$status"
}

# --- 1. restart behavior + idempotent arming --------------------------------

test_arm_installs_the_unit_with_restart_always() {
  local home out unit
  home=$(make_home install)
  make_brake "$home"
  SYSTEMCTL=$(make_systemctl "$home")
  unit="$home/unit-dir/$UNIT_NAME"
  out="$home/arm.out"

  run_arm "$home" "$out"
  expect_code 0 "$?" "arm exit"
  assert_present "$unit" "arm did not install the unit"
  assert_present "$home/state/capacity-brake.check-trust" "arm did not register the beat check"
  grep -q "Restart=always" "$unit" \
    || fail "the installed unit lost Restart=always - the brake would die silently again"
  grep -q "@FM_HOME@" "$unit" \
    && fail "the installed unit still carries the unrendered @FM_HOME@ placeholder" || true
  grep -q "$home/state/capacity-brake.sh" "$unit" \
    || fail "the installed unit does not point at this home's brake script"
  grep -q "enable --now $UNIT_NAME" "$home/systemctl.log" \
    || fail "arm never enabled and started the unit"
  grep -q "daemon-reload" "$home/systemctl.log" \
    || fail "arm never reloaded the daemon"
  assert_grep "armed" "$out" "arm did not report the armed outcome"
  [ "$(stat -c %a "$home/state/capacity-brake.check.sh" 2>/dev/null || stat -f %Lp "$home/state/capacity-brake.check.sh")" = 700 ] \
    || fail "the beat check shim is not mode 700"
  pass "arm installs the unit with Restart=always, enables and starts it, and registers the beat check"
}

test_rearm_is_idempotent_and_never_starts_a_second_brake() {
  local home out pid
  home=$(make_home rearm)
  make_brake "$home"
  SYSTEMCTL=$(make_systemctl "$home")
  out="$home/arm.out"

  run_arm "$home" "$out"
  expect_code 0 "$?" "first arm exit"

  # Simulate the running unit's process holding the brake lock.
  bash "$home/state/capacity-brake.sh" &
  pid=$!
  sleep 0.3

  run_arm "$home" "$out"
  expect_code 0 "$?" "re-arm exit"
  assert_grep "already armed" "$out" "a re-arm against an active unit did not report already armed"
  [ "$(grep -c "enable --now $UNIT_NAME" "$home/systemctl.log")" -eq 1 ] \
    || fail "re-arm started the unit again - there would be two brake launches"
  kill -0 "$pid" 2>/dev/null \
    || fail "re-arm killed the running brake process instead of leaving the unit alone"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "re-arming an active unit confirms and never starts a second brake or kills the running one"
}

test_arm_replaces_the_naked_loop() {
  local home out pid
  home=$(make_home replace)
  make_brake "$home"
  SYSTEMCTL=$(make_systemctl "$home")
  out="$home/arm.out"

  bash "$home/state/capacity-brake.sh" &
  pid=$!
  sleep 0.3
  [ "$(cat "$home/state/.capacity-brake.lock")" = "$pid" ] \
    || fail "the naked loop did not record its own pid in the lock"

  run_arm "$home" "$out"
  expect_code 0 "$?" "arm exit"
  kill -0 "$pid" 2>/dev/null \
    && fail "arm left the naked loop running next to the new unit" || true
  assert_grep "armed" "$out" "arm did not report the armed outcome"
  assert_present "$home/unit-dir/$UNIT_NAME" "arm did not install the unit after replacing the loop"
  pass "arm stops the naked loop before starting the unit, so there is never a second brake"
}

test_arm_refuses_to_kill_a_non_brake_lock_pid() {
  local home out pid
  home=$(make_home nonbrake)
  make_brake "$home"
  SYSTEMCTL=$(make_systemctl "$home")
  out="$home/arm.out"

  sleep 1000 &
  pid=$!
  printf '%s\n' "$pid" > "$home/state/.capacity-brake.lock"

  run_arm "$home" "$out"
  expect_code 1 "$?" "arm should refuse to kill a lock pid that is not the capacity brake"
  kill -0 "$pid" 2>/dev/null \
    || fail "arm killed a process that is not the capacity brake"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_absent "$home/unit-dir/$UNIT_NAME" "arm installed the unit after refusing the naked loop"
  pass "arm fails closed on a lock pid that is not the capacity brake"
}

test_arm_refuses_a_lock_pid_it_cannot_identify() {
  local home out pid psdir
  home=$(make_home unreadable)
  make_brake "$home"
  SYSTEMCTL=$(make_systemctl "$home")
  out="$home/arm.out"
  psdir="$home/unreadable-ps"
  mkdir -p "$psdir" "$home/empty-proc"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$psdir/ps"
  chmod 0755 "$psdir/ps"

  sleep 1000 &
  pid=$!
  printf '%s\n' "$pid" > "$home/state/.capacity-brake.lock"

  # No readable /proc entry and no usable ps: the command line cannot be read,
  # so the pid must not be trusted as the brake even though it is alive.
  run_arm "$home" "$out" FM_PROC_ROOT_OVERRIDE="$home/empty-proc" "PATH=$psdir:$PATH"
  expect_code 1 "$?" "arm should refuse a lock pid whose command line cannot be read"
  kill -0 "$pid" 2>/dev/null \
    || fail "arm signalled a process whose command line it could not read"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_absent "$home/unit-dir/$UNIT_NAME" "arm installed the unit after failing to identify the lock pid"
  pass "arm fails closed when the lock pid's command line is unreadable"
}

test_arm_fails_closed_when_the_template_is_missing() {
  local home out
  home=$(make_home notemplate)
  make_brake "$home"
  SYSTEMCTL=$(make_systemctl "$home")
  out="$home/arm.out"

  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CAPACITY_BRAKE_SYSTEMCTL="$SYSTEMCTL" \
    FM_CAPACITY_BRAKE_UNIT_DIR="$home/unit-dir" \
    FM_CAPACITY_BRAKE_TEMPLATE="$home/no-such-template.service" \
    "$ARM" arm >"$out" 2>&1
  expect_code 1 "$?" "arm should refuse a missing template"
  assert_absent "$home/unit-dir/$UNIT_NAME" "arm installed a unit despite a missing template"
  assert_absent "$home/state/capacity-brake.check.sh" "arm armed the beat check without a unit"
  pass "arm fails closed on a missing unit template"
}

# --- 3. beat-age self-report -------------------------------------------------

test_check_is_silent_while_the_beat_is_fresh() {
  local home out
  home=$(make_home fresh)
  out="$home/check.out"
  touch "$home/state/.capacity-brake-beat"
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ARM" check >"$out" 2>&1
  expect_code 0 "$?" "check exit"
  [ -s "$out" ] && fail "a fresh beat must not alarm" || true
  pass "a fresh beat keeps the check silent"
}

test_check_alarms_when_the_beat_is_stale_or_absent() {
  local home out
  home=$(make_home stale)
  out="$home/check.out"
  touch -d '6 minutes ago' "$home/state/.capacity-brake-beat"
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ARM" check >"$out" 2>&1
  expect_code 0 "$?" "check exit"
  grep -q "capacity-brake: beat" "$out" || fail "a stale beat did not alarm"
  grep -q "not beating" "$out" || fail "the stale-beat alarm does not say the loop is not beating"

  out="$home/check-absent.out"
  rm -f "$home/state/.capacity-brake-beat"
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ARM" check >"$out" 2>&1
  expect_code 0 "$?" "check exit"
  grep -q "not running" "$out" || fail "an absent beat did not alarm"
  pass "a stale or absent beat surfaces as an alarm line"
}

test_check_respects_the_grace_override() {
  local home out
  home=$(make_home grace)
  out="$home/check.out"
  touch -d '30 seconds ago' "$home/state/.capacity-brake-beat"
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CAPACITY_BRAKE_BEAT_GRACE=60 "$ARM" check >"$out" 2>&1
  [ -s "$out" ] && fail "a beat inside the grace window must stay silent" || true
  touch -d '2 minutes ago' "$home/state/.capacity-brake-beat"
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CAPACITY_BRAKE_BEAT_GRACE=60 "$ARM" check >"$out" 2>&1
  grep -q "capacity-brake: beat" "$out" || fail "a beat past the grace window did not alarm"
  pass "the beat-age alarm honors the configured grace"
}

test_the_armed_shim_dispatches_the_check() {
  local home out
  home=$(make_home shim)
  make_brake "$home"
  SYSTEMCTL=$(make_systemctl "$home")
  out="$home/arm.out"
  run_arm "$home" "$out"
  expect_code 0 "$?" "arm exit"

  touch -d '6 minutes ago' "$home/state/.capacity-brake-beat"
  out="$home/shim.out"
  env FM_CAPACITY_BRAKE_BEAT_GRACE=300 "$home/state/capacity-brake.check.sh" >"$out" 2>&1
  expect_code 0 "$?" "shim exit"
  grep -q "capacity-brake: beat" "$out" || fail "the armed shim did not dispatch the stale-beat alarm"
  pass "the registered check shim dispatches the real beat-age check"
}

# --- 4. disarm and fail-closed ----------------------------------------------

test_disarm_stops_and_removes_everything() {
  local home out
  home=$(make_home disarm)
  make_brake "$home"
  SYSTEMCTL=$(make_systemctl "$home")
  out="$home/arm.out"
  run_arm "$home" "$out"
  expect_code 0 "$?" "arm exit"

  out="$home/disarm.out"
  run_disarm "$home" "$out"
  expect_code 0 "$?" "disarm exit"
  assert_absent "$home/unit-dir/$UNIT_NAME" "disarm left the installed unit behind"
  grep -q "disable --now $UNIT_NAME" "$home/systemctl.log" || fail "disarm never disabled the unit"
  assert_absent "$home/state/capacity-brake.check.sh" "disarm left the beat check shim behind"
  assert_absent "$home/state/capacity-brake.check-trust" "disarm left the check trust binding behind"
  assert_grep "disarmed" "$out" "disarm did not report the outcome"
  pass "disarm stops and disables the unit, removes it, and unregisters the beat check"
}

test_arm_refuses_a_symlink_at_the_unit_destination() {
  local home out target
  home=$(make_home symlink)
  make_brake "$home"
  SYSTEMCTL=$(make_systemctl "$home")
  out="$home/arm.out"
  mkdir -p "$home/unit-dir"
  target="$home/not-the-unit.txt"
  printf 'a file the unit must not touch\n' > "$target"
  ln -s "$target" "$home/unit-dir/$UNIT_NAME"

  run_arm "$home" "$out"
  expect_code 1 "$?" "arm should refuse a symlink at the unit destination"
  [ "$(cat "$target")" = 'a file the unit must not touch' ] \
    || fail "arm followed the symlink and overwrote its target"
  pass "a symlink at the unit destination is refused instead of followed"
}

test_arm_installs_the_unit_with_restart_always
test_rearm_is_idempotent_and_never_starts_a_second_brake
test_arm_replaces_the_naked_loop
test_arm_refuses_to_kill_a_non_brake_lock_pid
test_arm_refuses_a_lock_pid_it_cannot_identify
test_arm_fails_closed_when_the_template_is_missing
test_check_is_silent_while_the_beat_is_fresh
test_check_alarms_when_the_beat_is_stale_or_absent
test_check_respects_the_grace_override
test_the_armed_shim_dispatches_the_check
test_disarm_stops_and_removes_everything
test_arm_refuses_a_symlink_at_the_unit_destination
