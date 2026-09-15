#!/usr/bin/env bash
# fm-self-update-timer.sh - the run wrapper the self-update timer executes.
#
# bin/fm-self-update-timer-arm.sh installs firstmate-self-update.timer (every
# six hours, Persistent=true) and this wrapper is what its service runs. The
# pass itself is bin/fm-update.sh, unchanged: fast-forward only, never forcing,
# stashing, or discarding, and it leaves every gitignored operational dir alone.
# This wrapper adds the three things an unattended cadence needs:
#
#   1. A build-token gate. state/.build-token (the hardlink lock owned by the
#      home's build-token tooling, "<id> <pid>") means a build owns the
#      machine. While that owner is alive, or while an ownerless lock is
#      younger than the 20-minute age-rig, the run appends
#      "skipped: build token held" and exits 0, so the timer never competes
#      with a running Next.js build for memory. A stale lock - dead owner, or
#      ownerless past the age-rig - does not block the pass.
#   2. Gated restarts. bin/fm-update.sh restarts every live mate it left on the
#      target commit, including one that was already current, because a restart
#      is what re-resolves launch-time wiring. That is right for a hand-run
#      update and wrong for a timer: a naive cadence would restart an
#      already-current mate four times a day. This wrapper restarts a mate only
#      when its own home actually advanced ("updated <old>..<new>"), and never
#      restarts the primary's own session - it records the pass's
#      "reread-firstmate: yes|no" line for the running session instead.
#   3. Retry of unconfirmed restarts. A mate whose restart was attempted but
#      reported "nudged" or "unreached" is recorded in
#      state/.self-update-pending-restarts and retried on the next run even
#      without new progress, so no mate stays permanently on old wiring; a
#      confirmed restart clears the entry. This is the one deliberate exception
#      to "nothing new -> no restarts", because it is an actually pending
#      update rather than churn.
#
# The run log is state/self-update-timer.log: one quiet line for a run with
# nothing to report, and a bounded detailed record when a home advanced, a
# target was skipped, or a pending restart was retried. The log is the
# operator-facing surface; docs/configuration.md "Self-update timer" owns the
# operator contract.
#
# Usage:
#   fm-self-update-timer.sh run       run one pass (the timer service's ExecStart)
#   fm-self-update-timer.sh --help
#
# Deterministic test seams:
#   FM_SELF_UPDATE_UPDATE_BIN   update pass binary (default: <repo>/bin/fm-update.sh)
#   FM_SELF_UPDATE_RESTART_BIN  restart binary (default: <repo>/bin/fm-secondmate-restart.sh)
#   FM_SELF_UPDATE_LOG          run log path (default: $FM_HOME/state/self-update-timer.log)
#   FM_SELF_UPDATE_PENDING      pending-restart state file (default: $FM_HOME/state/.self-update-pending-restarts)
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

UPDATE_BIN="${FM_SELF_UPDATE_UPDATE_BIN:-$SCRIPT_DIR/fm-update.sh}"
RESTART_BIN="${FM_SELF_UPDATE_RESTART_BIN:-$SCRIPT_DIR/fm-secondmate-restart.sh}"
LOG="${FM_SELF_UPDATE_LOG:-$STATE/self-update-timer.log}"
PENDING="${FM_SELF_UPDATE_PENDING:-$STATE/.self-update-pending-restarts}"
TOKEN="$STATE/.build-token"
# The build token's own ownerless age-rig (state/build-token.sh: OWNERLESS_AGE).
TOKEN_OWNERLESS_AGE=1200

usage() {
  cat <<'EOF'
Usage:
  fm-self-update-timer.sh run       run one self-update pass (the timer service's ExecStart)
  fm-self-update-timer.sh --help    print this help
EOF
}

error() {
  printf 'fm-self-update-timer: %s\n' "$1" >&2
}

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
file_mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# --- log ---------------------------------------------------------------------
# One record per run, appended to the log and echoed for the unit journal. A
# record is the timestamped header line plus zero or more detail lines.
emit_record() {  # <header> [detail-line...]
  local ts
  ts=$(date +%Y-%m-%dT%H:%M:%S%z)
  mkdir -p -- "$(dirname -- "$LOG")" 2>/dev/null || true
  if ! {
    printf '%s %s\n' "$ts" "$1"
    shift
    [ "$#" -eq 0 ] || printf '%s\n' "$@"
  } | tee -a "$LOG"; then
    error "cannot append to $LOG"
    return 1
  fi
  return 0
}

# --- build token -------------------------------------------------------------
# Held means the lock names a live owner, or it is ownerless and younger than
# the age-rig. A stale lock - dead owner, or ownerless past the age-rig - does
# not block the pass. An unreadable or symlinked lock is treated as held (fail
# safe): a skipped run is retried on the next cadence, while a build collision
# is not recoverable.
token_held() {
  local pid mtime age
  [ -e "$TOKEN" ] || return 1
  [ ! -L "$TOKEN" ] || return 0
  pid=$(awk 'NR == 1 { print $2 }' "$TOKEN" 2>/dev/null || true)
  if [ -n "$pid" ]; then
    kill -0 "$pid" 2>/dev/null && return 0
    return 1
  fi
  mtime=$(file_mtime "$TOKEN")
  [ -n "$mtime" ] || return 0
  age=$(( $(date +%s) - mtime ))
  [ "$age" -lt "$TOKEN_OWNERLESS_AGE" ]
}

# --- pending restarts --------------------------------------------------------
# PENDING_IDS is this module's global accumulator, read by action_run.
PENDING_IDS=()

read_pending() {
  PENDING_IDS=()
  [ -f "$PENDING" ] && [ ! -L "$PENDING" ] || return 0
  local line id
  while IFS= read -r line || [ -n "$line" ]; do
    id=${line%%[[:space:]]*}
    case "$id" in
      ''|*[!A-Za-z0-9._-]*) continue ;;
    esac
    PENDING_IDS+=("$id")
  done < "$PENDING"
}

write_pending() {  # <id>...
  if [ "$#" -eq 0 ]; then
    rm -f -- "$PENDING"
    return 0
  fi
  local tmp
  tmp=$(mktemp "$STATE/.self-update-pending.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$@" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$PENDING"
}

# --- restart outcomes --------------------------------------------------------
# RESTART_OUT is the restart pass's captured output, read by the two helpers
# below. Matching is by literal prefix so an id containing dots stays literal.
RESTART_OUT=""

restart_line_for() {  # <id>
  local id=$1 line
  while IFS= read -r line; do
    case "$line" in
      "restarted: $id"|"restarted: $id "*|"nudged: $id:"*|"unreached: $id:"*)
        printf '%s\n' "$line"
        return 0
        ;;
    esac
  done <<< "$RESTART_OUT"
  return 1
}

outcome_for() {  # <id> -> restarted|nudged|unreached|unknown
  local line
  line=$(restart_line_for "$1") || { printf 'unknown\n'; return 0; }
  case "$line" in
    "restarted: "*) printf 'restarted\n' ;;
    "nudged: "*) printf 'nudged\n' ;;
    "unreached: "*) printf 'unreached\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# --- one pass ----------------------------------------------------------------

action_run() {
  local line id i
  local -a advanced=() detail=() restart_ids=() still_pending=()
  local primary_updated=no reread_line="" seen=" " pass_detail_count=0
  local update_out update_rc=0 restart_rc=0 hard_fail=no header outcome

  if [ ! -d "$FM_HOME" ]; then
    error "home directory is unavailable: $FM_HOME"
    return 1
  fi
  mkdir -p -- "$STATE" 2>/dev/null || true
  if [ ! -d "$STATE" ]; then
    error "state directory is unavailable: $STATE"
    return 1
  fi

  if token_held; then
    emit_record "skipped: build token held" || return 1
    return 0
  fi

  # The pass's own skip semantics (dirty, diverged, offline, wrong branch) stay
  # authoritative: this wrapper never forces, stashes, or discards anything.
  update_out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-}" \
    "$UPDATE_BIN" 2>&1) || update_rc=$?

  # Parse the pass's per-target lines. Only "updated" advances a mate and
  # therefore earns a restart; "already current" is left alone. The pass's two
  # action-summary lines are deliberately not read: they express the pass's own
  # unconditional restart policy, which this wrapper replaces with the
  # progress-gated one above. Every other non-"already current" line is kept for
  # the log, so a skip reason is recorded verbatim.
  while IFS= read -r line; do
    case "$line" in
      "firstmate: updated "*)
        primary_updated=yes
        detail+=("$line")
        ;;
      "firstmate: already current") ;;
      "firstmate: skipped: "*)
        detail+=("$line")
        ;;
      "secondmate "*": updated "*)
        id=${line#secondmate }
        id=${id%%:*}
        advanced+=("$id")
        detail+=("$line")
        ;;
      "secondmate "*": already current") ;;
      "secondmate "*": skipped: "*)
        detail+=("$line")
        ;;
      "remote secondmate "*": updated on "*)
        id=${line#remote secondmate }
        id=${id%%:*}
        advanced+=("$id")
        detail+=("$line")
        ;;
      "remote secondmate "*": already current on "*) ;;
      "remote secondmate "*": skipped on "*)
        detail+=("$line")
        ;;
      "reread-firstmate: "*)
        reread_line=$line
        ;;
      "restart-secondmates:"*|"nudge-secondmates:"*) ;;
      "") ;;
      *)
        detail+=("$line")
        ;;
    esac
  done <<< "$update_out"
  # Only pass-sourced lines decide between the "skipped" and "pending restart
  # retry" headers; the restart lines appended below are outcome detail.
  pass_detail_count=${#detail[@]}
  if [ "$update_rc" -ne 0 ]; then
    hard_fail=yes
    detail+=("failed: the update pass exited $update_rc")
  fi

  # This run's candidates: mates that actually advanced, plus mates already
  # awaiting a confirmed restart from an earlier run.
  read_pending
  for i in "${advanced[@]+"${advanced[@]}"}" "${PENDING_IDS[@]+"${PENDING_IDS[@]}"}"; do
    case "$seen" in
      *" $i "*) continue ;;
    esac
    seen="$seen$i "
    restart_ids+=("$i")
  done

  if [ "${#restart_ids[@]}" -gt 0 ]; then
    RESTART_OUT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$RESTART_BIN" "${restart_ids[@]}" 2>&1) || restart_rc=$?
  else
    RESTART_OUT=""
  fi
  case "$restart_rc" in
    0|3) ;;
    *)
      hard_fail=yes
      detail+=("failed: the restart pass exited $restart_rc")
      ;;
  esac

  for id in "${restart_ids[@]+"${restart_ids[@]}"}"; do
    outcome=$(outcome_for "$id")
    case "$outcome" in
      restarted)
        line=$(restart_line_for "$id") || line="restarted: $id"
        detail+=("$line")
        ;;
      nudged|unreached)
        line=$(restart_line_for "$id") || line="$outcome: $id"
        detail+=("$line [retry pending]")
        still_pending+=("$id")
        ;;
      *)
        detail+=("restart $id: no outcome reported [retry pending]")
        still_pending+=("$id")
        ;;
    esac
  done

  if [ "${#still_pending[@]}" -gt 0 ]; then
    write_pending "${still_pending[@]}" || {
      error "cannot write $PENDING"
      hard_fail=yes
    }
  else
    rm -f -- "$PENDING" 2>/dev/null || true
  fi

  if [ "$hard_fail" = yes ]; then
    header="failed"
  elif [ "$primary_updated" = yes ] || [ "${#advanced[@]}" -gt 0 ]; then
    header="updated"
  elif [ "$pass_detail_count" -gt 0 ]; then
    header="skipped"
  elif [ "${#restart_ids[@]}" -gt 0 ]; then
    header="pending restart retry"
  else
    header="already current"
  fi

  if [ "$header" = "already current" ]; then
    emit_record "already current" || return 1
    return 0
  fi
  detail+=("${reread_line:-reread-firstmate: no}")
  emit_record "$header" "${detail[@]+"${detail[@]}"}" || return 1
  [ "$hard_fail" = no ] || return 1
  return 0
}

case "${1:-run}" in
  run)
    action_run
    ;;
  --help|-h)
    usage
    ;;
  *)
    error "unknown action: $1"
    usage >&2
    exit 2
    ;;
esac
