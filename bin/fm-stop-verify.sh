#!/usr/bin/env bash
# fm-stop-verify.sh - request a worker stop, VERIFY it, escalate honestly.
#
# The captain's capacity-brake finding (2026-09-07): the stop call
# (fm-control exit) is a polite request a worker stuck in a long shell command
# only sees after that command ends, so a brake that logs "stopped" after
# merely REQUESTING a stop reads better than reality, and repeating the same
# polite request to the same victim changes nothing. This helper is the
# reusable, tested stop-verification the capacity brake (a private state/
# script firstmate wires separately) and any other caller use:
#
#   request -> verify -> escalate -> honestly report
#
# Every call ends in exactly one machine-readable outcome, and the caller must
# treat everything except `confirmed` as "the worker is NOT stopped":
#
#   confirmed      the agent's recovery-grade state is dead/missing, so the
#                  worker is really gone. Includes already-stopped (a
#                  confirmed stop with no request needed).
#   escalated      the polite exit was requested but the agent stayed alive,
#                  so this helper delivered a hard interrupt and reported the
#                  escalation; the agent is STILL alive (unconfirmed).
#   cooldown       this victim was already addressed within the cooldown
#                  window with nothing changed; reported, nothing repeated.
#   skipped        the task is not a stop candidate (secondmate, done, failed,
#                  captain-held, remote, or invalid/unresolvable meta).
#   unverifiable   the endpoint cannot be classified (ambiguous, unreadable,
#                  unverified): fail-closed, no action taken.
#   failed         the stop request itself could not be delivered (control
#                  plane error, or another verification already running):
#                  fail-closed, no false "stopped".
#
# Exit codes: 0 = confirmed (stopped), 1 = escalated (action taken, agent
# still alive), 2 = no action (cooldown/skipped/unverifiable/failed/usage).
#
# The three captain requirements, and how this helper satisfies each:
#
# (1) Verify, then get harder. The polite exit (fm-control exit) is delivered
#     once, then the helper polls the backend's recovery-grade agent state
#     (fm_backend_agent_state; only dead/missing license "gone") for
#     --verify-wait seconds. Still alive? It does NOT repeat the polite
#     request: it delivers a hard interrupt (fm-control interrupt) and polls
#     again for --hard-wait seconds. Still alive? `escalated`, exit 1, and a
#     distinct event-log line. Never the same polite request twice.
# (2) Never the same victim on repeat. Every unconfirmed addressing writes a
#     durable per-victim record (state/.stop-verify-<task>) with its outcome
#     and timestamp. A victim whose last addressing was unconfirmed and whose
#     agent is still alive is in COOLDOWN for --cooldown seconds: a re-call
#     within the window reports `cooldown` and does nothing. A call with
#     several candidates addresses the first not-in-cooldown one, and when
#     every candidate is in cooldown it reports all of them instead of
#     repeating. After the cooldown expires, a re-addressing skips the polite
#     request and goes straight to the harder interrupt path.
# (3) Honest event log. Every transition appends a distinct line to the
#     durable event log (state/.stop-verify.log by default): `requested`,
#     `confirmed`, `escalated`, `unconfirmed`, `cooldown`, `skipped`,
#     `unverifiable`, `failed`. History never reads "stopped" for a request.
#
# Fail-closed boundaries:
#   - Only the recovery-grade dead/missing state proves a stop; ambiguous,
#     unreadable, unverified, or unknown state never confirms anything, and an
#     endpoint that becomes unclassifiable mid-verify is never interrupted.
#   - A task that is not a stop candidate (kind=secondmate, done/failed/
#     captain-held status, remote placement) is never addressed.
#   - The request goes through the verified control plane (fm-control exit and
#     interrupt); this helper never types into a pane itself.
#   - A concurrent addressing of the same task is refused through a per-task
#     lock, and a no-mistakes gate agent is refused (fm_refuse_if_gate_agent).
#
# Usage:
#   fm-stop-verify.sh <task-id> [<task-id>...] [options]
#     Address the FIRST eligible candidate and stop there. Candidates are
#     examined in the given order; the first that is not in cooldown, is a
#     stop candidate, and has a live agent is addressed. A candidate that is
#     already stopped is reported `confirmed` immediately. When no candidate
#     is addressable, every candidate's status is reported and nothing is
#     addressed.
#   fm-stop-verify.sh --list <task-id>... [options]
#     Report each candidate's status (eligible/cooldown/skipped/
#     already-stopped/unverifiable) without addressing any.
#   fm-stop-verify.sh --help
#
# Options:
#   --log <file>         event log path (default $STATE/.stop-verify.log)
#   --cooldown <secs>    unconfirmed-victim cooldown (default 300)
#   --verify-wait <secs> poll window after the polite exit before escalating
#                        (default 15)
#   --hard-wait <secs>   poll window after the hard interrupt before declaring
#                        escalated (default 15)
#   --poll <secs>        agent-state poll interval (default 1)
#   --list               eligibility report only, no addressing
#
# Environment (test seams in the FM_CREW_STATE_BIN spirit):
#   FM_STOP_VERIFY_CONTROL     control-plane binary (default fm-control.sh in
#                              this script's own bin/)
#   FM_STOP_VERIFY_STATE_BIN   executable whose stdout is one agent-state word
#                              for <task> <window> <backend>; unset reads the
#                              real backend classifier
#   FM_STOP_VERIFY_LOG, FM_STOP_VERIFY_COOLDOWN, FM_STOP_VERIFY_VERIFY_WAIT,
#   FM_STOP_VERIFY_HARD_WAIT, FM_STOP_VERIFY_POLL   defaults above

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# drive a crewmate's lifecycle (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-stop-verify refuses to resolve a task without an explicit firstmate home" >&2
  exit 2
fi
[ -d "$FM_HOME" ] || {
  echo "error: FM_HOME '$FM_HOME' is not a directory" >&2
  exit 2
}
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || {
  echo "error: state dir '$STATE' is missing; fm-stop-verify cannot resolve tasks for FM_HOME '$FM_HOME'" >&2
  exit 2
}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

CONTROL=${FM_STOP_VERIFY_CONTROL:-$SCRIPT_DIR/fm-control.sh}
STATE_BIN=${FM_STOP_VERIFY_STATE_BIN:-}
LOG=${FM_STOP_VERIFY_LOG:-$STATE/.stop-verify.log}
COOLDOWN=${FM_STOP_VERIFY_COOLDOWN:-300}
VERIFY_WAIT=${FM_STOP_VERIFY_VERIFY_WAIT:-15}
HARD_WAIT=${FM_STOP_VERIFY_HARD_WAIT:-15}
POLL=${FM_STOP_VERIFY_POLL:-1}
LIST_MODE=0

# --- argument parsing -------------------------------------------------------

LIST=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --list) LIST_MODE=1 ;;
    --log) [ "$#" -gt 1 ] || { echo "error: --log requires a value" >&2; exit 2; }; shift; LOG=$1 ;;
    --log=*) LOG=${1#--log=} ;;
    --cooldown) [ "$#" -gt 1 ] || { echo "error: --cooldown requires a value" >&2; exit 2; }; shift; COOLDOWN=$1 ;;
    --cooldown=*) COOLDOWN=${1#--cooldown=} ;;
    --verify-wait) [ "$#" -gt 1 ] || { echo "error: --verify-wait requires a value" >&2; exit 2; }; shift; VERIFY_WAIT=$1 ;;
    --verify-wait=*) VERIFY_WAIT=${1#--verify-wait=} ;;
    --hard-wait) [ "$#" -gt 1 ] || { echo "error: --hard-wait requires a value" >&2; exit 2; }; shift; HARD_WAIT=$1 ;;
    --hard-wait=*) HARD_WAIT=${1#--hard-wait=} ;;
    --poll) [ "$#" -gt 1 ] || { echo "error: --poll requires a value" >&2; exit 2; }; shift; POLL=$1 ;;
    --poll=*) POLL=${1#--poll=} ;;
    -*) echo "error: unexpected argument '$1'" >&2; exit 2 ;;
    *) LIST+=("$1") ;;
  esac
  shift
done
[ "${#LIST[@]}" -gt 0 ] || { usage >&2; exit 2; }
case "$COOLDOWN" in ''|*[!0-9.]*) echo "error: --cooldown must be seconds" >&2; exit 2 ;; esac
case "$VERIFY_WAIT" in ''|*[!0-9.]*) echo "error: --verify-wait must be seconds" >&2; exit 2 ;; esac
case "$HARD_WAIT" in ''|*[!0-9.]*) echo "error: --hard-wait must be seconds" >&2; exit 2 ;; esac
case "$POLL" in ''|*[!0-9.]*) echo "error: --poll must be seconds" >&2; exit 2 ;; esac

# --- outcome helpers --------------------------------------------------------

emit() {  # <outcome> <detail...>
  printf '%s %s\n' "$1" "${*:2}"
}

log_event() {  # <verb> <task> <window> [detail...]
  local verb=$1 task=$2 window=$3
  shift 3
  {
    printf '%s' "$(date +%s)"
    printf ' %s %s %s' "$verb" "$task" "$window"
    [ "$#" -eq 0 ] || printf ' %s' "$*"
    printf '\n'
  } >> "$LOG"
}

# agent_state_verdict: one normalized word for a task's recorded endpoint.
#   dead       recovery-grade dead or missing: the worker is authoritatively
#              gone (only this licenses a confirmed stop).
#   alive      a live agent is running.
#   unknown    ambiguous, unreadable, unverified, or empty: fail-closed, never
#              confirms anything and never licenses an interrupt.
agent_state_verdict() {  # <task> <window> <backend>
  local task=$1 window=$2 backend=$3 v
  if [ -n "$STATE_BIN" ]; then
    v=$("$STATE_BIN" "$task" "$window" "$backend" 2>/dev/null || true)
  else
    v=$(fm_backend_agent_state "$backend" "$window" 2>/dev/null || true)
  fi
  case "$v" in
    dead|missing) printf 'dead' ;;
    alive) printf 'alive' ;;
    *) printf 'unknown' ;;
  esac
}

# wait_for_dead: poll the endpoint until it is recovery-grade dead or the
# window expires. Returns 0 on dead; 1 on window expiry. Sets
# WAIT_LAST_VERDICT to the LAST verdict read (alive or unknown), so a caller
# can tell a still-alive endpoint (safe to escalate) from an unclassifiable
# one (never escalate - fail-closed).
WAIT_LAST_VERDICT=alive
wait_for_dead() {  # <task> <window> <backend> <seconds>
  local task=$1 window=$2 backend=$3 secs=$4 v elapsed=0
  WAIT_LAST_VERDICT=alive
  while :; do
    v=$(agent_state_verdict "$task" "$window" "$backend")
    WAIT_LAST_VERDICT=$v
    [ "$v" = dead ] && return 0
    awk -v e="$elapsed" -v t="$secs" 'BEGIN{exit !(e < t)}' || return 1
    sleep "$POLL"
    elapsed=$(awk -v e="$elapsed" -v p="$POLL" 'BEGIN{printf "%.3f", e + p}')
  done
}

# --- durable per-victim record ----------------------------------------------

record_of() {  # <task> -> 0 if an unconfirmed record exists; prints its ts
  local f="$STATE/.stop-verify-$1" out ts
  [ -f "$f" ] || return 1
  out=$(grep '^outcome=' "$f" 2>/dev/null | head -1 | cut -d= -f2-)
  ts=$(grep '^ts=' "$f" 2>/dev/null | head -1 | cut -d= -f2-)
  [ "$out" = unconfirmed ] && [ -n "$ts" ] || return 1
  printf '%s' "$ts"
}

clear_record() {  # <task>
  rm -f "$STATE/.stop-verify-$1"
}

write_unconfirmed() {  # <task> <window>
  local task=$1 win=$2
  printf 'outcome=unconfirmed\nts=%s\nwindow=%s\n' "$(date +%s)" "$win" \
    > "$STATE/.stop-verify-$task"
}

in_cooldown() {  # <ts> -> 0 while the recorded addressing is within COOLDOWN
  awk -v n="$(date +%s)" -v t="$1" -v c="$COOLDOWN" 'BEGIN{exit !(n - t < c)}'
}

# --- candidate classification -----------------------------------------------

# classify: print one of
#   skipped:<reason>  already-stopped  unverifiable  cooldown:<ts>  eligible
classify() {  # <task>
  local task=$1 meta kind remote last verb win backend verdict rec_ts
  meta="$STATE/$task.meta"
  [ -f "$meta" ] || { printf 'skipped:no meta record'; return; }
  case "$task" in ''|*[!A-Za-z0-9._-]*) printf 'skipped:invalid task id'; return ;; esac
  kind=$(fm_meta_get "$meta" kind)
  [ "$kind" != secondmate ] || { printf 'skipped:secondmate (idle pane is healthy)'; return; }
  remote=$(fm_meta_get "$meta" remote_host)
  [ -z "$remote" ] || { printf 'skipped:remote placement'; return; }
  last=$(tail -n 1 "$STATE/$task.status" 2>/dev/null || true)
  case "$(status_line_verb "$last")" in
    done|failed|captain-held) printf 'skipped:legitimately stopped'; return ;;
  esac
  fm_backend_validate_task_endpoint "$meta" "$task" >/dev/null 2>&1 \
    || { printf 'skipped:invalid endpoint'; return; }
  backend=$FM_BACKEND_VALIDATED_BACKEND
  win=$FM_BACKEND_VALIDATED_TARGET
  verdict=$(agent_state_verdict "$task" "$win" "$backend")
  case "$verdict" in
    dead) printf 'already-stopped'; return ;;
    unknown) printf 'unverifiable'; return ;;
  esac
  if rec_ts=$(record_of "$task") && in_cooldown "$rec_ts"; then
    printf 'cooldown:%s' "$rec_ts"
  else
    printf 'eligible'
  fi
}

# --- the address ladder -----------------------------------------------------

# run_hard: the harder step - deliver a hard interrupt, then verify again.
# Returns 0 on confirmed, 1 on escalated (still alive), 2 on failed.
run_hard() {  # <task> <window> <backend>
  local task=$1 win=$2 backend=$3 out rc v
  v=$(agent_state_verdict "$task" "$win" "$backend")
  if [ "$v" != alive ]; then
    # Fail-closed: never interrupt an endpoint that cannot be classified as
    # alive; a wrong interrupt is worse than a loud refusal.
    log_event unverifiable "$task" "$win" "endpoint unclassifiable before interrupt"
    emit unverifiable "$task endpoint cannot be classified; no interrupt delivered"
    return 2
  fi
  log_event escalated "$task" "$win" "hard interrupt delivered after polite exit failed"
  out=$("$CONTROL" "$task" interrupt 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    # The interrupt could not be delivered. The endpoint being authoritatively
    # gone still proves the stop; anything else confirms nothing.
    if wait_for_dead "$task" "$win" "$backend" "$HARD_WAIT"; then
      clear_record "$task"
      log_event confirmed "$task" "$win" "endpoint gone while interrupting"
      emit confirmed "$task stopped (endpoint gone while interrupting)"
      return 0
    fi
    write_unconfirmed "$task" "$win"
    if [ "$WAIT_LAST_VERDICT" = unknown ]; then
      log_event unconfirmed "$task" "$win" "interrupt failed, endpoint unclassifiable"
      emit escalated "$task stop unconfirmed: interrupt delivery failed, endpoint unclassifiable"
    else
      log_event unconfirmed "$task" "$win" "interrupt delivery failed, agent still alive"
      emit escalated "$task stop unconfirmed: interrupt delivery failed, agent still alive"
    fi
    return 1
  fi
  if wait_for_dead "$task" "$win" "$backend" "$HARD_WAIT"; then
    clear_record "$task"
    log_event confirmed "$task" "$win" "verified dead after hard interrupt"
    emit confirmed "$task stopped (verified after hard interrupt)"
    return 0
  fi
  write_unconfirmed "$task" "$win"
  if [ "$WAIT_LAST_VERDICT" = unknown ]; then
    log_event unconfirmed "$task" "$win" "agent state unclassifiable after hard interrupt"
    emit escalated "$task stop unconfirmed: endpoint unclassifiable after hard interrupt"
  else
    log_event unconfirmed "$task" "$win" "agent still alive after hard interrupt"
    emit escalated "$task stop unconfirmed: agent still alive after interrupt"
  fi
  return 1
}

# address: the full request -> verify -> escalate ladder for one victim.
# Returns 0 confirmed, 1 escalated, 2 no action (cooldown/unverifiable/failed).
address() {  # <task> <window> <backend>
  local task=$1 win=$2 backend=$3 lock verdict rec_ts out rc
  lock="$STATE/.stop-verify-$task.lock"
  if ! fm_lock_try_acquire "$lock"; then
    log_event failed "$task" "$win" "another stop-verification is already running"
    emit failed "another stop-verification is already running for $task"
    return 2
  fi
  # Authoritative re-read under the lock: state may have moved since classify.
  verdict=$(agent_state_verdict "$task" "$win" "$backend")
  case "$verdict" in
    dead)
      fm_lock_release "$lock"
      clear_record "$task"
      log_event confirmed "$task" "$win" already-stopped
      emit confirmed "already-stopped ($task)"
      return 0
      ;;
    unknown)
      fm_lock_release "$lock"
      log_event unverifiable "$task" "$win" "endpoint unclassifiable"
      emit unverifiable "$task endpoint cannot be classified"
      return 2
      ;;
  esac
  if rec_ts=$(record_of "$task") && in_cooldown "$rec_ts"; then
    # Re-checked under the lock: still the same unconfirmed victim.
    fm_lock_release "$lock"
    log_event cooldown "$task" "$win" "unconfirmed since $rec_ts, still alive"
    emit cooldown "$task already addressed at $rec_ts, still alive; nothing repeated"
    return 2
  fi
  if [ -n "${rec_ts:-}" ]; then
    # The cooldown has expired and the victim is STILL alive: the polite
    # request already had its chance, so this addressing goes straight to the
    # harder interrupt instead of repeating the same exit request.
    run_hard "$task" "$win" "$backend"
    rc=$?
    fm_lock_release "$lock"
    return "$rc"
  fi
  # First addressing: the polite request, one time only.
  log_event requested "$task" "$win" "polite exit delivered"
  out=$("$CONTROL" "$task" exit 2>&1); rc=$?
  if [ "$rc" -eq 0 ] \
     && { [[ "$out" == stopped\ * || "$out" == already-stopped\ * ]]; }; then
    clear_record "$task"
    log_event confirmed "$task" "$win" "control plane verified the stop"
    emit confirmed "$task stopped (control plane verified)"
    fm_lock_release "$lock"
    return 0
  fi
  # The polite request did not confirm (fm-control reports unconfirmed, or the
  # state flipped mid-flight). Verify for --verify-wait seconds, then get
  # harder. A request that failed for a reason OTHER than an unconfirmed agent
  # is still a request that cannot confirm anything.
  if wait_for_dead "$task" "$win" "$backend" "$VERIFY_WAIT"; then
    clear_record "$task"
    log_event confirmed "$task" "$win" "verified dead after polite exit"
    emit confirmed "$task stopped (verified after polite exit)"
    fm_lock_release "$lock"
    return 0
  fi
  if [ "$WAIT_LAST_VERDICT" = unknown ]; then
    # Fail-closed: never escalate onto an endpoint that became unclassifiable.
    fm_lock_release "$lock"
    log_event unverifiable "$task" "$win" "endpoint unclassifiable after polite exit"
    emit unverifiable "$task endpoint cannot be classified after polite exit"
    return 2
  fi
  # Still alive after the polite request's window: get harder, never repeat.
  run_hard "$task" "$win" "$backend"
  rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

# --- main -------------------------------------------------------------------

if [ "$LIST_MODE" = 1 ]; then
  for task in "${LIST[@]}"; do
    printf '%s %s\n' "$task" "$(classify "$task")"
  done
  exit 0
fi

for task in "${LIST[@]}"; do
  cls=$(classify "$task")
  case "$cls" in
    skipped:*)
      log_event skipped "$task" - "${cls#skipped:}"
      printf '%s skipped (%s)\n' "$task" "${cls#skipped:}"
      continue
      ;;
    unverifiable)
      log_event unverifiable "$task" - "endpoint unclassifiable"
      printf '%s unverifiable\n' "$task"
      continue
      ;;
    cooldown:*)
      log_event cooldown "$task" - "unconfirmed since ${cls#cooldown:}, still alive"
      printf '%s cooldown (already addressed at %s, still alive)\n' "$task" "${cls#cooldown:}"
      continue
      ;;
    already-stopped)
      # The candidate is already gone: a confirmed stop with no request.
      clear_record "$task"
      log_event confirmed "$task" - already-stopped
      emit confirmed "already-stopped ($task)"
      exit 0
      ;;
    eligible)
      fm_backend_validate_task_endpoint "$STATE/$task.meta" "$task" >/dev/null 2>&1
      address "$task" "$FM_BACKEND_VALIDATED_TARGET" "$FM_BACKEND_VALIDATED_BACKEND"
      exit $?
      ;;
  esac
done

# No candidate was addressable or already stopped: report instead of repeating.
echo "no candidate addressed: every candidate is in cooldown, skipped, unverifiable, or already handled"
exit 2
