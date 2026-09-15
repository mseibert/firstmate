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
#   2. Gated restarts. bin/fm-update.sh names every live mate it left on the
#      target commit for restart, including one that was already current,
#      because a restart is what re-resolves launch-time wiring. That is right
#      for a hand-run update and wrong for a timer: a naive cadence would
#      restart an already-current mate four times a day. This wrapper restarts a
#      mate only when its own home actually advanced ("updated <old>..<new>"),
#      and only while the pass still classifies it as a live restart candidate;
#      a mate whose endpoint is dead or missing is left to startup recovery, and
#      a mate whose runtime can never prove a restart gets the pass's one-time
#      re-read nudge instead of an endless retry. The primary's own session is
#      never restarted - the pass's "reread-firstmate: yes|no" line is recorded
#      as the signal the operator or running session acts on.
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
# target was skipped, or a pending restart was retried. The pass's stderr
# diagnostics - fm-guard.sh's WATCHER DOWN banner and its reminders - stay on
# the unit journal and never become log detail. The log is the operator-facing
# surface; docs/configuration.md "Self-update timer" owns the operator contract.
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
# A build-token lock with no live owner older than this is treated as stale and
# does not block the run, matching the 20-minute ownerless age-rig the home's
# build-token tooling applies when it reclaims such a lock.
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

write_pending() {  # <id>... (never called empty; the caller removes the file instead)
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

# Normalize a "restart-secondmates:"/"nudge-secondmates:" summary line into a
# space-padded id set (" " when empty), so membership is a literal match.
window_set() {  # <summary-line>
  local rest=${1#*:} tok id out=" "
  local -a tokens=()
  read -r -a tokens <<< "$rest"
  for tok in "${tokens[@]+"${tokens[@]}"}"; do
    [ "$tok" = none ] && continue
    id=${tok#fm-}
    case "$id" in
      ''|*[!A-Za-z0-9._-]*) continue ;;
    esac
    out="$out$id "
  done
  printf '%s\n' "$out"
}

in_spaced_set() {  # <spaced-set> <id>
  case "$1" in
    *" $2 "*) return 0 ;;
  esac
  return 1
}

# --- one pass ----------------------------------------------------------------

action_run() {
  local line id i
  local -a advanced=() detail=() attempt_ids=() retry_pending=() keep_pending=()
  local primary_updated=no reread_line="" seen=" " pending_set=" " skip_count=0
  local restart_live=" " nudge_live=" " skipped_ids=" " saw_summary=no
  local update_out update_err update_err_file update_rc=0 restart_rc=0
  local hard_fail=no restart_failed=no header outcome

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
  # authoritative: this wrapper never forces, stashes, or discards anything. Its
  # stdout carries the per-target status lines this wrapper parses; its stderr
  # carries diagnostics (fm-guard.sh's WATCHER DOWN banner, a failed remote
  # route, malformed registry entries) that belong on the unit journal and must
  # not become log detail or force the "skipped" header. The two streams are
  # staged separately because the banner would otherwise be parsed as if it
  # were a pass status line.
  update_err_file=$(mktemp "$STATE/.self-update-timer-stderr.XXXXXX" 2>/dev/null) || update_err_file=""
  if [ -n "$update_err_file" ]; then
    update_out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-}" \
      "$UPDATE_BIN" 2>"$update_err_file") || update_rc=$?
    update_err=$(cat "$update_err_file" 2>/dev/null || true)
    rm -f -- "$update_err_file"
  else
    # Cannot stage stderr: let it reach the unit journal directly and parse
    # stdout only, so a diagnostic still never masquerades as a pass status.
    update_out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-}" \
      "$UPDATE_BIN") || update_rc=$?
    update_err=""
  fi

  # Parse the pass's per-target stdout lines. Only "updated" advances a mate and
  # therefore earns a restart; "already current" is left alone. The pass's two
  # action-summary lines name which settled mates are live restart candidates
  # and which are live but can never prove a restart, and that classification is
  # authoritative for this wrapper too. A recognized skip line is recorded
  # verbatim and is the only pass line that drives the "skipped" header; any
  # other stdout line is still kept for the log (failure output) but is not
  # itself a skip.
  while IFS= read -r line; do
    case "$line" in
      "firstmate: updated "*)
        primary_updated=yes
        detail+=("$line")
        ;;
      "firstmate: already current") ;;
      "firstmate: skipped: "*)
        detail+=("$line")
        skip_count=$((skip_count + 1))
        ;;
      "secondmate "*": updated "*)
        id=${line#secondmate }
        id=${id%%:*}
        advanced+=("$id")
        detail+=("$line")
        ;;
      "secondmate "*": already current") ;;
      "secondmate "*": skipped: "*)
        id=${line#secondmate }
        id=${id%%:*}
        skipped_ids="$skipped_ids$id "
        detail+=("$line")
        skip_count=$((skip_count + 1))
        ;;
      "remote secondmate "*": updated on "*)
        id=${line#remote secondmate }
        id=${id%%:*}
        advanced+=("$id")
        detail+=("$line")
        ;;
      "remote secondmate "*": already current on "*) ;;
      "remote secondmate "*": skipped on "*)
        id=${line#remote secondmate }
        id=${id%%:*}
        skipped_ids="$skipped_ids$id "
        detail+=("$line")
        skip_count=$((skip_count + 1))
        ;;
      "reread-firstmate: "*)
        reread_line=$line
        ;;
      "restart-secondmates:"*)
        restart_live=$(window_set "$line")
        saw_summary=yes
        ;;
      "nudge-secondmates:"*)
        nudge_live=$(window_set "$line")
        saw_summary=yes
        ;;
      "") ;;
      *)
        detail+=("$line")
        ;;
    esac
  done <<< "$update_out"
  # A recognized skip line on stderr (an unreachable remote route) is pass
  # status too and is recorded the same way; every other stderr line is a
  # diagnostic and is forwarded to the unit journal instead.
  if [ -n "$update_err" ]; then
    while IFS= read -r line; do
      case "$line" in
        "firstmate: skipped: "*)
          detail+=("$line")
          skip_count=$((skip_count + 1))
          ;;
        "secondmate "*": skipped: "*)
          id=${line#secondmate }
          id=${id%%:*}
          skipped_ids="$skipped_ids$id "
          detail+=("$line")
          skip_count=$((skip_count + 1))
          ;;
        "remote secondmate "*": skipped on "*)
          id=${line#remote secondmate }
          id=${id%%:*}
          skipped_ids="$skipped_ids$id "
          detail+=("$line")
          skip_count=$((skip_count + 1))
          ;;
        *)
          printf '%s\n' "$line" >&2
          ;;
      esac
    done <<< "$update_err"
  fi
  if [ "$update_rc" -ne 0 ]; then
    hard_fail=yes
    detail+=("failed: the update pass exited $update_rc")
  fi

  # Restart candidacy belongs to the pass: only it knows which mates are live
  # and whose runtime can prove a restart. A home that advanced while its
  # endpoint is dead or missing is left to the ordinary startup recovery; a
  # mate whose runtime can never prove a restart gets the pass's one-time
  # re-read nudge and is never retried; a pending retry is attempted only while
  # the pass still classifies that mate as restart-capable; and a pending mate
  # whose home was skipped this run keeps waiting untouched. An incomplete pass
  # output (no action summary) falls back to attempting every known candidate,
  # so a transient pass failure can never silently drop a pending retry.
  read_pending
  for i in "${PENDING_IDS[@]+"${PENDING_IDS[@]}"}"; do
    pending_set="$pending_set$i "
  done
  seen=" "
  for i in "${advanced[@]+"${advanced[@]}"}" "${PENDING_IDS[@]+"${PENDING_IDS[@]}"}"; do
    case "$seen" in
      *" $i "*) continue ;;
    esac
    seen="$seen$i "
    if [ "$saw_summary" = no ] \
      || in_spaced_set "$restart_live" "$i" \
      || in_spaced_set "$nudge_live" "$i"; then
      attempt_ids+=("$i")
    elif in_spaced_set "$pending_set" "$i" && in_spaced_set "$skipped_ids" "$i"; then
      keep_pending+=("$i")
    elif in_spaced_set "$pending_set" "$i"; then
      detail+=("restart $i: dropped - no longer a live restart candidate")
    else
      detail+=("restart $i: skipped - no live agent to replace (startup recovery owns it)")
    fi
  done

  # The attempted set is made durable before the restart pass runs, so a run
  # the unit's TimeoutStartSec kills mid-restart leaves the retry for the next
  # cadence instead of losing it.
  if [ "${#attempt_ids[@]}" -gt 0 ] || [ "${#keep_pending[@]}" -gt 0 ]; then
    write_pending "${attempt_ids[@]+"${attempt_ids[@]}"}" "${keep_pending[@]+"${keep_pending[@]}"}" || {
      error "cannot write $PENDING"
      hard_fail=yes
    }
  else
    rm -f -- "$PENDING" 2>/dev/null || true
  fi

  if [ "${#attempt_ids[@]}" -gt 0 ]; then
    RESTART_OUT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$RESTART_BIN" "${attempt_ids[@]}" 2>&1) || restart_rc=$?
  else
    RESTART_OUT=""
  fi
  case "$restart_rc" in
    0|3) ;;
    *)
      hard_fail=yes
      restart_failed=yes
      detail+=("failed: the restart pass exited $restart_rc")
      ;;
  esac

  for id in "${attempt_ids[@]+"${attempt_ids[@]}"}"; do
    outcome=$(outcome_for "$id")
    case "$outcome" in
      restarted)
        line=$(restart_line_for "$id") || line="restarted: $id"
        detail+=("$line")
        ;;
      nudged|unreached)
        line=$(restart_line_for "$id") || line="$outcome: $id"
        if [ "$restart_failed" = yes ] || in_spaced_set "$restart_live" "$id"; then
          detail+=("$line [retry pending]")
          retry_pending+=("$id")
        else
          detail+=("$line [nudge only]")
        fi
        ;;
      *)
        if [ "$restart_failed" = yes ] || in_spaced_set "$restart_live" "$id"; then
          detail+=("restart $id: no outcome reported [retry pending]")
          retry_pending+=("$id")
        else
          detail+=("restart $id: no outcome reported [nudge only]")
        fi
        ;;
    esac
  done

  for i in "${keep_pending[@]+"${keep_pending[@]}"}"; do
    retry_pending+=("$i")
  done
  if [ "${#retry_pending[@]}" -gt 0 ]; then
    write_pending "${retry_pending[@]}" || {
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
  elif [ "$skip_count" -gt 0 ]; then
    header="skipped"
  elif [ "${#attempt_ids[@]}" -gt 0 ]; then
    header="pending restart retry"
  else
    header="already current"
  fi

  if [ "$header" = "already current" ] && [ "${#detail[@]}" -eq 0 ]; then
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
