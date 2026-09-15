#!/usr/bin/env bash
# fm-captain-context-watch-arm.sh - install, remove, and inspect the captain
# context watch under a tracked systemd --user unit.
#
# The watch itself (bin/fm-captain-context-watch.sh) must survive the session it
# restarts, so it never runs inside that session: it runs under
# firstmate-captain-context-watch.service with Restart=always, exactly like the
# capacity brake's unit. This helper owns the other two moving parts:
#
#   1. The unit. It renders the tracked template
#      (docs/examples/systemd/firstmate-captain-context-watch.service) with this
#      home's paths and installs it at ~/.config/systemd/user/, then enables and
#      starts it. Re-arming an active unit only re-confirms it, so there are
#      never two loops.
#   2. The liveness check. It writes and registers
#      state/captain-context-watch.check.sh, which execs
#      bin/fm-captain-context-watch.sh check; the watcher dispatches it on its
#      normal cadence and turns one line into a check wake, so a dead loop or a
#      stalled persist gate surfaces instead of going silent.
#
# The private application step - arming this home - is a firstmate post-step
# after the change lands, exactly as it is for the capacity brake; this script
# is that step's tool. It never touches any other home.
#
# Usage:
#   fm-captain-context-watch-arm.sh arm      render+install unit, enable+start, replace a naked loop, arm the check
#   fm-captain-context-watch-arm.sh disarm   stop+disable unit, remove it, unregister the check
#   fm-captain-context-watch-arm.sh status   print unit state, beat age, check registration, and the watch's own status
#   fm-captain-context-watch-arm.sh --help
#
# Deterministic test seams:
#   FM_CCW_SYSTEMCTL   systemctl binary (default: systemctl)
#   FM_CCW_UNIT_DIR    unit install directory (default: $HOME/.config/systemd/user)
#   FM_CCW_UNIT        installed unit name (default: firstmate-captain-context-watch.service)
#   FM_CCW_TEMPLATE    tracked unit template (default: <repo>/docs/examples/systemd/firstmate-captain-context-watch.service)
#   FM_CCW_STOP_WAIT   bounded seconds to wait for a naked loop to exit (default: 30)
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

SYSTEMCTL="${FM_CCW_SYSTEMCTL:-systemctl}"
UNIT_DIR="${FM_CCW_UNIT_DIR:-$HOME/.config/systemd/user}"
TEMPLATE="${FM_CCW_TEMPLATE:-$FM_ROOT/docs/examples/systemd/firstmate-captain-context-watch.service}"
UNIT="${FM_CCW_UNIT:-firstmate-captain-context-watch.service}"
STOP_WAIT="${FM_CCW_STOP_WAIT:-30}"

WATCH="$SCRIPT_DIR/fm-captain-context-watch.sh"
CHECK_ID=captain-context-watch
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
LOCK="$STATE/.captain-context-watch.lock"
BEAT="$STATE/.captain-context-watch-beat"
UNIT_FILE="$UNIT_DIR/$UNIT"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
UNREGISTER_BIN="$SCRIPT_DIR/fm-check-unregister.sh"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-unit-install-lib.sh
. "$SCRIPT_DIR/fm-unit-install-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-captain-context-watch-arm.sh arm      render+install unit, enable+start, replace a naked loop, arm the check
  fm-captain-context-watch-arm.sh disarm   stop+disable unit, remove it, unregister the check
  fm-captain-context-watch-arm.sh status   print unit state, beat age, check registration, and the watch's own status
  fm-captain-context-watch-arm.sh --help
EOF
}

error() {
  printf 'fm-captain-context-watch-arm: %s\n' "$1" >&2
}

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_ccw_arm_mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

resolve_home() {
  case "$FM_HOME" in
    /*) printf '%s\n' "$FM_HOME" ;;
    *)
      CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P || return 1
      ;;
  esac
}

# --- unit install ------------------------------------------------------------
# The render/install mechanics live once in bin/fm-unit-install-lib.sh; this
# wrapper supplies this home's substitutions.
install_unit() {
  local home
  home=$(resolve_home) || { error "cannot resolve FM_HOME $FM_HOME"; return 1; }
  fm_unit_install "$UNIT_DIR" "$TEMPLATE" "$UNIT_FILE" \
    "@FM_HOME@=$home" "@FM_CCW_WATCH@=$WATCH" \
    || { error "${FM_UNIT_ERROR:-could not install $UNIT_FILE}"; return 1; }
}

# --- naked-loop replacement --------------------------------------------------
# A live loop outside the unit holds the same lock. Starting the unit while it
# runs would make the unit's copy exit on the lock and systemd restart it
# forever, so arm stops the naked loop first - and only a process that really is
# this watch, never a stale or reused lock pid.
lock_pid_is_watch() {
  local pid=$1 cmd
  if [ -r "/proc/$pid/cmdline" ]; then
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
    case "$cmd" in
      *fm-captain-context-watch.sh*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

replace_naked_loop() {
  local pid deadline
  [ -f "$LOCK" ] && [ ! -L "$LOCK" ] || return 0
  pid=$(cat "$LOCK" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 0
  if ! lock_pid_is_watch "$pid"; then
    error "refusing to stop pid $pid from $LOCK: it is not the captain context watch"
    return 1
  fi
  kill -TERM "$pid" 2>/dev/null || true
  deadline=$(( $(date +%s) + STOP_WAIT ))
  while kill -0 "$pid" 2>/dev/null; do
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 0.2
  done
  if kill -0 "$pid" 2>/dev/null; then
    error "naked watch pid $pid still alive after ${STOP_WAIT}s; not starting a second watch"
    return 1
  fi
  rm -f -- "$LOCK"
  return 0
}

# --- check arming ------------------------------------------------------------
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
    '# Auto-generated by fm-captain-context-watch-arm.sh - captain context watch poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted watch script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$WATCH") check"
}

SHIM_WRITE_TMP=
SHIM_BACKUP=

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
  tmp=$(umask 077; mktemp "$STATE/.fm-captain-context-watch-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-captain-context-watch-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

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
  local unit_state target threshold
  [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] \
    || { error "unit template missing: $TEMPLATE"; return 1; }
  [ -x "$WATCH" ] || { error "watch script missing or not executable: $WATCH"; return 1; }
  [ -x "$REGISTER_BIN" ] || { error "check register helper missing: $REGISTER_BIN"; return 1; }
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { error "state directory is unavailable: $STATE"; return 1; }
  target=${FM_CCW_TARGET:-firstmate:captain}
  threshold=${FM_CCW_THRESHOLD:-500000}

  unit_state=$("$SYSTEMCTL" --user is-active "$UNIT" 2>/dev/null || true)
  if [ "$unit_state" = active ] || [ "$unit_state" = activating ]; then
    arm_check || return 1
    printf 'captain-context-watch: already armed %s active (target %s, threshold %s)\n' \
      "$UNIT" "$target" "$threshold"
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
  # Seed the beat so the freshly armed check does not alarm before the loop's
  # first cycle. The loop owns the beat from then on.
  umask 077
  : > "$BEAT" 2>/dev/null || true
  if ! arm_check; then
    error "the watch is running under $UNIT but its check could not be armed"
    return 1
  fi
  printf 'captain-context-watch: armed %s active (unit at %s, target %s, threshold %s)\n' \
    "$UNIT" "$UNIT_FILE" "$target" "$threshold"
  return 0
}

action_disarm() {
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
  # A disarmed watch must not leave a release gate behind: the request and
  # answer are transient, while the journal and state remain as evidence. The
  # lock is deliberately left alone - it belongs to whatever loop holds it, and
  # a stale one is taken over by the next loop anyway.
  rm -f -- "$STATE/.captain-context-watch.request" "$STATE/.captain-context-watch.answer" \
    "$STATE/.captain-context-watch.notified"
  printf 'captain-context-watch: disarmed %s (unit removed, check unregistered)\n' "$UNIT"
  return 0
}

action_status() {
  local unit_state age mtime
  unit_state=$("$SYSTEMCTL" --user is-active "$UNIT" 2>/dev/null || true)
  case "$unit_state" in
    active|inactive|failed|activating|deactivating) ;;
    *) unit_state="unknown (systemctl did not answer)" ;;
  esac
  printf 'captain-context-watch arm status:\n'
  printf '  unit:   %s (%s)\n' "$UNIT" "$unit_state"
  if [ -e "$BEAT" ] && [ ! -L "$BEAT" ]; then
    mtime=$(fm_ccw_arm_mtime "$BEAT")
    if [ -n "$mtime" ]; then
      age=$(( $(date +%s) - mtime ))
      printf '  beat:   %s - %ss old\n' "$BEAT" "$age"
    else
      printf '  beat:   %s - unreadable (assume not beating)\n' "$BEAT"
    fi
  else
    printf '  beat:   %s - absent (not beating)\n' "$BEAT"
  fi
  if [ -f "$CHECK_TRUST" ] && [ ! -L "$CHECK_TRUST" ] \
    && [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    printf '  check:  %s - registered\n' "$CHECK_SHIM"
  else
    printf '  check:  %s - not armed\n' "$CHECK_SHIM"
  fi
  [ -x "$WATCH" ] || return 0
  printf '\n'
  "$WATCH" status
  return 0
}

case "${1:-}" in
  arm) action_arm ;;
  disarm) action_disarm ;;
  status) action_status ;;
  -h|--help|'') usage ;;
  *) error "unknown action: $1"; usage >&2; exit 2 ;;
esac
