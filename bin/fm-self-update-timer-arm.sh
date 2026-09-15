#!/usr/bin/env bash
# fm-self-update-timer-arm.sh - install, inspect, and remove the self-update
# timer under tracked systemd --user units.
#
# The captain's requirement: the fleet checks for a new state and builds it at
# least every six hours, instead of a hand-run /updatefirstmate. The pass
# (bin/fm-update.sh) is already built to run unattended - fast-forward only,
# never forcing or discarding, skipping what is dirty or diverged - and only
# needed a cadence. This helper owns that cadence's two moving parts:
#
#   1. The units. It renders the tracked service template
#      (docs/examples/systemd/firstmate-self-update.service) with this home's
#      paths and installs it plus the tracked timer template
#      (docs/examples/systemd/firstmate-self-update.timer) at
#      ~/.config/systemd/user/, then enables and starts the timer. The service
#      is Type=oneshot and the timer owns the cadence; unlike the capacity
#      brake's long-running loop, Restart=always does not apply. Re-arming an
#      unchanged, active, enabled timer confirms and changes nothing, so there
#      are never two cadences.
#   2. The run entry point. The service executes bin/fm-self-update-timer.sh run
#      (tracked, and the single owner of the run policy); this helper only
#      renders its path into the unit and never duplicates that policy.
#
# The private application step - arming this home - is a firstmate post-step
# after the change lands, exactly as it is for the capacity brake; this script
# is that step's tool. It never touches any other home, and proxmox, a separate
# firstmate, arms the same tracked code in its own home with its own timer.
# docs/configuration.md "Self-update timer" owns the operator-facing contract.
#
# Usage:
#   fm-self-update-timer-arm.sh arm      render+install both units, enable+start the timer
#   fm-self-update-timer-arm.sh disarm   stop+disable the timer, remove both units, keep log and pending state
#   fm-self-update-timer-arm.sh status   print timer/service state, log path and last line, pending restarts
#   fm-self-update-timer-arm.sh --help
#
# Deterministic test seams:
#   FM_SELF_UPDATE_SYSTEMCTL         systemctl binary (default: systemctl)
#   FM_SELF_UPDATE_UNIT_DIR          unit install directory (default: $HOME/.config/systemd/user)
#   FM_SELF_UPDATE_SERVICE_TEMPLATE  tracked service template (default: <repo>/docs/examples/systemd/firstmate-self-update.service)
#   FM_SELF_UPDATE_TIMER_TEMPLATE    tracked timer template (default: <repo>/docs/examples/systemd/firstmate-self-update.timer)
#   FM_SELF_UPDATE_SERVICE_UNIT      installed service unit name (default: firstmate-self-update.service)
#   FM_SELF_UPDATE_TIMER_UNIT        installed timer unit name (default: firstmate-self-update.timer)
#   FM_SELF_UPDATE_RUN               run wrapper rendered into the service (default: <repo>/bin/fm-self-update-timer.sh)
#   FM_SELF_UPDATE_LOG               run log path shown by status (default: $FM_HOME/state/self-update-timer.log)
#   FM_SELF_UPDATE_PENDING           pending-restart state file shown by status (default: $FM_HOME/state/.self-update-pending-restarts)
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

SYSTEMCTL="${FM_SELF_UPDATE_SYSTEMCTL:-systemctl}"
UNIT_DIR="${FM_SELF_UPDATE_UNIT_DIR:-$HOME/.config/systemd/user}"
SERVICE_TEMPLATE="${FM_SELF_UPDATE_SERVICE_TEMPLATE:-$FM_ROOT/docs/examples/systemd/firstmate-self-update.service}"
TIMER_TEMPLATE="${FM_SELF_UPDATE_TIMER_TEMPLATE:-$FM_ROOT/docs/examples/systemd/firstmate-self-update.timer}"
SERVICE_UNIT="${FM_SELF_UPDATE_SERVICE_UNIT:-firstmate-self-update.service}"
TIMER_UNIT="${FM_SELF_UPDATE_TIMER_UNIT:-firstmate-self-update.timer}"
RUN_BIN="${FM_SELF_UPDATE_RUN:-$SCRIPT_DIR/fm-self-update-timer.sh}"
LOG="${FM_SELF_UPDATE_LOG:-$STATE/self-update-timer.log}"
PENDING="${FM_SELF_UPDATE_PENDING:-$STATE/.self-update-pending-restarts}"

SERVICE_FILE="$UNIT_DIR/$SERVICE_UNIT"
TIMER_FILE="$UNIT_DIR/$TIMER_UNIT"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-self-update-timer-arm.sh arm      render+install both units, enable+start the timer
  fm-self-update-timer-arm.sh disarm   stop+disable the timer, remove both units, keep log and pending state
  fm-self-update-timer-arm.sh status   print timer/service state, log path and last line, pending restarts
  fm-self-update-timer-arm.sh --help
EOF
}

error() {
  printf 'fm-self-update-timer-arm: %s\n' "$1" >&2
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
# Render a tracked template (literal @FM_HOME@ and @FM_SELF_UPDATE_RUN@
# substitution) and install it at UNIT_DIR by rename. Refuses a symlink or a
# non-regular destination and rewrites only when the rendered bytes differ, so
# a re-arm does not churn the file or force an unnecessary daemon-reload.
# Sets UNIT_CHANGED=yes when a file was actually (re)written.
UNIT_CHANGED=no

render_template() {  # <template>
  local text rendered home
  home=$(resolve_home) || return 1
  text=$(cat "$1") || return 1
  rendered=${text//@FM_HOME@/$home}
  rendered=${rendered//@FM_SELF_UPDATE_RUN@/$RUN_BIN}
  printf '%s\n' "$rendered"
}

install_unit() {  # <template> <destination>
  local template=$1 dest=$2 rendered device tmp
  [ -d "$UNIT_DIR" ] && [ ! -L "$UNIT_DIR" ] || mkdir -p "$UNIT_DIR" || return 1
  device=$(fm_pr_file_device "$UNIT_DIR") || return 1
  fm_pr_regular_destination_on_device_or_absent "$dest" "$device" \
    || { error "refusing symlink or unusable path at $dest"; return 1; }
  rendered=$(render_template "$template") || return 1
  if [ -f "$dest" ] && [ ! -L "$dest" ] \
    && [ "$(cat "$dest" 2>/dev/null)" = "$rendered" ]; then
    return 0
  fi
  tmp=$(umask 022; mktemp "$UNIT_DIR/.fm-self-update.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$rendered" > "$tmp" \
    || ! chmod 0644 "$tmp" \
    || ! fm_pr_regular_destination_on_device_or_absent "$dest" "$device" \
    || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
  UNIT_CHANGED=yes
  return 0
}

# --- actions ----------------------------------------------------------------

action_arm() {
  local timer_state enabled_state
  [ -f "$SERVICE_TEMPLATE" ] && [ ! -L "$SERVICE_TEMPLATE" ] \
    || { error "service template missing: $SERVICE_TEMPLATE"; return 1; }
  [ -f "$TIMER_TEMPLATE" ] && [ ! -L "$TIMER_TEMPLATE" ] \
    || { error "timer template missing: $TIMER_TEMPLATE"; return 1; }
  [ -x "$RUN_BIN" ] || { error "run wrapper missing or not executable: $RUN_BIN"; return 1; }
  [ -d "$FM_HOME" ] && [ ! -L "$FM_HOME" ] \
    || { error "home directory is unavailable: $FM_HOME"; return 1; }

  UNIT_CHANGED=no
  install_unit "$SERVICE_TEMPLATE" "$SERVICE_FILE" \
    || { error "could not install $SERVICE_FILE"; return 1; }
  install_unit "$TIMER_TEMPLATE" "$TIMER_FILE" \
    || { error "could not install $TIMER_FILE"; return 1; }

  timer_state=$("$SYSTEMCTL" --user is-active "$TIMER_UNIT" 2>/dev/null || true)
  enabled_state=$("$SYSTEMCTL" --user is-enabled "$TIMER_UNIT" 2>/dev/null || true)
  if [ "$UNIT_CHANGED" = no ] && [ "$timer_state" = active ] && [ "$enabled_state" = enabled ]; then
    printf 'self-update timer: already armed %s (active, enabled); log %s\n' "$TIMER_UNIT" "$LOG"
    return 0
  fi

  if [ "$UNIT_CHANGED" = yes ]; then
    if ! "$SYSTEMCTL" --user daemon-reload >/dev/null 2>&1; then
      error "systemctl daemon-reload failed"
      return 1
    fi
  fi
  if ! "$SYSTEMCTL" --user enable --now "$TIMER_UNIT" >/dev/null 2>&1; then
    error "systemctl enable --now $TIMER_UNIT failed"
    return 1
  fi
  timer_state=$("$SYSTEMCTL" --user is-active "$TIMER_UNIT" 2>/dev/null || true)
  if [ "$timer_state" != active ]; then
    error "timer did not come up active (state: ${timer_state:-unknown})"
    return 1
  fi
  printf 'self-update timer: armed %s (active, enabled; unit at %s); log %s\n' \
    "$TIMER_UNIT" "$TIMER_FILE" "$LOG"
  return 0
}

action_disarm() {
  # Stop and disable best-effort: the units may not exist, and the wants
  # symlink may already be gone. The installed files are removed only when
  # they are regular files; a symlink at either path is refused rather than
  # followed, and both are checked before either is removed.
  local file
  for file in "$TIMER_FILE" "$SERVICE_FILE"; do
    if [ -L "$file" ]; then
      error "refusing to remove symlink at $file"
      return 1
    fi
  done
  "$SYSTEMCTL" --user disable --now "$TIMER_UNIT" >/dev/null 2>&1 || true
  "$SYSTEMCTL" --user stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
  "$SYSTEMCTL" --user daemon-reload >/dev/null 2>&1 || true
  for file in "$TIMER_FILE" "$SERVICE_FILE"; do
    [ -e "$file" ] || continue
    rm -f -- "$file" || { error "could not remove $file"; return 1; }
  done
  printf 'self-update timer: disarmed %s (timer stopped and disabled, unit files removed; log and pending restarts kept)\n' \
    "$TIMER_UNIT"
  return 0
}

action_status() {
  local timer_state enabled_state service_state last
  timer_state=$("$SYSTEMCTL" --user is-active "$TIMER_UNIT" 2>/dev/null || true)
  case "$timer_state" in
    active|inactive|failed|activating|deactivating) : ;;
    *) timer_state="unknown (systemctl did not answer)" ;;
  esac
  enabled_state=$("$SYSTEMCTL" --user is-enabled "$TIMER_UNIT" 2>/dev/null || true)
  case "$enabled_state" in
    enabled|disabled|static|masked) : ;;
    *) enabled_state="unknown" ;;
  esac
  service_state=$("$SYSTEMCTL" --user is-active "$SERVICE_UNIT" 2>/dev/null || true)
  case "$service_state" in
    active|inactive|failed|activating|deactivating) : ;;
    *) service_state="unknown" ;;
  esac

  printf 'self-update timer status:\n'
  printf '  timer:    %s - %s, %s' "$TIMER_UNIT" "$timer_state" "$enabled_state"
  if [ -f "$TIMER_FILE" ] && [ ! -L "$TIMER_FILE" ]; then
    printf ' (unit installed)\n'
  else
    printf ' (unit file missing)\n'
  fi
  printf '  service:  %s - %s' "$SERVICE_UNIT" "$service_state"
  if [ -f "$SERVICE_FILE" ] && [ ! -L "$SERVICE_FILE" ]; then
    printf ' (unit installed)\n'
  else
    printf ' (unit file missing)\n'
  fi
  printf '  run:      %s\n' "$RUN_BIN"
  printf '  log:      %s\n' "$LOG"
  if [ -f "$LOG" ] && [ ! -L "$LOG" ]; then
    last=$(tail -n 1 "$LOG" 2>/dev/null || true)
    printf '  last:     %s\n' "${last:-<empty>}"
  else
    printf '  last:     <no run recorded yet>\n'
  fi
  if [ -f "$PENDING" ] && [ ! -L "$PENDING" ] && [ -s "$PENDING" ]; then
    printf '  pending:  %s\n' "$(tr '\n' ' ' < "$PENDING")"
  else
    printf '  pending:  none\n'
  fi
  return 0
}

case "${1:-}" in
  arm)
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
