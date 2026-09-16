#!/usr/bin/env bash
# fm-park-lib.sh - the single READER of the fm-park.v1 operating-point marker.
#
# bin/fm-park.sh owns the write side and docs/park-release.md owns the schema.
# Every surface that must agree on whether a task is released reads through
# fm_park_marker_state, so one private format never grows a second parser with
# different strictness: a malformed, foreign, or stale marker must not free a
# slot in the current-state or watcher surfaces while the lifecycle owner
# refuses it, and a marker must never claim an incarnation other than the
# worker that is actually running.
#
# Usage: . bin/fm-park-lib.sh
#
# fm_park_marker_state <state-dir> <task-id> [<current-incarnation>]
#   Prints `released`, `releasing`, or nothing.
#   A marker counts only when it is a regular file (never a symlink) whose
#   schema is exactly fm-park.v1, whose task= names this id, and whose state is
#   one of the two known values. When <current-incarnation> is given - the
#   task's current spawn_gen - a marker recording a different incarnation is
#   stale, because a new worker started outside bin/fm-park.sh (a control-plane
#   relaunch or a recovery respawn), and nothing is printed. An empty
#   <current-incarnation> skips that check for a legacy record without one.
#
# Read-only and side-effect free.

fm_park_marker_field() {  # <marker-file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_park_marker_state() {  # <state-dir> <task-id> [<current-incarnation>]
  local state_dir=$1 id=$2 incarnation=${3-} marker schema task state marker_inc
  marker="$state_dir/$id.parked"
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 0
  schema=$(fm_park_marker_field "$marker" schema)
  [ "$schema" = fm-park.v1 ] || return 0
  task=$(fm_park_marker_field "$marker" task)
  [ "$task" = "$id" ] || return 0
  state=$(fm_park_marker_field "$marker" state)
  case "$state" in
    released)
      if [ -n "$incarnation" ]; then
        marker_inc=$(fm_park_marker_field "$marker" incarnation)
        [ "$marker_inc" = "$incarnation" ] || return 0
      fi
      printf 'released'
      ;;
    releasing) printf 'releasing' ;;
  esac
}
