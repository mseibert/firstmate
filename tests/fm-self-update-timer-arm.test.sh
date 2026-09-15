#!/usr/bin/env bash
# tests/fm-self-update-timer-arm.test.sh - the self-update timer's arm helper
# (bin/fm-self-update-timer-arm.sh): tracked service+timer templates, idempotent
# arming, an unambiguous status, and a clean disarm.
#
# The captain's requirement (2026-09-15): a six-hour cadence for the
# fast-forward-only self-update pass, armed as systemd --user units like the
# existing capacity brake. systemd is driven through the
# FM_SELF_UPDATE_SYSTEMCTL seam and the unit destination through
# FM_SELF_UPDATE_UNIT_DIR, so the whole lifecycle is pinned deterministically
# without a real user manager.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ARM="$ROOT/bin/fm-self-update-timer-arm.sh"
TMP_ROOT=$(fm_test_tmproot fm-self-update-timer-arm)
SERVICE_UNIT=firstmate-self-update.service
TIMER_UNIT=firstmate-self-update.timer

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# Fake systemctl: tracks the timer's and the service's active/enabled state in
# marker files and logs every invocation, so a test can assert exactly how many
# starts a re-arm caused.
make_systemctl() {
  local home=$1
  cat > "$home/fake-systemctl.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$home/systemctl.log"
shift   # --user
cmd=\$1
shift
case "\$cmd" in
  is-active)
    case "\${1:-}" in
      $TIMER_UNIT) [ -f "$home/timer-active" ] && printf 'active\n' || printf 'inactive\n' ;;
      $SERVICE_UNIT) [ -f "$home/service-active" ] && printf 'active\n' || printf 'inactive\n' ;;
      *) printf 'inactive\n' ;;
    esac
    ;;
  is-enabled)
    case "\${1:-}" in
      $TIMER_UNIT) [ -f "$home/timer-enabled" ] && printf 'enabled\n' || printf 'disabled\n' ;;
      *) printf 'disabled\n' ;;
    esac
    ;;
  daemon-reload)
    ;;
  enable)
    [ "\${1:-}" = --now ] && shift
    case "\${1:-}" in
      $TIMER_UNIT) touch "$home/timer-enabled" "$home/timer-active" ;;
      $SERVICE_UNIT) touch "$home/service-enabled" "$home/service-active" ;;
    esac
    ;;
  start)
    [ "\${1:-}" = --now ] && shift
    case "\${1:-}" in
      $TIMER_UNIT) touch "$home/timer-active" ;;
      $SERVICE_UNIT) touch "$home/service-active" ;;
    esac
    ;;
  disable)
    [ "\${1:-}" = --now ] && shift
    case "\${1:-}" in
      $TIMER_UNIT) rm -f "$home/timer-enabled" "$home/timer-active" ;;
      $SERVICE_UNIT) rm -f "$home/service-enabled" "$home/service-active" ;;
    esac
    ;;
  stop)
    case "\${1:-}" in
      $TIMER_UNIT) rm -f "$home/timer-active" ;;
      $SERVICE_UNIT) rm -f "$home/service-active" ;;
    esac
    ;;
  *)
    printf 'fake systemctl: unknown command %s\n' "\$cmd" >&2
    exit 1
    ;;
esac
exit 0
SH
  chmod 0755 "$home/fake-systemctl.sh"
}

run_arm() {
  local home=$1 out=$2 status=0
  shift 2
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_SELF_UPDATE_SYSTEMCTL="$home/fake-systemctl.sh" \
    FM_SELF_UPDATE_UNIT_DIR="$home/unit-dir" \
    "$@" "$ARM" arm >"$out" 2>&1 || status=$?
  return "$status"
}

run_verb() {  # <home> <verb> <out>
  local home=$1 verb=$2 out=$3
  env FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_SELF_UPDATE_SYSTEMCTL="$home/fake-systemctl.sh" \
    FM_SELF_UPDATE_UNIT_DIR="$home/unit-dir" \
    "$ARM" "$verb" >"$out" 2>&1
}

# --- rendered-unit semantics -------------------------------------------------
# The installed units are machine-consumed configuration, so assert them as
# parsed directives rather than by grepping the file text: a commented-out or
# reformatted line must not satisfy an assertion, and the assertions name
# systemd's semantics (a single-valued key appears once; Environment= lines
# accumulate variable assignments).

parse_unit() {  # <file> -> "section<TAB>key<TAB>value" per directive
  local file=$1 line current='' key value
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    case "$line" in
      '#'*|';'*) continue ;;
    esac
    case "$line" in
      \[*\])
        current=${line#\[}
        current=${current%\]}
        continue
        ;;
    esac
    [ -n "$current" ] || continue
    case "$line" in
      *=*)
        key=${line%%=*}
        value=${line#*=}
        printf '%s\t%s\t%s\n' "$current" "$key" "$value"
        ;;
    esac
  done < "$file"
}

unit_directive() {  # <file> <section> <key> -> the single value
  local file=$1 section=$2 key=$3 s k v found='' have=no
  while IFS=$'\t' read -r s k v; do
    if [ "$s" != "$section" ] || [ "$k" != "$key" ]; then
      continue
    fi
    if [ "$have" = yes ]; then
      printf 'unit_directive: duplicate [%s] %s in %s\n' "$section" "$key" "$file" >&2
      return 1
    fi
    found=$v
    have=yes
  done < <(parse_unit "$file")
  [ "$have" = yes ] || return 1
  printf '%s\n' "$found"
}

unit_has_directive() {  # <file> <section> <key>
  local file=$1 section=$2 key=$3 s k v
  while IFS=$'\t' read -r s k v; do
    if [ "$s" = "$section" ] && [ "$k" = "$key" ]; then
      return 0
    fi
  done < <(parse_unit "$file")
  return 1
}

unit_environment() {  # <file> <variable> -> value assigned in [Service]
  local file=$1 variable=$2 s k v assignment found='' have=no
  while IFS=$'\t' read -r s k v; do
    if [ "$s" != Service ] || [ "$k" != Environment ]; then
      continue
    fi
    for assignment in $v; do
      case "$assignment" in
        "$variable"=*)
          found=${assignment#"$variable"=}
          have=yes
          ;;
      esac
    done
  done < <(parse_unit "$file")
  [ "$have" = yes ] || return 1
  printf '%s\n' "$found"
}

unit_has_placeholder() {  # <file> -> 0 when a template token remains
  local file=$1 s k v
  while IFS=$'\t' read -r s k v; do
    case "$v" in
      *'@FM_HOME@'*|*'@FM_SELF_UPDATE_RUN@'*) return 0 ;;
    esac
  done < <(parse_unit "$file")
  return 1
}

assert_unit_directive() {  # <file> <section> <key> <expected> <msg>
  local actual
  actual=$(unit_directive "$1" "$2" "$3") \
    || fail "$5 (no single [$2] $3 directive in $1)"
  [ "$actual" = "$4" ] || fail "$5 (expected '$4', got '$actual')"
}

assert_unit_directive_absent() {  # <file> <section> <key> <msg>
  if unit_has_directive "$1" "$2" "$3"; then
    fail "$4"
  fi
}

assert_unit_environment() {  # <file> <variable> <expected> <msg>
  local actual
  actual=$(unit_environment "$1" "$2") \
    || fail "$4 (no Environment $2= assignment in $1)"
  [ "$actual" = "$3" ] || fail "$4 (expected '$3', got '$actual')"
}

assert_path_has_dir() {  # <path-value> <directory> <msg>
  case ":$1:" in
    *":$2:"*) : ;;
    *) fail "$3 (missing '$2' in '$1')" ;;
  esac
}

# --- 1. install and idempotent arming ----------------------------------------

test_arm_installs_both_units_and_starts_the_timer() {
  local home out service timer service_path
  home=$(make_home install)
  make_systemctl "$home"
  out="$home/arm.out"
  run_arm "$home" "$out"
  expect_code 0 "$?" "arm exit"
  service="$home/unit-dir/$SERVICE_UNIT"
  timer="$home/unit-dir/$TIMER_UNIT"
  assert_present "$service" "arm did not install the service unit"
  assert_present "$timer" "arm did not install the timer unit"
  assert_unit_directive "$service" Service Type oneshot \
    "the service must be oneshot (the timer owns the cadence)"
  assert_unit_directive_absent "$service" Service Restart \
    "a oneshot pass must not carry a Restart= directive"
  assert_unit_directive "$service" Service TimeoutStartSec 30min \
    "the service must give the persist gate a generous timeout"
  assert_unit_directive "$service" Service ExecStart "$ROOT/bin/fm-self-update-timer.sh run" \
    "the service does not execute this repo's run wrapper"
  assert_unit_environment "$service" FM_HOME "$home" \
    "the service does not pin this home"
  service_path=$(unit_environment "$service" PATH) \
    || fail "the service does not set PATH for the gated restart"
  assert_path_has_dir "$service_path" '%h/.local/bin' \
    "the service PATH must let a local mate restart resolve a user-installed harness"
  assert_path_has_dir "$service_path" '%h/.npm-global/bin' \
    "the service PATH must let a local mate restart resolve a user-installed harness"
  if unit_has_placeholder "$service"; then
    fail "the installed service still carries an unrendered placeholder"
  fi
  assert_unit_directive "$timer" Timer OnCalendar '*-*-* 00,06,12,18:00:00' \
    "the timer lost the six-hour calendar"
  assert_unit_directive "$timer" Timer Persistent true \
    "the timer lost Persistent=true"
  assert_unit_directive "$timer" Timer Unit "$SERVICE_UNIT" \
    "the timer does not name the service unit"
  assert_unit_directive "$timer" Install WantedBy timers.target \
    "the timer is not installable into timers.target"
  grep -q "enable --now $TIMER_UNIT" "$home/systemctl.log" || fail "arm never enabled and started the timer"
  grep -q 'daemon-reload' "$home/systemctl.log" || fail "arm never reloaded the daemon"
  assert_grep 'armed' "$out" "arm did not report the armed outcome"
  pass "arm installs both units with the six-hour calendar and starts the timer"
}

test_rearm_is_idempotent() {
  local home out
  home=$(make_home rearm)
  make_systemctl "$home"
  out="$home/arm.out"
  run_arm "$home" "$out"
  expect_code 0 "$?" "first arm exit"
  run_arm "$home" "$out"
  expect_code 0 "$?" "re-arm exit"
  assert_grep 'already armed' "$out" "a re-arm against an active, enabled timer must confirm"
  [ "$(grep -c "enable --now $TIMER_UNIT" "$home/systemctl.log")" -eq 1 ] \
    || fail "re-arm started the timer again"
  [ "$(grep -c 'daemon-reload' "$home/systemctl.log")" -eq 1 ] \
    || fail "re-arm reloaded the daemon again for unchanged units"
  pass "re-arming an active, enabled timer confirms and changes nothing"
}

test_rearm_rewrites_changed_units() {
  local home out copy
  home=$(make_home rewrite)
  make_systemctl "$home"
  out="$home/arm.out"
  copy="$home/service.template"
  cp "$ROOT/docs/examples/systemd/$SERVICE_UNIT" "$copy"
  printf '\n[Service]\nEnvironment=FM_SELF_UPDATE_REARM_MARKER=marker\n' >> "$copy"
  run_arm "$home" "$out" FM_SELF_UPDATE_SERVICE_TEMPLATE="$copy"
  expect_code 0 "$?" "first arm exit"
  assert_unit_environment "$home/unit-dir/$SERVICE_UNIT" FM_SELF_UPDATE_REARM_MARKER marker \
    "a changed template was not rendered into the installed unit"
  [ "$(grep -c 'daemon-reload' "$home/systemctl.log")" -eq 1 ] || fail "the first install did not reload the daemon"
  run_arm "$home" "$out" FM_SELF_UPDATE_SERVICE_TEMPLATE="$copy"
  expect_code 0 "$?" "second arm exit"
  [ "$(grep -c 'daemon-reload' "$home/systemctl.log")" -eq 1 ] \
    || fail "an unchanged re-arm reloaded the daemon again"
  pass "re-arm rewrites only changed unit bytes"
}

# --- 2. status and disarm ----------------------------------------------------

test_status_reports_armed_state_log_and_pending() {
  local home out
  home=$(make_home status)
  make_systemctl "$home"
  run_arm "$home" "$home/arm.out"
  expect_code 0 "$?" "arm exit"
  printf '2026-09-15T14:20:01+0200 already current\n' > "$home/state/self-update-timer.log"
  printf 'nuc\n' > "$home/state/.self-update-pending-restarts"
  run_verb "$home" status "$home/status.out"
  expect_code 0 "$?" "status exit"
  out=$(cat "$home/status.out")
  assert_contains "$out" "$TIMER_UNIT - active, enabled" "status must name the active, enabled timer"
  assert_contains "$out" "$SERVICE_UNIT - inactive" "status must name the service state"
  assert_contains "$out" "$home/state/self-update-timer.log" "status must print the log path"
  assert_contains "$out" 'already current' "status must print the last log line"
  assert_contains "$out" 'pending:  nuc' "status must print the pending mates"
  pass "status reports the timer, service, log, last line, and pending restarts"
}

test_disarm_removes_units_and_keeps_state() {
  local home out
  home=$(make_home disarm)
  make_systemctl "$home"
  run_arm "$home" "$home/arm.out"
  expect_code 0 "$?" "arm exit"
  printf '2026-09-15T14:20:01+0200 already current\n' > "$home/state/self-update-timer.log"
  printf 'nuc\n' > "$home/state/.self-update-pending-restarts"

  out="$home/disarm.out"
  run_verb "$home" disarm "$out"
  expect_code 0 "$?" "disarm exit"
  assert_absent "$home/unit-dir/$SERVICE_UNIT" "disarm left the service unit behind"
  assert_absent "$home/unit-dir/$TIMER_UNIT" "disarm left the timer unit behind"
  grep -q "disable --now $TIMER_UNIT" "$home/systemctl.log" || fail "disarm never disabled the timer"
  grep -q "stop $SERVICE_UNIT" "$home/systemctl.log" || fail "disarm never stopped the service"
  assert_present "$home/state/self-update-timer.log" "disarm removed the run log"
  assert_present "$home/state/.self-update-pending-restarts" "disarm removed the pending-restart state"
  assert_grep 'disarmed' "$out" "disarm did not report the outcome"
  pass "disarm stops and removes both units but keeps the log and pending state"
}

# --- 3. fail-closed guards ---------------------------------------------------

test_arm_refuses_a_symlink_at_the_unit_destination() {
  local home out target
  home=$(make_home symlink)
  make_systemctl "$home"
  out="$home/arm.out"
  mkdir -p "$home/unit-dir"
  target="$home/not-the-unit.txt"
  printf 'a file the unit must not touch\n' > "$target"
  ln -s "$target" "$home/unit-dir/$TIMER_UNIT"
  run_arm "$home" "$out"
  expect_code 1 "$?" "arm should refuse a symlink at the timer destination"
  [ "$(cat "$target")" = 'a file the unit must not touch' ] \
    || fail "arm followed the symlink and overwrote its target"
  pass "a symlink at the timer destination is refused instead of followed"
}

test_arm_fails_closed_on_a_missing_template() {
  local home out
  home=$(make_home notemplate)
  make_systemctl "$home"
  out="$home/arm.out"
  run_arm "$home" "$out" FM_SELF_UPDATE_TIMER_TEMPLATE="$home/no-such.timer"
  expect_code 1 "$?" "arm should refuse a missing timer template"
  assert_absent "$home/unit-dir/$TIMER_UNIT" "arm installed a timer despite the missing template"
  pass "arm fails closed on a missing unit template"
}

test_arm_fails_closed_on_a_missing_run_wrapper() {
  local home out
  home=$(make_home norun)
  make_systemctl "$home"
  out="$home/arm.out"
  run_arm "$home" "$out" FM_SELF_UPDATE_RUN="$home/no-such-run.sh"
  expect_code 1 "$?" "arm should refuse a missing run wrapper"
  assert_absent "$home/unit-dir/$SERVICE_UNIT" "arm installed a service pointing at a missing wrapper"
  pass "arm fails closed when the run wrapper is missing"
}

test_arm_installs_both_units_and_starts_the_timer
test_rearm_is_idempotent
test_rearm_rewrites_changed_units
test_status_reports_armed_state_log_and_pending
test_disarm_removes_units_and_keeps_state
test_arm_refuses_a_symlink_at_the_unit_destination
test_arm_fails_closed_on_a_missing_template
test_arm_fails_closed_on_a_missing_run_wrapper
