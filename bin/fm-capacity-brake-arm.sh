#!/usr/bin/env bash
# fm-capacity-brake-arm.sh - install, run, and self-report the capacity brake
# under a tracked systemd --user unit, replacing the naked bash loop.
#
# The captain's finding (2026-09-07/08): the capacity brake
# (state/capacity-brake.sh) ran as a naked bash pid with no systemd unit and no
# self-report, so the Paseo restart that emptied its cgroup left the brake dead
# for 17 hours without anyone seeing it. The watcher has its own liveness
# beacon; the brake had none, and that asymmetry was the gap.
#
# This helper is the tracked, tested hardening for that incident:
#
#   1. A tracked systemd --user unit TEMPLATE
#      (docs/examples/systemd/firstmate-capacity-brake.service) with
#      Restart=always, so the brake survives the next crash, reboot, or cgroup
#      cleanup. The template is never installed by hand; this helper renders
#      and installs it.
#   2. Idempotent arming: install the unit, enable and start it, and cleanly
#      replace the current naked loop. Re-arming a home whose unit is already
#      active confirms and changes nothing, so there are never two brake
#      processes.
#   3. Beat-age self-report: arming also registers a custom watcher check
#      (state/capacity-brake.check.sh) that prints one line when
#      state/.capacity-brake-beat is older than FM_CAPACITY_BRAKE_BEAT_GRACE
#      seconds, so a dead loop surfaces as a check wake instead of going silent
#      the way the incident's loop did.
#
# The private application step - installing this home's unit, enabling and
# starting it, replacing the current naked loop - is a documented firstmate
# post-step after this PR lands; this script is that step's tool.
#
# Usage:
#   fm-capacity-brake-arm.sh arm       render+install unit, enable+start, replace naked loop, arm beat check
#   fm-capacity-brake-arm.sh disarm    stop+disable unit, remove installed unit, unregister beat check
#   fm-capacity-brake-arm.sh status    print unit state, beat age, and check registration
#   fm-capacity-brake-arm.sh check     beat-age self-report: one line when stale, silent otherwise
#   fm-capacity-brake-arm.sh --help    print this help
#
# Deterministic test seams:
#   FM_CAPACITY_BRAKE_SYSTEMCTL   systemctl binary (default: systemctl)
#   FM_CAPACITY_BRAKE_UNIT_DIR    unit install directory (default: $HOME/.config/systemd/user)
#   FM_CAPACITY_BRAKE_TEMPLATE    tracked unit template (default: <repo>/docs/examples/systemd/firstmate-capacity-brake.service)
#   FM_CAPACITY_BRAKE_UNIT        installed unit name (default: firstmate-capacity-brake.service)
#   FM_CAPACITY_BRAKE_BEAT_GRACE  beat-age alarm threshold in seconds (default: 300)
#   FM_CAPACITY_BRAKE_STOP_WAIT   bounded seconds to wait for the naked loop to exit (default: 30)
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

SYSTEMCTL="${FM_CAPACITY_BRAKE_SYSTEMCTL:-systemctl}"
UNIT_DIR="${FM_CAPACITY_BRAKE_UNIT_DIR:-$HOME/.config/systemd/user}"
TEMPLATE="${FM_CAPACITY_BRAKE_TEMPLATE:-$FM_ROOT/docs/examples/systemd/firstmate-capacity-brake.service}"
UNIT="${FM_CAPACITY_BRAKE_UNIT:-firstmate-capacity-brake.service}"
GRACE="${FM_CAPACITY_BRAKE_BEAT_GRACE:-300}"
# The naked loop spends most of its time inside `sleep 20`, and bash defers a
# trapped TERM until the foreground sleep returns, so the stop can legitimately
# take one whole brake iteration. 30 comfortably exceeds the 20s interval.
STOP_WAIT="${FM_CAPACITY_BRAKE_STOP_WAIT:-30}"

CHECK_ID=capacity-brake
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
BRAKE="$FM_HOME/state/capacity-brake.sh"
BEAT="$STATE/.capacity-brake-beat"
LOCK="$STATE/.capacity-brake.lock"
UNIT_FILE="$UNIT_DIR/$UNIT"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
UNREGISTER_BIN="$SCRIPT_DIR/fm-check-unregister.sh"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-capacity-brake-arm.sh arm       install unit, enable+start, replace the naked loop, arm the beat check
  fm-capacity-brake-arm.sh disarm    stop+disable the unit, remove the installed unit, unregister the beat check
  fm-capacity-brake-arm.sh status    print unit state, beat age, and check registration
  fm-capacity-brake-arm.sh check     beat-age self-report: one line when stale, silent otherwise
  fm-capacity-brake-arm.sh --help    print this help
EOF
}

error() {
  printf 'fm-capacity-brake-arm: %s\n' "$1" >&2
}

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_cap_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# Resolve FM_HOME to an absolute path, the way the check shim embeds it.
resolve_home() {
  case "$FM_HOME" in
    /*) printf '%s\n' "$FM_HOME" ;;
    *)
      CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P || return 1
      ;;
  esac
}

# --- beat-age self-report ----------------------------------------------------
# One line only when the brake is not beating within GRACE seconds, nothing
# otherwise, so it composes with the watcher state-check contract: the watcher
# turns that line into a check wake and the beat stays silent while healthy.
action_check() {
  local age mtime
  if [ -e "$BEAT" ] && [ ! -L "$BEAT" ]; then
    mtime=$(fm_cap_stat_mtime "$BEAT")
    if [ -n "$mtime" ]; then
      age=$(( $(date +%s) - mtime ))
      if [ "$age" -ge "$GRACE" ]; then
        printf 'capacity-brake: beat %ss old (> %ss) - brake loop not beating; bin/fm-capacity-brake-arm.sh status\n' "$age" "$GRACE"
      fi
    else
      printf 'capacity-brake: beat %s unreadable - brake loop not beating; bin/fm-capacity-brake-arm.sh status\n' "$BEAT"
    fi
  else
    printf 'capacity-brake: no beat at %s - brake loop not running; bin/fm-capacity-brake-arm.sh status\n' "$BEAT"
  fi
  return 0
}

# --- naked-loop replacement --------------------------------------------------
# The brake's own lock (state/.capacity-brake.lock) names the running loop. A
# stale lock with a dead pid is harmless - capacity-brake.sh takes the lock over
# whenever its recorded pid is dead - so the only case to act on is a live pid.
# Before signaling, verify the pid is really the capacity brake and not some
# unrelated process that a stale or reused lock now points at; /proc may be
# absent (macOS), in which case the brake's own lock is trusted.
lock_pid_is_brake() {
  local pid=$1 cmd
  if [ -r "/proc/$pid/cmdline" ]; then
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
    case "$cmd" in
      *capacity-brake.sh*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

# Stop the naked loop and wait up to STOP_WAIT seconds for it to actually exit.
# Returns 1 when it is still alive after the wait: fail closed, because starting
# the unit's brake while a live naked loop holds the lock would just make the
# unit's copy exit and systemd restart it forever.
replace_naked_loop() {
  local pid deadline
  [ -f "$LOCK" ] && [ ! -L "$LOCK" ] || return 0
  pid=$(cat "$LOCK" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 0
  if ! lock_pid_is_brake "$pid"; then
    error "refusing to stop pid $pid from $LOCK: it is not the capacity brake"
    return 1
  fi
  kill -TERM "$pid" 2>/dev/null || true
  deadline=$(( $(date +%s) + STOP_WAIT ))
  while kill -0 "$pid" 2>/dev/null; do
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 0.2
  done
  if kill -0 "$pid" 2>/dev/null; then
    error "naked loop pid $pid still alive after ${STOP_WAIT}s; not starting a second brake"
    return 1
  fi
  return 0
}

# --- unit install ------------------------------------------------------------
# Render the tracked template (literal @FM_HOME@ substitution) and install it
# at UNIT_DIR/UNIT by rename. Refuses a symlink or a non-regular destination and
# rewrites only when the rendered bytes differ, so a re-arm does not churn the
# file or force an unnecessary daemon-reload.
render_template() {
  local text rendered
  text=$(cat "$TEMPLATE") || return 1
  rendered=${text//@FM_HOME@/$FM_HOME}
  printf '%s\n' "$rendered"
}

install_unit() {
  local rendered device tmp
  [ -d "$UNIT_DIR" ] && [ ! -L "$UNIT_DIR" ] || mkdir -p "$UNIT_DIR" || return 1
  device=$(fm_pr_file_device "$UNIT_DIR") || return 1
  fm_pr_regular_destination_on_device_or_absent "$UNIT_FILE" "$device" \
    || { error "refusing symlink or unusable path at $UNIT_FILE"; return 1; }
  rendered=$(render_template) || return 1
  if [ -f "$UNIT_FILE" ] && [ ! -L "$UNIT_FILE" ] \
    && [ "$(cat "$UNIT_FILE" 2>/dev/null)" = "$rendered" ]; then
    return 0
  fi
  tmp=$(umask 022; mktemp "$UNIT_DIR/.fm-capacity-brake.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$rendered" > "$tmp" \
    || ! chmod 0644 "$tmp" \
    || ! fm_pr_regular_destination_on_device_or_absent "$UNIT_FILE" "$device" \
    || ! mv -f -- "$tmp" "$UNIT_FILE"; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}

# --- beat check arming -------------------------------------------------------
# The watcher executes state/<id>.check.sh only after validating its bytes
# against the state/<id>.check-trust binding, so the shim is written by rename
# and registered with fm-check-register.sh. An unregistered shim is not inert -
# the watcher rejects it every cycle and wakes about unauthenticated checks - so
# the one rule after a failed or interrupted arm is that the home never holds a
# shim without a matching trust binding.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-capacity-brake-arm.sh - capacity brake beat-age poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-capacity-brake-arm.sh") check"
}

SHIM_WRITE_TMP=

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ] \
    && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-capacity-brake-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

# Keep a byte copy of a shim that is already in place, so a failed arm can put
# back the shim a working home was already using rather than an equivalent
# rewrite. The trust binding is over the bytes, so a rewrite would satisfy it
# too, but a home that was armed stays armed with what it had.
shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-capacity-brake-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

SHIM_BACKUP=

arm_check_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$SHIM_BACKUP" ]; then
    mv -f -- "$SHIM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$CHECK_SHIM"
    SHIM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

arm_check() {
  local want home
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { error "state directory is unavailable: $STATE"; return 1; }
  home=$(resolve_home) || { error "cannot resolve FM_HOME $FM_HOME"; return 1; }
  want=$(shim_content "$home")
  SHIM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    SHIM_BACKUP=$(shim_backup) || { error "could not save the existing $CHECK_SHIM"; return 1; }
  fi
  if ! shim_write "$want"; then
    arm_check_rollback
    error "could not write $CHECK_SHIM"
    return 1
  fi
  if ! "$REGISTER_BIN" "$CHECK_ID" >/dev/null 2>&1; then
    arm_check_rollback
    error "could not register $CHECK_SHIM"
    return 1
  fi
  SHIM_BACKUP=
  return 0
}

# --- actions ----------------------------------------------------------------

action_arm() {
  local unit_state
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] \
    || { error "unit template missing: $TEMPLATE"; return 1; }
  [ -x "$BRAKE" ] || { error "brake script missing or not executable: $BRAKE"; return 1; }
  [ -x "$REGISTER_BIN" ] || { error "check register helper missing: $REGISTER_BIN"; return 1; }
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { error "state directory is unavailable: $STATE"; return 1; }

  unit_state=$("$SYSTEMCTL" --user is-active "$UNIT" 2>/dev/null || true)
  if [ "$unit_state" = active ] || [ "$unit_state" = activating ]; then
    # Already under systemd: the lock's live pid (if any) is the unit's own
    # process, so re-arming must not touch it - that is the no-double-process
    # contract. Ensure the beat check is armed and confirm.
    arm_check || return 1
    printf 'capacity-brake: already armed %s active, beat check registered\n' "$UNIT"
    return 0
  fi

  if ! replace_naked_loop; then
    return 1
  fi
  if ! install_unit; then
    error "could not install $UNIT at $UNIT_FILE"
    return 1
  fi
  if ! "$SYSTEMCTL" --user daemon-reload >/dev/null 2>&1; then
    error "systemctl daemon-reload failed"
    return 1
  fi
  if ! "$SYSTEMCTL" --user enable --now "$UNIT" >/dev/null 2>&1; then
    error "systemctl enable --now $UNIT failed"
    return 1
  fi
  unit_state=$("$SYSTEMCTL" --user is-active "$UNIT" 2>/dev/null || true)
  if [ "$unit_state" != active ]; then
    error "unit did not come up active (state: ${unit_state:-unknown})"
    return 1
  fi
  if ! arm_check; then
    error "brake is running under $UNIT but its beat check could not be armed"
    return 1
  fi
  printf 'capacity-brake: armed %s active (unit at %s), beat check registered\n' "$UNIT" "$UNIT_FILE"
  return 0
}

action_disarm() {
  # Stop and disable best-effort: the unit may not exist, and the wants symlink
  # may already be gone. The installed unit file is removed only when it is a
  # regular file; a symlink at the path is refused rather than followed.
  "$SYSTEMCTL" --user disable --now "$UNIT" >/dev/null 2>&1 || true
  "$SYSTEMCTL" --user daemon-reload >/dev/null 2>&1 || true
  if [ -e "$UNIT_FILE" ] || [ -L "$UNIT_FILE" ]; then
    if [ -L "$UNIT_FILE" ]; then
      error "refusing to remove symlink at $UNIT_FILE"
      return 1
    fi
    rm -f -- "$UNIT_FILE" || { error "could not remove $UNIT_FILE"; return 1; }
  fi
  if [ -x "$UNREGISTER_BIN" ]; then
    "$UNREGISTER_BIN" "$CHECK_ID" >/dev/null 2>&1 || true
  fi
  printf 'capacity-brake: disarmed %s (unit removed, beat check unregistered)\n' "$UNIT"
  return 0
}

action_status() {
  local unit_state pid age
  unit_state=$("$SYSTEMCTL" --user is-active "$UNIT" 2>/dev/null || true)
  case "$unit_state" in
    active|inactive|failed|activating|deactivating) : ;;
    *) unit_state="unknown (systemctl did not answer)" ;;
  esac
  printf 'capacity-brake status:\n'
  printf '  unit:        %s (%s)\n' "$UNIT" "$unit_state"
  if [ -e "$BEAT" ] && [ ! -L "$BEAT" ]; then
    mtime=$(fm_cap_stat_mtime "$BEAT")
    if [ -n "$mtime" ]; then
      age=$(( $(date +%s) - mtime ))
      printf '  beat:        %s - %ss old\n' "$BEAT" "$age"
    else
      printf '  beat:        %s - unreadable (assume not beating)\n' "$BEAT"
    fi
  else
    printf '  beat:        %s - absent (not beating)\n' "$BEAT"
  fi
  if [ -f "$CHECK_TRUST" ] && [ ! -L "$CHECK_TRUST" ] \
    && [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    printf '  check:       %s - registered\n' "$CHECK_SHIM"
  else
    printf '  check:       %s - not armed\n' "$CHECK_SHIM"
  fi
  if [ "$unit_state" != active ] && [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
    pid=$(cat "$LOCK" 2>/dev/null || true)
    case "$pid" in
      ''|*[!0-9]*)
        printf '  naked loop:  unreadable lock at %s\n' "$LOCK"
        ;;
      *)
        if kill -0 "$pid" 2>/dev/null; then
          printf '  naked loop:  pid %s running outside the unit\n' "$pid"
        else
          printf '  naked loop:  stale lock at %s (pid %s dead)\n' "$LOCK" "$pid"
        fi
        ;;
    esac
  fi
  return 0
}

case "${1:-}" in
  check)
    case "$GRACE" in
      ''|*[!0-9]*|0)
        error "FM_CAPACITY_BRAKE_BEAT_GRACE must be a whole number of seconds"
        exit 2
        ;;
    esac
    action_check
    ;;
  arm)
    case "$GRACE" in
      ''|*[!0-9]*|0)
        error "FM_CAPACITY_BRAKE_BEAT_GRACE must be a whole number of seconds"
        exit 2
        ;;
    esac
    case "$STOP_WAIT" in
      ''|*[!0-9]*|0)
        error "FM_CAPACITY_BRAKE_STOP_WAIT must be a whole number of seconds"
        exit 2
        ;;
    esac
    action_arm
    ;;
  disarm)
    action_disarm
    ;;
  status)
    action_status
    ;;
  --help|-h|'')
    usage
    ;;
  *)
    error "unknown action: $1"
    usage >&2
    exit 2
    ;;
esac
