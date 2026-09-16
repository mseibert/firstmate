#!/usr/bin/env bash
# fm-park.sh - the operating-point release: park a waiting task, resume it later.
#
# WHY THIS EXISTS. A worker that reports `done:` and now only waits for a merge
# or a captain decision still occupies its worker slot: its endpoint is alive,
# its pane looks idle, and the next dispatch sees a full operating point with
# nothing actually running. The captain's rule is that waiting work must not
# occupy the point: the work is handed off in the PR, status log, and backlog,
# the slot is released, and the task is resumed later as a short run.
#
# This script is the single owner of that release. `park` stops the worker
# through bin/fm-control.sh `exit` - which preserves the endpoint, the worktree,
# and every uncommitted change - after recording a durable marker, one status
# line, and a backlog note naming the handoff. `resume` brings the same task
# back with a short relaunch note. Nothing here discards work, merges, or tears
# down; bin/fm-teardown.sh still owns the complete landed-work test.
#
# Usage:
#   fm-park.sh park <task-id>
#   fm-park.sh resume <task-id> --reason merge|decision [--note <text>]
#   fm-park.sh clear <task-id> [--reason <text>]
#   fm-park.sh list
#   fm-park.sh status <task-id>
#   fm-park.sh sweep [--limit <n>]
#   fm-park.sh --help
#
#   park    Check eligibility and release the task's slot. Eligibility is: not
#           a secondmate, no actively working pipeline run, and a provable
#           handoff. A no-mistakes run parked at an ask-user/authority gate is a
#           decision wait whose pointer is the gate's open keyed decision; the
#           gate's canonical current-state detail carries the
#           `(ask-user: authority decision)` marker only for a non-fix_review
#           gate whose findings table has an ask-user action, and a run parked
#           at any other gate (fix-review) is refused because the worker must
#           answer that gate, so it is not waiting on firstmate or the captain;
#           a gate-free task uses an open keyed
#           `needs-decision`/`blocked` status decision, a captain-held backlog
#           row, or a recorded `pr=` on a `done`/`parked` crew. The run-step gate
#           facts come from the canonical current-state line, never from a
#           second attribution of no-mistakes records. A run parked at a gate
#           whose decision key is not recorded refuses rather than guessing. The
#           action writes the marker (state=releasing), appends the status line,
#           records the backlog note, then verifies the stop and rewrites the
#           marker state=released. An already-released task is idempotent success
#           with no second exit. A marker left at state=releasing (an interrupted
#           or failed release) is retried.
#   resume  Require a released marker whose reason matches --reason, relaunch
#           the worker through bin/fm-control.sh with a short note for that
#           reason, then remove the marker. --note carries the captain's
#           decision words for reason=decision.
#   clear   Remove a marker without relaunching, for a landing that is trivially
#           and cleanly complete so firstmate can go straight to cleanup. A
#           teardown never depends on a worker relaunch.
#   list    Machine-readable TSV of every parked task, one row per marker:
#           id, reason, pointer, branch, pr, epoch, incarnation, state.
#   status  One line for one task: `parked <id> reason=... ...` (exit 0) for a
#           released marker, `releasing <id> reason=... ...` (exit 1) for a
#           recorded but unverified release, `stale <id> ...` (exit 1) for a
#           marker recorded by an earlier incarnation, or `not-parked <id>`
#           (exit 1).
#   sweep   Bounded session-start/heartbeat housekeeping: find eligible but
#           unmarked tasks and park them. Silent on success apart from a manual
#           home's owed backlog note on stderr; a failed release prints one
#           PARK_SWEEP line so the caller can surface it. Bounded by
#           --limit (default FM_PARK_SWEEP_LIMIT, 2) and by
#           FM_PARK_SWEEP_BUDGET_SECS (default 20) of wall clock checked
#           between tasks, and best-effort: a sweep cut off by the startup
#           bound leaves every task as it found it and the next session or
#           heartbeat retries.
#
# The marker `state/<id>.parked` is schema fm-park.v1; docs/park-release.md
# owns the field table and the `releasing`/`released` semantics. Every reader
# goes through bin/fm-park-lib.sh, so the current-state line (`parked` with
# source `park-marker`), the watcher's expected-stop predicate, the startup
# digest's liveness line, and this script agree on which markers count: only a
# regular fm-park.v1 file naming this task and recording the task's CURRENT
# incarnation is live, and a marker left by an earlier incarnation (a
# control-plane relaunch outside this script) is stale and drops out.
# bin/fm-fleet-snapshot.sh counts only `working` tasks as the active operating
# point. bin/fm-teardown.sh removes the marker with the rest of the task record.
#
# The backlog note is written through the configured backend under the same
# gate rules as every other lifecycle mutation (docs/configuration.md "Backlog
# backend"): with an automatic backend and compatible tasks-axi the note is
# recorded with `tasks-axi update --body-file --archive-body`; a manual-backend
# home keeps its backlog hand-edited and park prints the exact note owed on
# stderr, so a caller that discards park's stdout still surfaces it; an
# automatic-backend home with an unresolvable or incompatible backend is
# refused before any mutation.
#
# Fail-closed boundaries: an unclear state refuses loudly rather than guessing;
# a running pipeline run is never parked; a secondmate is never parked; a stop
# that cannot be verified is reported as a failed release, never as parked; the
# per-task supervision lease guards the whole mutation, not only the stop.
#
# Environment knobs:
#   FM_PARK_CONTROL_BIN       control-plane binary (default bin/fm-control.sh)
#   FM_PARK_CREW_STATE_BIN    current-state reader (default bin/fm-crew-state.sh)
#   FM_PARK_NOW_EPOCH         park epoch override for deterministic tests
#   FM_PARK_SWEEP_LIMIT       max park attempts per sweep (default 2)
#   FM_PARK_SWEEP_BUDGET_SECS sweep wall-clock budget (default 20)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  # The whole leading comment block, ending at the first non-comment line.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# release a crewmate's slot (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-park-lib.sh
. "$SCRIPT_DIR/fm-park-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"

FM_PARK_CONTROL_BIN=${FM_PARK_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}
FM_PARK_CREW_STATE_BIN=${FM_PARK_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}
FM_PARK_SWEEP_LIMIT=${FM_PARK_SWEEP_LIMIT:-2}
FM_PARK_SWEEP_BUDGET_SECS=${FM_PARK_SWEEP_BUDGET_SECS:-20}
case "$FM_PARK_SWEEP_LIMIT" in ''|*[!0-9]*) FM_PARK_SWEEP_LIMIT=2 ;; esac
case "$FM_PARK_SWEEP_BUDGET_SECS" in ''|*[!0-9]*) FM_PARK_SWEEP_BUDGET_SECS=20 ;; esac
PAUSED_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}

fail() {
  printf 'fm-park: %s\n' "$*" >&2
  exit 1
}

# --- shared helpers ---------------------------------------------------------

meta_get() {  # <meta-file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

now_epoch() {
  if [ -n "${FM_PARK_NOW_EPOCH:-}" ]; then
    printf '%s' "$FM_PARK_NOW_EPOCH"
    return 0
  fi
  date +%s
}

validate_id() {  # <task-id>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) fail "'$1' is not a valid task id" ;;
  esac
}

marker_get() {  # <marker-file> <key>
  fm_park_marker_field "$1" "$2"
}

# Decode one tasks-axi `show` field: a JSON string when quoted, else verbatim.
decode_field() {  # <shown-field>
  local value=$1
  case "$value" in
    \"*\")
      printf '%s' "$value" | perl -MJSON::PP -e '
        local $/;
        my $value = decode_json(<STDIN>);
        binmode STDOUT, ":raw";
        utf8::encode($value) if utf8::is_utf8($value);
        print $value;
      '
      ;;
    *) printf '%s' "$value" ;;
  esac
}

# Read one backlog row's body. Prints nothing when the row or its body is
# unreadable; the caller decides whether that is fatal.
backlog_row_body() {  # <id>
  local data show
  data=$(fm_backlog_data_absolute "$DATA" 2>/dev/null) || return 0
  show=$(fm_backlog_row_show "$data" "$ID" --full 2>/dev/null) || return 0
  decode_field "$(printf '%s\n' "$show" | sed -n 's/^  body: //p' | head -1)"
}

# --- task resolution --------------------------------------------------------

ID=
META=
MARKER=
PARK_REASON=
PARK_POINTER=
PARK_BRANCH=
PARK_PR=
PARK_INCARNATION=
PARK_REFUSE=
RESUME_NOTE=

# The park lock serializes park/resume/clear for one task. It is deliberately
# NOT the control plane's own lock: park calls bin/fm-control.sh inside, which
# takes that lock itself, so holding it here would deadlock the call.
PARK_LOCK=
PARK_LOCK_HELD=0
park_cleanup() {
  if [ "$PARK_LOCK_HELD" = 1 ]; then
    fm_lock_release "$PARK_LOCK" || true
    PARK_LOCK_HELD=0
  fi
  if declare -F fm_lease_guard_release >/dev/null 2>&1; then
    fm_lease_guard_release || true
  fi
}
trap park_cleanup EXIT

acquire_park_lock() {
  PARK_LOCK="$STATE/.park-$ID.lock"
  fm_lock_acquire_wait "$PARK_LOCK"
  PARK_LOCK_HELD=1
}

release_park_lock() {
  [ "$PARK_LOCK_HELD" = 1 ] || return 0
  fm_lock_release "$PARK_LOCK"
  PARK_LOCK_HELD=0
  PARK_LOCK=
}

resolve_task() {  # <task-id>
  ID=$1
  validate_id "$ID"
  [ -d "$STATE" ] || fail "state directory '$STATE' is missing; fm-park cannot resolve tasks for FM_HOME '$FM_HOME'"
  META="$STATE/$ID.meta"
  [ -f "$META" ] || fail "no task '$ID' in $STATE (fm-park resolves an exact task id only)"
  MARKER="$STATE/$ID.parked"
  KIND=$(meta_get "$META" kind)
  [ -n "$KIND" ] || KIND=ship
}

# The release mutates the same per-task overlap set the supervision lease
# protects (stop/relaunch, status, backlog), so every mutating verb guards it
# exactly like the other lifecycle entrypoints; the guard is a no-op outside a
# Pi primary home, and read-only verbs stay unguarded.
guard_release() {
  fm_lease_guard "$ID" "operating-point release (fm-park)"
}

# Refuse a symlinked marker rather than reading or removing whatever it points
# at; every lifecycle record under state/ is a regular file this home owns.
require_regular_marker() {
  [ ! -L "$MARKER" ] || fail "marker $MARKER is a symlink; refusing to trust or remove it"
}

load_marker() {  # <marker-file>
  local schema task reason
  schema=$(marker_get "$1" schema)
  task=$(marker_get "$1" task)
  [ "$schema" = fm-park.v1 ] || fail "marker $1 has schema '${schema:-none}', not fm-park.v1; refusing to trust it"
  [ "$task" = "$ID" ] || fail "marker $1 names task '${task:-none}', not '$ID'; refusing to trust it"
  reason=$(marker_get "$1" reason)
  case "$reason" in
    merge|decision) ;;
    *) fail "marker $1 records reason '${reason:-none}', not merge or decision; refusing to trust it" ;;
  esac
  [ -n "$(marker_get "$1" pointer)" ] || fail "marker $1 has no pointer; refusing to trust it"
}

# --- eligibility ------------------------------------------------------------

# The current crew state token from the canonical reader. Unreadable or
# unparseable output is `unknown`, never a guess.

# Parse the canonical current-state line into CREW_STATE, CREW_SOURCE, and
# CREW_DETAIL. The line is owned by bin/fm-crew-state.sh; park_probe needs the
# run-step gate facts it carries (a run parked at a gate reports source=run-step
# with the gate name and, for an authority gate, the canonical
# `(ask-user: authority decision)` marker derived from the gate findings' action
# column), so this is the same run-step source read through its one owner rather
# than a second attribution of no-mistakes records.
CREW_STATE=unknown
CREW_SOURCE=none
CREW_DETAIL=
crew_state_fields() {
  local line rest
  CREW_STATE=unknown
  CREW_SOURCE=none
  CREW_DETAIL=
  line=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$FM_PARK_CREW_STATE_BIN" "$ID" 2>/dev/null) || line=
  case "$line" in
    'state: '*) ;;
    *) return 0 ;;
  esac
  rest=${line#state: }
  CREW_STATE=${rest%% *}
  case "$line" in
    *' · source: '*) rest=${line#*' · source: '} ;;
    *) return 0 ;;
  esac
  CREW_SOURCE=${rest%% *}
  case "$rest" in
    *' · '*) CREW_DETAIL=${rest#*' · '} ;;
  esac
}

# The most recent still-open keyed decision on this task's status log, if any.
# bin/fm-classify-lib.sh owns the open/resolved fold; a `needs-decision` or
# `blocked` event with a key is a documented wait with a pointer.
open_decision_key() {
  local open
  open=$(status_open_decisions "$STATE/$ID.status") || return 0
  [ -n "$open" ] || return 0
  printf '%s\n' "$open" | awk -F'\t' '
    ($2 == "needs-decision" || $2 == "blocked") { key = $1 }
    END { if (key != "") print key }
  '
}

# A captain-held backlog row is the other documented wait: the captain owns the
# next move, and the hold reason is the pointer. Prints the pointer or nothing;
# a probe that cannot answer is not evidence either way.
captain_hold_pointer() {
  local data show reason
  data=$(fm_backlog_data_absolute "$DATA" 2>/dev/null) || return 0
  fm_backlog_row_probe "$data" "$ID" >/dev/null 2>&1 || return 0
  [ "$FM_BACKLOG_ROW_HOLD_KIND" = captain ] || return 0
  show=$(fm_backlog_row_show "$data" "$ID" --full 2>/dev/null) || show=
  reason=$(printf '%s\n' "$show" | sed -n 's/^  hold_reason: *//p' | head -1)
  reason=$(decode_field "$reason")
  case "$reason" in ''|'-') printf 'captain-hold' ;;
    *) printf 'captain-hold: %s' "$reason" ;;
  esac
}

work_branch() {  # <worktree>
  local wt=$1 branch
  [ -n "$wt" ] && [ -d "$wt" ] || { printf '%s' '-'; return 0; }
  branch=$(git -C "$wt" branch --show-current 2>/dev/null) || branch=
  [ -n "$branch" ] || branch=-
  printf '%s' "$branch"
}

# park_probe fills the PARK_* fields when the task is eligible, or PARK_REFUSE
# with the reason it is not. The current-state read comes first because a
# no-mistakes run parked at a gate decides the handoff: an ask-user/authority
# gate is a decision wait whose pointer is the gate's open keyed decision, a
# gate the worker itself must answer (fix-review) refuses parking, and only a
# gate-free task may use its recorded pr= as a merge handoff.
park_probe() {
  local state source detail key hold pr
  PARK_REASON=
  PARK_POINTER=
  PARK_BRANCH=
  PARK_PR=
  PARK_INCARNATION=
  PARK_REFUSE=
  if [ "$KIND" = secondmate ]; then
    PARK_REFUSE="persistent secondmates are never parked; an idle secondmate is healthy"
    return 1
  fi
  pr=$(meta_get "$META" pr)
  crew_state_fields
  state=$CREW_STATE
  source=$CREW_SOURCE
  detail=$CREW_DETAIL
  case "$state" in
    working)
      PARK_REFUSE="the crew is actively working ($state); only a parked run at a gate, a done task, or a documented wait may be parked"
      return 1
      ;;
  esac
  if [ "$state" = parked ] && [ "$source" = run-step ]; then
    # A no-mistakes run parked at a gate. The gate decides: an authority gate
    # carries the canonical ask-user marker and waits on firstmate/captain,
    # every other gate waits on the worker.
    case "$detail" in
      *'(ask-user: authority decision)'*)
        key=$(open_decision_key)
        if [ -z "$key" ]; then
          PARK_REFUSE="a run is parked at an ask-user gate but no keyed decision is recorded on the status log; record the gate decision before parking"
          return 1
        fi
        PARK_REASON=decision
        PARK_POINTER="key=$key"
        ;;
      *)
        PARK_REFUSE="a run is parked at a gate the worker must answer (${detail:-gate}); it is not waiting on firstmate or the captain, and parking would stop the worker the gate waits on"
        return 1
        ;;
    esac
  else
    key=$(open_decision_key)
    hold=
    [ -n "$key" ] || hold=$(captain_hold_pointer)
    if [ -n "$key" ]; then
      PARK_REASON=decision
      PARK_POINTER="key=$key"
    elif [ -n "$hold" ]; then
      PARK_REASON=decision
      PARK_POINTER=$hold
    elif [ -n "$pr" ]; then
      PARK_REASON=merge
      PARK_POINTER=$pr
    else
      PARK_REFUSE="no provable handoff: no open keyed decision, no captain-held backlog row, and no recorded pr= to wait on"
      return 1
    fi
  fi
  if [ "$PARK_REASON" = merge ]; then
    case "$state" in
      parked|done) ;;
      *)
        PARK_REFUSE="a merge handoff needs crew state parked or done, but the crew reads '$state'; reconcile it first"
        return 1
        ;;
    esac
  fi
  PARK_POINTER=$(printf '%s' "$PARK_POINTER" | tr '\n\r' '  ')
  PARK_PR=$pr
  PARK_INCARNATION=$(meta_get "$META" spawn_gen)
  PARK_BRANCH=$(work_branch "$(meta_get "$META" worktree)")
  return 0
}

# --- marker, status line, backlog note --------------------------------------

write_marker() {  # <releasing|released>
  local tmp
  tmp=$(umask 077; mktemp "$STATE/.$ID.parked.tmp.XXXXXX") || return 1
  {
    printf 'schema=fm-park.v1\n'
    printf 'task=%s\n' "$ID"
    printf 'reason=%s\n' "$PARK_REASON"
    printf 'pointer=%s\n' "$PARK_POINTER"
    printf 'branch=%s\n' "${PARK_BRANCH:--}"
    printf 'pr=%s\n' "${PARK_PR:--}"
    printf 'epoch=%s\n' "$(now_epoch)"
    printf 'incarnation=%s\n' "${PARK_INCARNATION:--}"
    printf 'state=%s\n' "$1"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$MARKER"
}

park_status_line() {
  printf '%s [key=park-%s]: released awaiting %s - %s' "$PAUSED_VERB" "$ID" "$PARK_REASON" "$PARK_POINTER"
}

append_park_status_line() {
  local line
  line=$(park_status_line)
  if [ -f "$STATE/$ID.status" ] && grep -Fxq "$line" "$STATE/$ID.status" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$line" >> "$STATE/$ID.status"
}

park_note_text() {
  printf 'Park release: awaiting %s - %s\n' "$PARK_REASON" "$PARK_POINTER"
  printf 'Branch: %s\n' "${PARK_BRANCH:--}"
  case "$PARK_REASON" in
    merge) printf 'Remaining: after the merge, reconcile the branch head, rebase or fix only if needed, and report done for cleanup.\n' ;;
    decision) printf 'Remaining: apply the decision above, finish the open work, and report done.\n' ;;
  esac
}

backlog_display() {
  local file
  if file=$(fm_backlog_file "$DATA" 2>/dev/null); then
    printf '%s' "$file"
  else
    printf '%s/backlog.md' "${DATA%/}"
  fi
}

backlog_note_manual() {
  case "${FM_BACKLOG_TRANSITION_SKIP:-}" in
    *'keeps no backlog'*)
      printf 'Backlog: %s\n' "$FM_BACKLOG_TRANSITION_SKIP" >&2
      ;;
    *)
      # The owed hand edit goes to stderr so a sweep that discards park_task's
      # stdout still surfaces it (the startup report captures stderr).
      printf 'Backlog: add this note by hand to %s:\n' "$(backlog_display)" >&2
      park_note_text | sed 's/^/  /' >&2
      ;;
  esac
}

# Record the handoff note in the task's backlog row. Returns non-zero when an
# automatic backend is configured but the note could not be recorded, so the
# release stops before the worker is stopped with its handoff undocumented.
park_backlog_note() {
  local first body tmp new_body rc
  first=$(park_note_text | sed -n 1p)
  body=$(backlog_row_body)
  if printf '%s\n' "$body" | grep -Fxq "$first" 2>/dev/null; then
    return 0
  fi
  if fm_backlog_transition_applies "$CONFIG" "$DATA" "$KIND"; then
    :
  else
    rc=$?
    if [ "$rc" -eq 2 ]; then
      printf 'fm-park: cannot record the park note: %s\n' "${FM_BACKLOG_TRANSITION_ERROR:-automatic backlog transitions are unavailable}" >&2
      return 1
    fi
    backlog_note_manual
    return 0
  fi
  if ! fm_backlog_row_probe "$DATA" "$ID" >/dev/null 2>&1; then
    printf 'fm-park: %s has no readable backlog row in this home (%s), so its handoff cannot be recorded; add the item before parking\n' \
      "$ID" "${FM_BACKLOG_ROW_ERROR:-row not found}" >&2
    return 1
  fi
  new_body=$(park_note_text)
  if [ -n "$body" ]; then
    new_body=$(printf '%s\n\n%s' "$body" "$new_body")
  fi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-park-note.XXXXXX") || {
    printf 'fm-park: cannot stage the park note\n' >&2
    return 1
  }
  if ! printf '%s\n' "$new_body" > "$tmp"; then
    rm -f "$tmp"
    printf 'fm-park: cannot stage the park note for %s\n' "$ID" >&2
    return 1
  fi
  if ! fm_backlog_mutate "$DATA" update "$ID" --body-file "$tmp" --archive-body >/dev/null; then
    rm -f "$tmp"
    printf 'fm-park: could not record the park note on %s in the configured backlog: %s\n' \
      "$ID" "${FM_BACKLOG_TRANSITION_ERROR:-unknown error}" >&2
    return 1
  fi
  rm -f "$tmp"
  return 0
}

# --- release and resume -----------------------------------------------------

# Stop the released worker and only then mark the release verified. A failure
# leaves the marker at state=releasing: the intent is durable, the slot is not
# claimed free, and the next park retries the stop.
finish_release() {
  local out
  if ! out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$FM_PARK_CONTROL_BIN" "$ID" exit 2>&1); then
    printf 'fm-park: %s could not be stopped, so it is NOT parked: %s\n' "$ID" "$out" >&2
    printf 'fm-park: the release intent stays recorded at %s (state=releasing); fix the stop and run park again\n' "$MARKER" >&2
    return 1
  fi
  write_marker released || {
    printf 'fm-park: %s was stopped but its released marker could not be committed; the release stays recorded as releasing and park retries it\n' "$ID" >&2
    return 1
  }
  return 0
}

PARK_RESULT=

park_task() {  # <task-id>; prints the backlog-owed hand edit when there is one
  resolve_task "$1"
  guard_release
  acquire_park_lock
  local rc=0
  park_task_locked || rc=$?
  release_park_lock
  return "$rc"
}

park_task_locked() {
  local marker_state current_gen
  require_regular_marker
  current_gen=$(meta_get "$META" spawn_gen)
  marker_state=$(fm_park_marker_state "$STATE" "$ID" "$current_gen")
  if [ -z "$marker_state" ] && [ -e "$MARKER" ]; then
    # A valid marker from an earlier incarnation is stale: a control-plane
    # relaunch or recovery respawn started a new worker outside fm-park, so the
    # release no longer describes this task. A malformed marker is refused.
    load_marker "$MARKER"
    printf 'fm-park: dropping a stale park marker for %s (recorded incarnation %s, current %s)\n' \
      "$ID" "$(marker_get "$MARKER" incarnation)" "${current_gen:--}" >&2
    rm -f "$MARKER"
  fi
  if [ -n "$marker_state" ]; then
    load_marker "$MARKER"
    PARK_REASON=$(marker_get "$MARKER" reason)
    PARK_POINTER=$(marker_get "$MARKER" pointer)
    PARK_BRANCH=$(marker_get "$MARKER" branch)
    PARK_PR=$(marker_get "$MARKER" pr)
    PARK_INCARNATION=$(marker_get "$MARKER" incarnation)
    case "$marker_state" in
      released)
        PARK_RESULT=already
        printf 'already-parked %s reason=%s pointer=%s\n' "$ID" "$PARK_REASON" "$PARK_POINTER"
        return 0
        ;;
      releasing)
        # An interrupted or failed release: retry the idempotent status line
        # (the fresh path writes it after the marker, so a release interrupted
        # in between owes it), then the note, then the stop, then commit the
        # verified state.
        append_park_status_line || fail "could not append the park status line for $ID"
        park_backlog_note || { PARK_RESULT=failed; return 1; }
        finish_release || { PARK_RESULT=failed; return 1; }
        PARK_RESULT=parked
        printf 'parked %s reason=%s pointer=%s\n' "$ID" "$PARK_REASON" "$PARK_POINTER"
        return 0
        ;;
    esac
  fi
  park_probe || { PARK_RESULT=ineligible; return 1; }
  # Record the durable intent first: a crash between here and the stop leaves a
  # visible releasing marker rather than a silently half-released task.
  write_marker releasing || fail "could not write the park marker $MARKER"
  append_park_status_line || fail "could not append the park status line for $ID"
  park_backlog_note || { PARK_RESULT=failed; return 1; }
  finish_release || { PARK_RESULT=failed; return 1; }
  PARK_RESULT=parked
  printf 'parked %s reason=%s pointer=%s\n' "$ID" "$PARK_REASON" "$PARK_POINTER"
  return 0
}

resume_note_text() {
  case "$PARK_REASON" in
    merge)
      printf 'PR merged at %s. Reconcile the branch head with the merged result; rebase or fix only if needed, then report done for cleanup.' "$PARK_POINTER"
      ;;
    decision)
      if [ -n "$RESUME_NOTE" ]; then
        printf '%s\n\nThe decision recorded at %s is being delivered through your instruction inbox. Apply it, finish the open work, then report done.' "$RESUME_NOTE" "$PARK_POINTER"
      else
        printf 'The decision recorded at %s is ready. Read your instruction inbox, finish the open work, then report done.' "$PARK_POINTER"
      fi
      ;;
    *)
      fail "marker $MARKER records reason '${PARK_REASON:-none}', which is neither merge nor decision"
      ;;
  esac
}

resume_task() {  # <task-id> <reason> [note]
  local reason=$2 note=${3:-} rc=0
  resolve_task "$1"
  guard_release
  [ -e "$MARKER" ] || fail "task $ID is not parked (no marker at $MARKER)"
  acquire_park_lock
  resume_task_locked "$reason" "$note" || rc=$?
  release_park_lock
  return "$rc"
}

resume_task_locked() {  # <reason> <note>
  local reason=$1 note=$2 out recorded family
  local -a relaunch_args=()
  require_regular_marker
  load_marker "$MARKER"
  PARK_REASON=$(marker_get "$MARKER" reason)
  PARK_POINTER=$(marker_get "$MARKER" pointer)
  PARK_BRANCH=$(marker_get "$MARKER" branch)
  PARK_PR=$(marker_get "$MARKER" pr)
  PARK_INCARNATION=$(marker_get "$MARKER" incarnation)
  case "$(fm_park_marker_state "$STATE" "$ID" "$(meta_get "$META" spawn_gen)")" in
    released) ;;
    *)
      fail "task $ID's release is not verified for its current incarnation; finish the park first, or clear a stale marker from a worker that was relaunched outside fm-park"
      ;;
  esac
  [ "$PARK_REASON" = "$reason" ] \
    || fail "task $ID is parked for reason=$PARK_REASON, not $reason; refusing to resume it for the wrong trigger (clear it instead if the release no longer applies)"
  # A raw launch command records its basename, which the control plane cannot
  # reconstruct; the replacement runs on the resolved verified adapter family,
  # the same resolution the exit leg used.
  recorded=$(meta_get "$META" harness)
  if family=$(fm_control_harness_family "$recorded") && [ "$family" != "$recorded" ]; then
    relaunch_args=(--harness "$family")
  fi
  RESUME_NOTE=$note
  note=$(resume_note_text)
  if ! out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$FM_PARK_CONTROL_BIN" "$ID" relaunch ${relaunch_args[@]+"${relaunch_args[@]}"} --note "$note" 2>&1); then
    printf 'fm-park: %s could not be relaunched, so it stays parked: %s\n' "$ID" "$out" >&2
    return 1
  fi
  rm -f "$MARKER"
  printf 'resumed %s reason=%s pointer=%s\n' "$ID" "$PARK_REASON" "$PARK_POINTER"
  return 0
}

# --- verbs ------------------------------------------------------------------

command_park() {
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  if ! park_task "$1"; then
    if [ "$PARK_RESULT" = ineligible ]; then
      printf 'fm-park: %s\n' "$PARK_REFUSE" >&2
    fi
    exit 1
  fi
}

command_resume() {
  local id=${1:-} reason='' note='' want=''
  [ -n "$id" ] || { usage >&2; exit 2; }
  shift
  for arg in "$@"; do
    if [ -n "$want" ]; then
      case "$want" in
        reason) reason=$arg ;;
        note) note=$arg ;;
      esac
      want=
      continue
    fi
    case "$arg" in
      --reason) want=reason ;;
      --reason=*) reason=${arg#--reason=} ;;
      --note) want=note ;;
      --note=*) note=${arg#--note=} ;;
      *) fail "unexpected argument '$arg'" ;;
    esac
  done
  [ -z "$want" ] || fail "--$want requires a value"
  case "$reason" in
    merge|decision) ;;
    *) fail "resume requires --reason merge or --reason decision (got '${reason:-none}')" ;;
  esac
  resume_task "$id" "$reason" "$note"
}

command_clear() {
  local id=${1:-} reason='' want=''
  [ -n "$id" ] || { usage >&2; exit 2; }
  shift
  for arg in "$@"; do
    if [ -n "$want" ]; then
      reason=$arg
      want=
      continue
    fi
    case "$arg" in
      --reason) want=reason ;;
      --reason=*) reason=${arg#--reason=} ;;
      *) fail "unexpected argument '$arg'" ;;
    esac
  done
  [ -z "$want" ] || fail "--$want requires a value"
  resolve_task "$id"
  guard_release
  [ -e "$MARKER" ] || fail "task $ID is not parked (no marker at $MARKER)"
  acquire_park_lock
  require_regular_marker
  # clear is the explicit drop, so it removes even a malformed or stale marker
  # that the lifecycle verbs would refuse; that is its documented purpose.
  local state
  state=$(marker_get "$MARKER" state)
  rm -f "$MARKER"
  release_park_lock
  if [ -n "$reason" ]; then
    printf 'cleared %s state=%s reason=%s\n' "$ID" "${state:-unknown}" "$reason"
  else
    printf 'cleared %s state=%s\n' "$ID" "${state:-unknown}"
  fi
}

command_list() {
  local marker id reason pointer branch pr epoch incarnation state
  [ -d "$STATE" ] || fail "state directory '$STATE' is missing"
  for marker in "$STATE"/*.parked; do
    [ -f "$marker" ] && [ ! -L "$marker" ] || continue
    id=$(basename "$marker" .parked)
    case "$(marker_get "$marker" schema)" in
      fm-park.v1) ;;
      *) continue ;;
    esac
    reason=$(marker_get "$marker" reason)
    pointer=$(marker_get "$marker" pointer)
    branch=$(marker_get "$marker" branch)
    pr=$(marker_get "$marker" pr)
    epoch=$(marker_get "$marker" epoch)
    incarnation=$(marker_get "$marker" incarnation)
    state=$(marker_get "$marker" state)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "$reason" "$pointer" "$branch" "$pr" "$epoch" "$incarnation" "$state"
  done | LC_ALL=C sort -t "$(printf '\t')" -k1,1
}

command_status() {
  local id=${1:-} state fields
  [ -n "$id" ] || { usage >&2; exit 2; }
  resolve_task "$id"
  if [ ! -e "$MARKER" ]; then
    printf 'not-parked %s\n' "$ID"
    return 1
  fi
  require_regular_marker
  state=$(fm_park_marker_state "$STATE" "$ID" "$(meta_get "$META" spawn_gen)")
  if [ -z "$state" ]; then
    # A valid marker for another incarnation is stale; a malformed one is
    # refused loudly rather than reported as any kind of release.
    load_marker "$MARKER"
    state=stale
  fi
  # Only a released marker is parked state; a releasing marker's release is not
  # verified and a stale marker describes an earlier worker, so neither may
  # read as a freed slot.
  fields="reason=$(marker_get "$MARKER" reason) pointer=$(marker_get "$MARKER" pointer) branch=$(marker_get "$MARKER" branch) pr=$(marker_get "$MARKER" pr) epoch=$(marker_get "$MARKER" epoch) incarnation=$(marker_get "$MARKER" incarnation) state=$state"
  case "$state" in
    released)
      printf 'parked %s %s\n' "$ID" "$fields"
      return 0
      ;;
  esac
  printf '%s %s %s\n' "$state" "$ID" "$fields"
  return 1
}

command_sweep() {
  local limit=$FM_PARK_SWEEP_LIMIT budget=$FM_PARK_SWEEP_BUDGET_SECS
  local meta id kind marker state start elapsed attempts=0
  if [ "${1:-}" = --limit ]; then
    [ -n "${2:-}" ] || fail "--limit requires a value"
    case "$2" in ''|*[!0-9]*) fail "--limit must be a non-negative integer" ;; esac
    limit=$2
  elif [ "$#" -gt 0 ]; then
    usage >&2
    exit 2
  fi
  [ -d "$STATE" ] || fail "state directory '$STATE' is missing"
  start=$(now_epoch)
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    [ "$attempts" -lt "$limit" ] || break
    elapsed=$(( $(now_epoch) - start ))
    [ "$elapsed" -lt "$budget" ] || break
    id=$(basename "$meta" .meta)
    marker="$STATE/$id.parked"
    if [ -L "$marker" ]; then
      continue
    fi
    if [ -e "$marker" ]; then
      state=$(marker_get "$marker" state)
      [ "$state" = released ] && continue
    fi
    kind=$(meta_get "$meta" kind)
    [ "$kind" = secondmate ] && continue
    # Skip a task the other supervision actor is actively changing: the park
    # guard would refuse it anyway, and its exit would abort the whole sweep.
    fm_lease_live "$id" && continue
    if ! park_task "$id" >/dev/null; then
      case "$PARK_RESULT" in
        ineligible) ;;
        *)
          attempts=$((attempts + 1))
          printf 'PARK_SWEEP: could not release %s; the task stays in place\n' "$id"
          ;;
      esac
    else
      attempts=$((attempts + 1))
    fi
  done
  return 0
}

# --- dispatch ---------------------------------------------------------------

VERB=${1:-}
case "$VERB" in
  park) shift; command_park "$@" ;;
  resume) shift; command_resume "$@" ;;
  clear) shift; command_clear "$@" ;;
  list) shift; [ "$#" -eq 0 ] || { usage >&2; exit 2; }; command_list ;;
  status) shift; command_status "$@" ;;
  sweep) shift; command_sweep "$@" ;;
  '') usage >&2; exit 2 ;;
  *) usage >&2; exit 2 ;;
esac
