#!/usr/bin/env bash
# fm-captain-context-watch.sh - restart the captain session before its context
# runs away, gated on a durable persist answer.
#
# WHY THIS EXISTS
# The captain decided on 2026-09-13 that the captain session (the Pi window
# firstmate:captain) is restarted at 500k of context. A restart is not free: it
# drops the conversation, which is where firstmate holds open work that is not
# yet written down. So the restart is a two-phase gate copied from
# bin/fm-secondmate-restart.sh phase A: a durable, correlated request asks the
# session to persist its open records, and ONLY that answer releases the
# restart - never a wall clock, never a timeout, never an assumption.
#
# WHICH VALUE CARRIES THE THRESHOLD (measured, 2026-09-13)
# Pi's footer renders `↑<cumulative input> ↓<cumulative output> <percent>%/<window> (auto)`.
# The `↓` value is the session's cumulative OUTPUT over every assistant message,
# not its context: the captain session's handover line reported `↓549k` while the
# same session's Pi JSONL summed exactly 548,854 output tokens and its last
# recorded context was ~80% of 1.0M. The context value is the percent/window
# pair, so 500k of a 1.0M window is 50.0%. This script therefore measures
# context tokens as the default metric and records the `↓` reading beside it.
# FM_CCW_METRIC=output keeps the literal `↓` reading available as a documented
# option; the threshold number itself (500000) is one value either way.
#
# WHY IT LIVES OUTSIDE THE SESSION
# A watcher that dies with the session it restarts is not one. This script is
# therefore started by the tracked systemd --user unit
# firstmate-captain-context-watch.service (bin/fm-captain-context-watch-arm.sh
# installs it), exactly like the capacity brake; it never runs inside the
# captain session's turn loop. The session only ever answers the request.
#
# THE FLOW (state machine, crash-safe, idempotent)
#   idle            - measure; at or above the threshold, capture the agent pid
#                     and enter awaiting-answer with a durable request
#   awaiting-answer - the persisted, correlated answer file is the only release
#   quiescing       - bounded wait for the session to stop being mid-turn
#   restarting      - kill ONLY the pi pid in the target pane, then start `pi`
#                     again in that pane; re-entrant, so a crash after the kill
#                     completes the start on the next cycle instead of losing it
#   aftercare       - verify a fresh watcher beat after the new agent appeared,
#                     otherwise send the session-start nudge once, and record
#                     the new footer
#
# Every transition is appended to state/.captain-context-watch.log with the
# evidence the acceptance test asks for (old footer, correlation, answer, old
# and new pid, new footer, beat). A second trigger, a restart of this process,
# or a crash cannot double-fire: the durable phase blocks a new request while
# one is in flight, the answer is bound to the request's correlation id, and a
# cooldown separates consecutive restarts.
#
# Usage:
#   fm-captain-context-watch.sh run             the long-lived loop (systemd ExecStart)
#   fm-captain-context-watch.sh step            advance the state machine exactly once
#   fm-captain-context-watch.sh measure         print one measurement as key=value
#   fm-captain-context-watch.sh answer [--corr <hex>] [--note <text>]
#                                               record the persist answer (the release)
#   fm-captain-context-watch.sh check           registered watcher check: one line when attention is due
#   fm-captain-context-watch.sh status          print unit, phase, sample, beat, journal
#   fm-captain-context-watch.sh --help
#
# Environment knobs:
#   FM_CCW_TARGET          tmux target of the captain session (default firstmate:captain)
#   FM_CCW_THRESHOLD       restart threshold (default 500000)
#   FM_CCW_METRIC          context|output - which measured value carries it
#                          (default context; see the measurement note above)
#   FM_CCW_INTERVAL        seconds between loop cycles (default 60)
#   FM_CCW_COOLDOWN        seconds after a restart before a new request may open
#                          (default 300; keeps a fresh session from re-triggering
#                          while its footer is still being read)
#   FM_CCW_QUIESCE_WAIT    bounded seconds to let the answered turn end before the
#                          kill (default 300; 0 kills as soon as the answer lands)
#   FM_CCW_RESTART_WAIT    seconds to wait for the old agent to exit and the new
#                          one to appear (default 60)
#   FM_CCW_AFTERCARE_WAIT  seconds to wait for a fresh watcher beat after the new
#                          agent appeared before nudging once (default 180)
#   FM_CCW_LAUNCH_CMD      command typed into the pane to start the agent (default pi)
#   FM_CCW_FOOTER_FILE     read the footer text from this file instead of tmux
#                          (deterministic tests and manual drills only)
#   FM_CCW_BEAT_GRACE      check alarm when the loop beat is older than this
#                          (default 300)
#   FM_CCW_ALARM_REPEAT    seconds before a still-present alarm is re-reported
#                          (default 3600)
#   FM_CCW_REMIND_AFTER    seconds between persist-request reminders (default 1800)
#   FM_CCW_REMIND_MAX      reminders after the initial request, then silence
#                          (default 3)
#   FM_CCW_UNREADABLE_ALARM  consecutive unreadable samples before the check
#                          reports the footer as unmeasurable (default 5)
#   FM_CCW_STALL_ALARM     seconds a restart phase may stay unfinished before
#                          the check reports it (default 900)
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

TARGET=${FM_CCW_TARGET:-firstmate:captain}
THRESHOLD=${FM_CCW_THRESHOLD:-500000}
METRIC=${FM_CCW_METRIC:-context}
INTERVAL=${FM_CCW_INTERVAL:-60}
COOLDOWN=${FM_CCW_COOLDOWN:-300}
QUIESCE_WAIT=${FM_CCW_QUIESCE_WAIT:-300}
RESTART_WAIT=${FM_CCW_RESTART_WAIT:-60}
AFTERCARE_WAIT=${FM_CCW_AFTERCARE_WAIT:-180}
LAUNCH_CMD=${FM_CCW_LAUNCH_CMD:-pi}
FOOTER_FILE=${FM_CCW_FOOTER_FILE:-}
BEAT_GRACE=${FM_CCW_BEAT_GRACE:-300}
ALARM_REPEAT=${FM_CCW_ALARM_REPEAT:-3600}
REMIND_AFTER=${FM_CCW_REMIND_AFTER:-1800}
REMIND_MAX=${FM_CCW_REMIND_MAX:-3}
UNREADABLE_ALARM=${FM_CCW_UNREADABLE_ALARM:-5}
STALL_ALARM=${FM_CCW_STALL_ALARM:-900}

STATE_FILE="$STATE/.captain-context-watch.state"
REQUEST_FILE="$STATE/.captain-context-watch.request"
ANSWER_FILE="$STATE/.captain-context-watch.answer"
NOTIFIED_FILE="$STATE/.captain-context-watch.notified"
LOCK_FILE="$STATE/.captain-context-watch.lock"
BEAT_FILE="$STATE/.captain-context-watch-beat"
WATCHER_BEAT_FILE="$STATE/.last-watcher-beat"
LOG_FILE="$STATE/.captain-context-watch.log"

# The journal keeps the newest half of this many lines: enough to reconstruct
# several crossings without letting a chattering alarm path grow a file forever.
JOURNAL_MAX_LINES=4000

STATE_SCHEMA=fm-captain-context-watch-state-v1
STATE_KEYS='phase corr crossed_epoch crossed_context crossed_footer old_pid
  answer_epoch answer_note quiesce_deadline phase_epoch restart_epoch new_pid
  aftercare_deadline nudge_sent last_restart_epoch last_context last_percent
  last_window last_output last_input last_footer last_measured_epoch
  unreadable_streak err_note err_tag err_count'
NOTE_SCHEMA=fm-captain-context-watch-notified-v1
NOTE_KEYS='persist_corr persist_sent persist_last_epoch beat_last_epoch
  stall_last_epoch unreadable_last_epoch'
# Fold the key lists onto one line so a membership test can match a key that
# ends a list line; a newline would otherwise swallow its trailing space.
STATE_KEYS_FLAT=$(printf '%s' "$STATE_KEYS" | tr '\n' ' ')
NOTE_KEYS_FLAT=$(printf '%s' "$NOTE_KEYS" | tr '\n' ' ')

usage() {
  sed -n '/^# Usage:/,/^set -u/p' "$0" | sed '/^set -u/d;s/^# \{0,1\}//'
}

die_usage() {
  printf 'fm-captain-context-watch: %s\n' "$1" >&2
  usage >&2
  exit 2
}

error() {
  printf 'fm-captain-context-watch: %s\n' "$1" >&2
}

# --- validation -------------------------------------------------------------

require_uint() {  # <name> <value> [minimum]
  local name=$1 value=$2 minimum=${3:-0}
  case "$value" in
    ''|*[!0-9]*) die_usage "$name must be a whole number (got '$value')" ;;
  esac
  [ "$value" -ge "$minimum" ] || die_usage "$name must be at least $minimum (got '$value')"
}

require_uint FM_CCW_THRESHOLD "$THRESHOLD" 1
require_uint FM_CCW_INTERVAL "$INTERVAL" 1
require_uint FM_CCW_COOLDOWN "$COOLDOWN" 0
require_uint FM_CCW_QUIESCE_WAIT "$QUIESCE_WAIT" 0
require_uint FM_CCW_RESTART_WAIT "$RESTART_WAIT" 1
require_uint FM_CCW_AFTERCARE_WAIT "$AFTERCARE_WAIT" 1
require_uint FM_CCW_BEAT_GRACE "$BEAT_GRACE" 1
require_uint FM_CCW_ALARM_REPEAT "$ALARM_REPEAT" 1
require_uint FM_CCW_REMIND_AFTER "$REMIND_AFTER" 1
require_uint FM_CCW_REMIND_MAX "$REMIND_MAX" 0
require_uint FM_CCW_UNREADABLE_ALARM "$UNREADABLE_ALARM" 1
require_uint FM_CCW_STALL_ALARM "$STALL_ALARM" 1
case "$METRIC" in context|output) ;; *) die_usage "FM_CCW_METRIC must be context or output (got '$METRIC')" ;; esac
[ -n "$TARGET" ] || die_usage 'FM_CCW_TARGET must not be empty'
[ -d "$STATE" ] && [ ! -L "$STATE" ] || die_usage "state directory is unavailable: $STATE"

# --- small helpers ----------------------------------------------------------

fm_ccw_mtime() {  # <path>; empty when unreadable
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_ccw_now() { date +%s; }

fm_ccw_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }

fm_ccw_one_line() {  # <text> - collapse to one line for key=value records
  printf '%s' "$1" | tr '\t\r\n' '   ' | tr -s ' '
}

fm_ccw_tokens() {  # <formatted-token-value> -> whole tokens, empty when invalid
  local value=$1 number suffix scale
  case "$value" in
    *k) suffix=k; number=${value%k} ;;
    *M) suffix=M; number=${value%M} ;;
    *) suffix=''; number=$value ;;
  esac
  case "$number" in
    ''|*[!0-9.]*) return 1 ;;
  esac
  case "$suffix" in
    k) scale=1000 ;;
    M) scale=1000000 ;;
    *) scale=1 ;;
  esac
  awk -v n="$number" -v s="$scale" 'BEGIN { printf "%.0f", n * s }'
}

# --- the measurement --------------------------------------------------------

# The pi footer is the bottom-most line of the pane in this shape:
#   ↑9.2M ↓144k 26.1%/1.0M (auto)  (provider) model • effort
# Extension status lines may follow it, so the parser scans a bounded tail for
# the last line that carries the percent/window pair instead of trusting the
# very last line. An unparseable footer is reported as such, never guessed.
fm_ccw_capture() {
  if [ -n "$FOOTER_FILE" ]; then
    cat "$FOOTER_FILE" 2>/dev/null || return 1
    return 0
  fi
  command -v tmux >/dev/null 2>&1 || return 1
  tmux capture-pane -p -t "$TARGET" 2>/dev/null || return 1
}

# Sets ME_* for one sample:
#   ME_STATUS   ok|no-percent|no-footer|capture-error
#   ME_FOOTER   the matched footer line (empty when none)
#   ME_PERCENT  numeric percent, empty when unknown
#   ME_WINDOW   window in tokens, empty when unknown
#   ME_CONTEXT  context tokens, empty when unknown
#   ME_OUTPUT   cumulative output tokens from ↓ (empty when absent)
#   ME_INPUT    cumulative input tokens from ↑ (empty when absent)
fm_ccw_measure() {
  local text line segment percent window output input
  ME_STATUS=capture-error
  ME_FOOTER=
  ME_PERCENT=
  ME_WINDOW=
  ME_CONTEXT=
  ME_OUTPUT=
  ME_INPUT=
  text=$(fm_ccw_capture) || return 0
  ME_STATUS=no-footer
  line=$(printf '%s\n' "$text" | tail -n 8 \
    | grep -E '([0-9]+(\.[0-9]+)?%|\?)/[0-9]+(\.[0-9]+)?[kM]' | tail -n 1)
  [ -n "$line" ] || return 0
  ME_FOOTER=$(fm_ccw_one_line "$line")
  segment=$(printf '%s' "$line" \
    | grep -oE '([0-9]+(\.[0-9]+)?%|\?)/[0-9]+(\.[0-9]+)?[kM]' | tail -n 1)
  percent=${segment%%/*}
  window=${segment##*/}
  percent=${percent%\%}
  ME_WINDOW=$(fm_ccw_tokens "$window" 2>/dev/null || true)
  output=$(printf '%s' "$line" | grep -oE '↓[0-9]+(\.[0-9]+)?[kM]' | head -n 1)
  input=$(printf '%s' "$line" | grep -oE '↑[0-9]+(\.[0-9]+)?[kM]' | head -n 1)
  [ -z "$output" ] || ME_OUTPUT=$(fm_ccw_tokens "${output#↓}" 2>/dev/null || true)
  [ -z "$input" ] || ME_INPUT=$(fm_ccw_tokens "${input#↑}" 2>/dev/null || true)
  if [ "$percent" = '?' ]; then
    ME_STATUS=no-percent
    return 0
  fi
  case "$percent" in
    ''|*[!0-9.]*) ME_STATUS=no-percent; return 0 ;;
  esac
  [ -n "$ME_WINDOW" ] || { ME_STATUS=no-percent; return 0; }
  ME_PERCENT=$percent
  ME_CONTEXT=$(awk -v p="$percent" -v w="$ME_WINDOW" 'BEGIN { printf "%.0f", p * w / 100 }')
  ME_STATUS=ok
}

# --- durable state ----------------------------------------------------------

# Loads every state key into ST_<key>. Missing or malformed lines fall back to
# the defaults below, so a truncated state file degrades to idle rather than to
# an undefined phase.
fm_ccw_state_load() {
  local key value
  ST_phase=idle
  ST_corr=
  ST_crossed_epoch=0
  ST_crossed_context=
  ST_crossed_footer=
  ST_old_pid=
  ST_answer_epoch=0
  ST_answer_note=
  ST_quiesce_deadline=0
  ST_phase_epoch=0
  ST_restart_epoch=0
  ST_new_pid=
  ST_aftercare_deadline=0
  ST_nudge_sent=0
  ST_last_restart_epoch=0
  ST_last_context=
  ST_last_percent=
  ST_last_window=
  ST_last_output=
  ST_last_input=
  ST_last_footer=
  ST_last_measured_epoch=0
  ST_unreadable_streak=0
  ST_err_note=
  ST_err_tag=
  ST_err_count=0
  [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || return 0
  while IFS= read -r key_value; do
    key=${key_value%%=*}
    value=${key_value#*=}
    case " $STATE_KEYS_FLAT " in
      *" $key "*) printf -v "ST_$key" '%s' "$value" ;;
    esac
  done < "$STATE_FILE"
  return 0
}

fm_ccw_state_save() {
  local key name value tmp
  tmp=$(umask 077; mktemp "$STATE/.captain-context-watch.state.XXXXXX" 2>/dev/null) || return 1
  {
    printf 'schema=%s\n' "$STATE_SCHEMA"
    for key in $STATE_KEYS; do
      name="ST_$key"
      value=${!name:-}
      printf '%s=%s\n' "$key" "$(fm_ccw_one_line "$value")"
    done
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$STATE_FILE" || { rm -f -- "$tmp"; return 1; }
  return 0
}

fm_ccw_journal() {  # <phase> <detail...>
  local phase=$1 detail=${2:-} lines
  printf '%s phase=%s %s\n' "$(fm_ccw_iso)" "$phase" "$(fm_ccw_one_line "$detail")" >> "$LOG_FILE" || return 1
  lines=$(wc -l < "$LOG_FILE" 2>/dev/null | tr -d ' ')
  case "$lines" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$lines" -le "$JOURNAL_MAX_LINES" ] && return 0
  if ! tail -n $((JOURNAL_MAX_LINES / 2)) "$LOG_FILE" > "$LOG_FILE.trim" 2>/dev/null \
    || ! mv -f "$LOG_FILE.trim" "$LOG_FILE"; then
    rm -f -- "$LOG_FILE.trim"
  fi
  return 0
}

fm_ccw_beat() {
  umask 077
  : > "$BEAT_FILE" 2>/dev/null || true
}

fm_ccw_uint_or() {  # <value> <default>
  case "$1" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

# --- the check-owned notification record ------------------------------------
# The registered watcher check runs outside the loop and never rewrites the
# loop's state; its own bookkeeping (what it has already reported, and when)
# lives here instead.

fm_ccw_note_load() {
  local key value
  NO_persist_corr=
  NO_persist_sent=0
  NO_persist_last_epoch=0
  NO_beat_last_epoch=0
  NO_stall_last_epoch=0
  NO_unreadable_last_epoch=0
  [ -f "$NOTIFIED_FILE" ] && [ ! -L "$NOTIFIED_FILE" ] || return 0
  while IFS= read -r key_value; do
    key=${key_value%%=*}
    value=${key_value#*=}
    case " $NOTE_KEYS_FLAT " in
      *" $key "*) printf -v "NO_$key" '%s' "$value" ;;
    esac
  done < "$NOTIFIED_FILE"
  return 0
}

fm_ccw_note_save() {
  local key name value tmp
  tmp=$(umask 077; mktemp "$STATE/.captain-context-watch.notified.XXXXXX" 2>/dev/null) || return 1
  {
    printf 'schema=%s\n' "$NOTE_SCHEMA"
    for key in $NOTE_KEYS; do
      name="NO_$key"
      value=${!name:-}
      printf '%s=%s\n' "$key" "$(fm_ccw_one_line "$value")"
    done
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$NOTIFIED_FILE" || { rm -f -- "$tmp"; return 1; }
  return 0
}

fm_ccw_report_due() {  # <last-epoch> <window> <now>
  local last=$1 window=$2 now=$3
  case "$last" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$last" -gt 0 ] || return 0
  [ $(( now - last )) -ge "$window" ]
}

fm_ccw_emit_finding() {  # <accumulator-var> <text>
  local name=$1 text=$2 current=${!1}
  if [ -z "$current" ]; then
    printf -v "$name" '%s' "$text"
  else
    printf -v "$name" '%s; %s' "$current" "$text"
  fi
}

# --- the captain pane -------------------------------------------------------

fm_ccw_pane_pid() {  # prints the pane's shell pid, empty when unreadable
  command -v tmux >/dev/null 2>&1 || return 0
  tmux display-message -p -t "$TARGET" '#{pane_pid}' 2>/dev/null || true
}

# The agent process in the pane: the direct child of the pane shell whose
# process name is exactly the launch command's basename. Works for the real
# `pi` and for a test stand-in alike, and never touches any other process.
fm_ccw_agent_pid() {
  local pane_pid command_name
  pane_pid=$(fm_ccw_pane_pid)
  [ -n "$pane_pid" ] || return 0
  case "$pane_pid" in *[!0-9]*) return 0 ;; esac
  command_name=${LAUNCH_CMD##*/}
  ps -axo pid=,ppid=,comm= 2>/dev/null \
    | awk -v parent="$pane_pid" -v want="$command_name" '$2 == parent && $3 == want { print $1; exit }'
}

fm_ccw_wait_agent() {  # <previous-pid>; prints the new pid, empty on timeout
  local previous=$1 deadline pid
  deadline=$(( $(fm_ccw_now) + RESTART_WAIT ))
  while :; do
    pid=$(fm_ccw_agent_pid)
    if [ -n "$pid" ] && [ "$pid" != "$previous" ]; then
      printf '%s\n' "$pid"
      return 0
    fi
    [ "$(fm_ccw_now)" -lt "$deadline" ] || break
    sleep 1
  done
  return 1
}

fm_ccw_kill_agent() {  # <pid>; TERM then bounded KILL, never another pid
  local pid=$1 deadline
  kill -TERM "$pid" 2>/dev/null || return 0
  deadline=$(( $(fm_ccw_now) + RESTART_WAIT ))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$(fm_ccw_now)" -ge "$deadline" ]; then
      kill -KILL "$pid" 2>/dev/null || true
      deadline=$(( $(fm_ccw_now) + 10 ))
      while kill -0 "$pid" 2>/dev/null && [ "$(fm_ccw_now)" -lt "$deadline" ]; do
        sleep 1
      done
      kill -0 "$pid" 2>/dev/null && return 1
      return 0
    fi
    sleep 1
  done
  return 0
}

fm_ccw_start_agent() {
  local existing
  existing=$(fm_ccw_agent_pid)
  [ -z "$existing" ] || return 0
  command -v tmux >/dev/null 2>&1 || return 1
  tmux send-keys -t "$TARGET" "$LAUNCH_CMD" Enter 2>/dev/null || return 1
  return 0
}

# The one aftercare nudge. It is the same operational input the session-start
# nudge tier carries, submitted through the fleet's guarded tmux submit
# primitive, so it can never concatenate onto half-typed text. Non-empty output
# means the submit could not be confirmed; that is journaled, never retried
# blindly.
fm_ccw_nudge() {
  local body text verdict
  # shellcheck disable=SC2016  # the backticks are the nudge's literal text
  body='Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
  text=$("$SCRIPT_DIR/fm-operational-input.sh" encode session-start <<< "$body" 2>/dev/null) || return 1
  fm_ccw_load_tmux_lib
  verdict=$(fm_tmux_submit_core "$TARGET" "$text" 3 0.5 0.5)
  printf '%s\n' "$verdict"
  return 0
}

# --- phase steps ------------------------------------------------------------

fm_ccw_begin_request()  {  # <now> <old-pid>
  local now=$1 old_pid=$2 corr
  corr=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  case "$corr" in
    ''|*[!0-9a-f]*) error 'could not mint a correlation id'; return 1 ;;
  esac
  ST_corr=$corr
  ST_crossed_epoch=$now
  ST_crossed_context=$ME_CONTEXT
  ST_crossed_footer=$ME_FOOTER
  ST_old_pid=$old_pid
  ST_answer_epoch=0
  ST_answer_note=
  ST_err_note=
  ST_err_tag=
  ST_err_count=0
  fm_ccw_request_write || { error 'could not write the persist request'; return 1; }
  ST_phase=awaiting-answer
  ST_phase_epoch=$now
  fm_ccw_journal crossed "corr=$corr context=$ME_CONTEXT percent=$ME_PERCENT window=$ME_WINDOW output=${ME_OUTPUT:-none} input=${ME_INPUT:-none} old_pid=$old_pid footer=\"$ME_FOOTER\""
  return 0
}

fm_ccw_request_write() {
  local tmp
  tmp=$(umask 077; mktemp "$STATE/.captain-context-watch.request.XXXXXX" 2>/dev/null) || return 1
  {
    printf '%s\n' \
      'CAPTAIN CONTEXT WATCH - open-record persistence request' \
      '' \
      "This session's context reached the restart threshold: ${ST_crossed_context} >= ${THRESHOLD} tokens." \
      'A fresh session will replace this one once the open work that lives only in this conversation is durably recorded.' \
      '' \
      'That is the /stow skill'"'"'s "Open-record persistence" contract and nothing more:' \
      '' \
      '- file a backlog task for each open record that exists only in this conversation, including any captain call you formed but never registered;' \
      '- correct any task whose recorded state no longer reflects what you now know.' \
      '' \
      'Do NOT run the memory, learnings, or captain-preference sweeps.' \
      '' \
      'When that is done, run exactly:' \
      '' \
      "    bin/fm-captain-context-watch.sh answer --corr ${ST_corr}" \
      '' \
      'That durable answer is the only thing that releases the restart. If you deliberately leave something' \
      "unpersisted, record it in the same command with --note '...' and answer anyway; the restart proceeds" \
      'either way and the note is journaled. Nothing restarts this session before the answer lands.' \
      '' \
      "Correlation: ${ST_corr}" \
      "Requested: $(fm_ccw_iso)"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$REQUEST_FILE" || { rm -f -- "$tmp"; return 1; }
  return 0
}

fm_ccw_answer_read() {  # sets AN_corr/AN_epoch/AN_note; false when absent
  local line key value
  AN_corr=
  AN_epoch=0
  AN_note=
  [ -f "$ANSWER_FILE" ] && [ ! -L "$ANSWER_FILE" ] || return 1
  while IFS= read -r line; do
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      corr) AN_corr=$value ;;
      epoch) AN_epoch=$value ;;
      note) AN_note=$value ;;
    esac
  done < "$ANSWER_FILE"
  [ -n "$AN_corr" ] || return 1
  return 0
}

fm_ccw_step_idle() {  # <now>
  local now=$1 value old_pid
  case "$ME_STATUS" in
    ok) value=$ME_CONTEXT ;;
    *) return 0 ;;
  esac
  [ -n "$value" ] || return 0
  case "$value" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$METRIC" = output ]; then
    value=${ME_OUTPUT:-}
    case "$value" in ''|*[!0-9]*) return 0 ;; esac
  fi
  [ "$value" -ge "$THRESHOLD" ] || return 0
  [ $(( now - ST_last_restart_epoch )) -ge "$COOLDOWN" ] || return 0
  old_pid=$(fm_ccw_agent_pid)
  if [ -z "$old_pid" ]; then
    fm_ccw_error_once "$now" crossed-no-agent "context=$ME_CONTEXT threshold=$THRESHOLD target=$TARGET"
    return 0
  fi
  fm_ccw_begin_request "$now" "$old_pid"
}

fm_ccw_step_awaiting() {  # <now>
  local now=$1
  fm_ccw_answer_read || return 0
  [ "$AN_corr" = "$ST_corr" ] || return 0
  case "$AN_epoch" in
    ''|*[!0-9]*) ST_answer_epoch=$now ;;
    *) ST_answer_epoch=$AN_epoch ;;
  esac
  ST_answer_note=$AN_note
  ST_phase=quiescing
  ST_phase_epoch=$now
  ST_quiesce_deadline=$(( now + QUIESCE_WAIT ))
  fm_ccw_journal answered "corr=$ST_corr note=\"${AN_note:-}\""
  return 0
}

fm_ccw_load_tmux_lib() {
  [ -n "${FM_CCW_TMUX_LIB_LOADED:-}" ] && return 0
  # shellcheck source=bin/fm-tmux-lib.sh
  . "$SCRIPT_DIR/fm-tmux-lib.sh"
  FM_CCW_TMUX_LIB_LOADED=1
  return 0
}

fm_ccw_pane_busy() {  # busy|idle|unknown
  command -v tmux >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  fm_ccw_load_tmux_lib
  fm_pane_busy_state "$TARGET" pi 2>/dev/null || printf 'unknown'
}

fm_ccw_step_quiescing() {  # <now>
  local now=$1 busy deadline
  busy=$(fm_ccw_pane_busy)
  deadline=$(fm_ccw_uint_or "${ST_quiesce_deadline:-0}" 0)
  if [ "$busy" = busy ] && [ "$now" -lt "$deadline" ]; then
    return 0
  fi
  ST_phase=restarting
  ST_phase_epoch=$now
  ST_restart_epoch=$now
  fm_ccw_journal restart-begin "corr=$ST_corr old_pid=${ST_old_pid:-none} quiesced=$busy"
  return 0
}

fm_ccw_step_restarting() {  # <now>
  local now=$1 current new_pid
  current=$(fm_ccw_agent_pid)
  if [ -n "$current" ] && [ -n "$ST_old_pid" ] && [ "$current" != "$ST_old_pid" ]; then
    # The session was already replaced (an external restart, or this process
    # crashed after starting the new agent). Adopt it and move on.
    ST_new_pid=$current
    ST_restart_epoch=$now
    ST_phase=aftercare
    ST_phase_epoch=$now
    ST_aftercare_deadline=$(( now + AFTERCARE_WAIT ))
    fm_ccw_journal restart-done "old_pid=${ST_old_pid:-none} new_pid=$current adopted=1"
    return 0
  fi
  if [ -n "$current" ]; then
    if ! fm_ccw_kill_agent "$current"; then
      fm_ccw_restart_error "$now" "the agent pid $current did not stop"
      return 0
    fi
    fm_ccw_journal restart-killed "old_pid=$current"
  fi
  if ! fm_ccw_start_agent; then
    fm_ccw_restart_error "$now" "could not start $LAUNCH_CMD in $TARGET"
    return 0
  fi
  new_pid=$(fm_ccw_wait_agent "${ST_old_pid:-}") || {
    fm_ccw_restart_error "$now" "the new agent did not appear within ${RESTART_WAIT}s"
    return 0
  }
  ST_new_pid=$new_pid
  ST_restart_epoch=$now
  ST_err_note=
  ST_err_tag=
  ST_err_count=0
  ST_phase=aftercare
  ST_phase_epoch=$now
  ST_aftercare_deadline=$(( now + AFTERCARE_WAIT ))
  fm_ccw_journal restart-done "old_pid=${ST_old_pid:-none} new_pid=$new_pid"
  return 0
}

# Journal one durable error line, at once for a new kind and only every tenth
# repetition of the same kind, so a stuck port cannot fill the journal.
fm_ccw_error_once() {  # <now> <tag> <note>
  local now=$1 tag=$2 note=$3 count
  count=$(fm_ccw_uint_or "${ST_err_count:-0}" 0)
  count=$(( count + 1 ))
  ST_err_count=$count
  if [ "$tag" != "${ST_err_tag:-}" ] || [ $(( count % 10 )) -eq 0 ]; then
    ST_err_tag=$tag
    ST_err_note=$note
    fm_ccw_journal "$tag" "attempt=$count note=\"$note\""
  fi
  return 0
}

# A failing restart attempt must not refresh the phase epoch: the check's stall
# alarm is measured from the moment the phase was entered, so a port failing
# every cycle still surfaces instead of resetting its own watchdog.
fm_ccw_restart_error() {  # <now> <note>
  local now=$1 note=$2
  fm_ccw_error_once "$now" restart-error "$note"
  return 0
}

fm_ccw_step_aftercare() {  # <now>
  local now=$1 beat_epoch age verdict restart_epoch aftercare_deadline
  # The watcher's own liveness beacon, owned by bin/fm-watch.sh - not this
  # loop's beat. A fresh watcher beat after the new agent appeared is the proof
  # that supervision came back with it.
  beat_epoch=$(fm_ccw_mtime "$WATCHER_BEAT_FILE")
  case "$beat_epoch" in
    ''|*[!0-9]*) beat_epoch=0 ;;
  esac
  restart_epoch=$(fm_ccw_uint_or "${ST_restart_epoch:-0}" 0)
  aftercare_deadline=$(fm_ccw_uint_or "${ST_aftercare_deadline:-0}" 0)
  if [ "$beat_epoch" -ge "$restart_epoch" ] && [ "$beat_epoch" -gt 0 ]; then
    age=$(( now - beat_epoch ))
    ST_last_context=$ME_CONTEXT
    ST_last_percent=$ME_PERCENT
    ST_last_window=$ME_WINDOW
    ST_last_output=${ME_OUTPUT:-}
    ST_last_input=${ME_INPUT:-}
    ST_last_footer=$ME_FOOTER
    ST_last_measured_epoch=$now
    ST_last_restart_epoch=$now
    fm_ccw_journal aftercare-done "new_pid=${ST_new_pid:-none} context=$ME_CONTEXT percent=$ME_PERCENT output=${ME_OUTPUT:-none} watcher_beat_epoch=$beat_epoch watcher_beat_age=${age}s footer=\"$ME_FOOTER\""
    fm_ccw_phase_idle_cleanup
    ST_phase=idle
    ST_phase_epoch=$now
    return 0
  fi
  if [ "$now" -ge "$aftercare_deadline" ]; then
    if [ "${ST_nudge_sent:-0}" != 1 ]; then
      verdict=$(fm_ccw_nudge 2>/dev/null || true)
      [ -n "$verdict" ] || verdict=unavailable
      ST_nudge_sent=1
      fm_ccw_journal aftercare-nudge "verdict=$verdict context=${ME_CONTEXT:-unknown} footer=\"${ME_FOOTER:-}\""
    fi
    ST_last_restart_epoch=$now
    fm_ccw_phase_idle_cleanup
    ST_phase=idle
    ST_phase_epoch=$now
    return 0
  fi
  return 0
}

fm_ccw_phase_idle_cleanup() {
  rm -f -- "$REQUEST_FILE" "$ANSWER_FILE"
  ST_corr=
  ST_old_pid=
  ST_nudge_sent=0
  ST_quiesce_deadline=0
  ST_aftercare_deadline=0
}

# --- one step and the loop --------------------------------------------------

fm_ccw_record_sample() {  # <now>
  local now=$1
  ST_last_measured_epoch=$now
  if [ "$ME_STATUS" = ok ]; then
    ST_unreadable_streak=0
    ST_last_context=$ME_CONTEXT
    ST_last_percent=$ME_PERCENT
    ST_last_window=$ME_WINDOW
    ST_last_output=${ME_OUTPUT:-}
    ST_last_input=${ME_INPUT:-}
    ST_last_footer=$ME_FOOTER
  else
    ST_unreadable_streak=$((${ST_unreadable_streak:-0} + 1))
    [ -n "$ME_FOOTER" ] || ST_last_footer=
  fi
}

fm_ccw_step() {
  local now
  now=$(fm_ccw_now)
  fm_ccw_state_load
  fm_ccw_measure || true
  fm_ccw_record_sample "$now"
  case "$ST_phase" in
    idle) fm_ccw_step_idle "$now" ;;
    awaiting-answer) fm_ccw_step_awaiting "$now" ;;
    quiescing) fm_ccw_step_quiescing "$now" ;;
    restarting) fm_ccw_step_restarting "$now" ;;
    aftercare) fm_ccw_step_aftercare "$now" ;;
    *)
      fm_ccw_journal unknown-phase "phase=$ST_phase"
      ST_phase=idle
      ST_phase_epoch=$now
      ;;
  esac
  fm_ccw_state_save || error 'could not write the state record'
  fm_ccw_beat
  return 0
}

fm_ccw_pid_is_loop() {  # <pid>; /proc cmdline identity where available
  local pid=$1 cmd
  [ -r "/proc/$pid/cmdline" ] || return 0
  cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
  case "$cmd" in
    *fm-captain-context-watch.sh*) return 0 ;;
  esac
  return 1
}

# Refuse a second loop. A stale lock (dead pid, or a live pid that is provably
# not this loop) is taken over; a live loop is never raced.
fm_ccw_lock_acquire() {
  local pid tmp
  if [ -f "$LOCK_FILE" ]; then
    pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    case "$pid" in
      ''|*[!0-9]*) ;;
      *)
        if kill -0 "$pid" 2>/dev/null && fm_ccw_pid_is_loop "$pid"; then
          error "another context watch loop is running (pid $pid)"
          return 1
        fi
        ;;
    esac
  fi
  tmp=$(umask 077; mktemp "$STATE/.captain-context-watch.lock.XXXXXX" 2>/dev/null) || return 1
  printf '%s\n' "$$" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$LOCK_FILE" || { rm -f -- "$tmp"; return 1; }
  return 0
}

fm_ccw_lock_release() {
  local pid
  pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
  [ "$pid" = "$$" ] && rm -f -- "$LOCK_FILE"
  return 0
}

fm_ccw_lock_refuse_concurrent_step() {
  local pid
  [ -f "$LOCK_FILE" ] || return 0
  pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
    "$$") return 0 ;;
  esac
  if kill -0 "$pid" 2>/dev/null && fm_ccw_pid_is_loop "$pid"; then
    error "another context watch loop is running (pid $pid); stop it before a manual step"
    return 1
  fi
  return 0
}

# --- actions ----------------------------------------------------------------

cmd_measure() {
  fm_ccw_measure || true
  printf 'status=%s\n' "$ME_STATUS"
  printf 'footer=%s\n' "$ME_FOOTER"
  printf 'percent=%s\n' "$ME_PERCENT"
  printf 'window=%s\n' "$ME_WINDOW"
  printf 'context=%s\n' "$ME_CONTEXT"
  printf 'output=%s\n' "${ME_OUTPUT:-}"
  printf 'input=%s\n' "${ME_INPUT:-}"
  printf 'threshold=%s\n' "$THRESHOLD"
  printf 'metric=%s\n' "$METRIC"
  return 0
}

cmd_step() {
  fm_ccw_lock_refuse_concurrent_step || exit 2
  fm_ccw_step
}

cmd_run() {
  if [ -z "$FOOTER_FILE" ] && ! command -v tmux >/dev/null 2>&1; then
    error 'tmux is required to read the captain session footer'
    exit 1
  fi
  fm_ccw_lock_acquire || exit 2
  trap 'fm_ccw_lock_release; exit 0' TERM INT HUP
  fm_ccw_journal loop-start "pid=$$ target=$TARGET threshold=$THRESHOLD metric=$METRIC interval=$INTERVAL"
  while :; do
    fm_ccw_step || true
    sleep "$INTERVAL"
  done
}

cmd_answer() {
  local note='' expect_corr='' arg
  while [ "$#" -gt 0 ]; do
    arg=$1
    case "$arg" in
      --corr) [ "$#" -ge 2 ] || die_usage '--corr needs a value'; expect_corr=$2; shift 2 ;;
      --note) [ "$#" -ge 2 ] || die_usage '--note needs a value'; note=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die_usage "unexpected argument '$arg'" ;;
    esac
  done
  fm_ccw_state_load
  [ "$ST_phase" = awaiting-answer ] || {
    error 'no persist request is pending'
    exit 1
  }
  [ -n "$ST_corr" ] || { error 'the pending request has no correlation id'; exit 1; }
  if [ -n "$expect_corr" ] && [ "$expect_corr" != "$ST_corr" ]; then
    error "correlation mismatch: pending is $ST_corr"
    exit 1
  fi
  fm_ccw_marker_write "$STATE/.captain-context-watch.answer.XXXXXX" "$ANSWER_FILE" \
    "$ST_corr" "$(fm_ccw_now)" "$note" || { error 'could not record the answer'; exit 1; }
  fm_ccw_journal answer "corr=$ST_corr note=\"$(fm_ccw_one_line "$note")\""
  printf 'captain-context-watch: answer recorded for %s\n' "$ST_corr"
  return 0
}

fm_ccw_marker_write() {  # <mktemp-template> <destination> <corr> <epoch> <note>
  local template=$1 destination=$2 corr=$3 epoch=$4 note=$5 tmp
  tmp=$(umask 077; mktemp "$template" 2>/dev/null) || return 1
  {
    printf '%s\n' fm-captain-context-watch-answer-v1
    printf 'corr=%s\n' "$corr"
    printf 'epoch=%s\n' "$epoch"
    printf 'note=%s\n' "$(fm_ccw_one_line "$note")"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$destination" || { rm -f -- "$tmp"; return 1; }
  return 0
}

cmd_check() {
  local now beat_epoch streak started sent minutes findings='' dirty=0
  fm_ccw_state_load
  fm_ccw_note_load
  now=$(fm_ccw_now)

  # 1. The loop's liveness beacon.
  beat_epoch=$(fm_ccw_mtime "$BEAT_FILE")
  case "$beat_epoch" in
    ''|*[!0-9]*) beat_epoch=0 ;;
  esac
  if [ "$beat_epoch" -eq 0 ] || [ $(( now - beat_epoch )) -ge "$BEAT_GRACE" ]; then
    if fm_ccw_report_due "$NO_beat_last_epoch" "$ALARM_REPEAT" "$now"; then
      if [ "$beat_epoch" -eq 0 ]; then
        fm_ccw_emit_finding findings "watcher loop has never beaten (target $TARGET)"
      else
        fm_ccw_emit_finding findings "watcher loop beat is $(( now - beat_epoch ))s old (> ${BEAT_GRACE}s) - the context watcher is not running"
      fi
      NO_beat_last_epoch=$now
      dirty=1
    fi
  elif [ "$NO_beat_last_epoch" != 0 ]; then
    NO_beat_last_epoch=0
    dirty=1
  fi

  # 2. A footer that cannot be measured, reported once it has persisted.
  streak=$(fm_ccw_uint_or "${ST_unreadable_streak:-0}" 0)
  if [ "$streak" -ge "$UNREADABLE_ALARM" ]; then
    if fm_ccw_report_due "$NO_unreadable_last_epoch" "$ALARM_REPEAT" "$now"; then
      fm_ccw_emit_finding findings "footer unreadable for $streak consecutive samples (target $TARGET) - the captain context cannot be measured"
      NO_unreadable_last_epoch=$now
      dirty=1
    fi
  elif [ "$NO_unreadable_last_epoch" != 0 ]; then
    NO_unreadable_last_epoch=0
    dirty=1
  fi

  # 3. The persist request, announced once and then reminded on its own cadence.
  if [ "$ST_phase" = awaiting-answer ] && [ -n "$ST_corr" ]; then
    if [ "$NO_persist_corr" != "$ST_corr" ]; then
      fm_ccw_emit_finding findings "context ${ST_crossed_context:-unknown} >= $THRESHOLD (corr=$ST_corr) - persist open records before the restart: read $REQUEST_FILE, then run bin/fm-captain-context-watch.sh answer --corr $ST_corr"
      NO_persist_corr=$ST_corr
      NO_persist_sent=1
      NO_persist_last_epoch=$now
      dirty=1
    else
      sent=$(fm_ccw_uint_or "$NO_persist_sent" 0)
      if [ "$sent" -lt $(( 1 + REMIND_MAX )) ] \
        && fm_ccw_report_due "$NO_persist_last_epoch" "$REMIND_AFTER" "$now"; then
        minutes=$(( (now - $(fm_ccw_uint_or "${ST_crossed_epoch:-0}" 0) + 59) / 60 ))
        fm_ccw_emit_finding findings "persist request $ST_corr still unanswered after ${minutes}min (context ${ST_last_context:-unknown}) - read $REQUEST_FILE and answer with bin/fm-captain-context-watch.sh answer --corr $ST_corr"
        NO_persist_sent=$(( sent + 1 ))
        NO_persist_last_epoch=$now
        dirty=1
      fi
    fi
  elif [ -n "$NO_persist_corr" ]; then
    NO_persist_corr=
    NO_persist_sent=0
    NO_persist_last_epoch=0
    dirty=1
  fi

  # 4. A restart phase that never finishes.
  case "$ST_phase" in
    quiescing|restarting|aftercare)
      started=$(fm_ccw_uint_or "${ST_phase_epoch:-0}" 0)
      if [ "$started" -gt 0 ] && [ $(( now - started )) -ge "$STALL_ALARM" ] \
        && fm_ccw_report_due "$NO_stall_last_epoch" "$ALARM_REPEAT" "$now"; then
        minutes=$(( (now - started + 59) / 60 ))
        fm_ccw_emit_finding findings "restart phase $ST_phase unfinished for ${minutes}min (old_pid=${ST_old_pid:-none} new_pid=${ST_new_pid:-none}) - inspect bin/fm-captain-context-watch.sh status"
        NO_stall_last_epoch=$now
        dirty=1
      fi
      ;;
    *)
      if [ "$NO_stall_last_epoch" != 0 ]; then
        NO_stall_last_epoch=0
        dirty=1
      fi
      ;;
  esac

  [ "$dirty" -eq 0 ] || fm_ccw_note_save || true
  [ -z "$findings" ] || fm_ccw_journal alert "$findings"
  [ -z "$findings" ] || printf 'captain-context-watch: %s\n' "$findings"
  return 0
}

cmd_status() {
  local beat_epoch age last_line
  fm_ccw_state_load
  printf 'captain-context-watch status:\n'
  printf '  target:      %s\n' "$TARGET"
  printf '  threshold:   %s (%s tokens)\n' "$THRESHOLD" "$METRIC"
  printf '  phase:       %s (since epoch %s)\n' "$ST_phase" "${ST_phase_epoch:-0}"
  if [ -n "$ST_last_footer" ]; then
    printf '  last sample: context=%s percent=%s window=%s output=%s input=%s at epoch %s\n' \
      "${ST_last_context:-?}" "${ST_last_percent:-?}" "${ST_last_window:-?}" \
      "${ST_last_output:-?}" "${ST_last_input:-?}" "${ST_last_measured_epoch:-0}"
    printf '               footer: %s\n' "$ST_last_footer"
  else
    printf '  last sample: none readable (unreadable streak %s)\n' "${ST_unreadable_streak:-0}"
  fi
  if [ -n "$ST_corr" ]; then
    printf '  request:     corr=%s crossed_epoch=%s old_pid=%s\n' "$ST_corr" "$ST_crossed_epoch" "${ST_old_pid:-none}"
    [ -z "$ST_crossed_footer" ] || printf '               crossed footer: %s\n' "$ST_crossed_footer"
  fi
  case "${ST_answer_epoch:-0}" in
    ''|0) ;;
    *) printf '  answer:      epoch=%s note=%s\n' "$ST_answer_epoch" "${ST_answer_note:-}" ;;
  esac
  [ -z "$ST_err_note" ] || printf '  last error:  %s\n' "$ST_err_note"
  if [ "$ST_phase" = restarting ] || [ "$ST_phase" = aftercare ]; then
    printf '  restart:     old_pid=%s new_pid=%s epoch=%s\n' "${ST_old_pid:-none}" "${ST_new_pid:-none}" "${ST_restart_epoch:-0}"
  fi
  beat_epoch=$(fm_ccw_mtime "$BEAT_FILE")
  case "$beat_epoch" in
    ''|*[!0-9]*) printf '  beat:        %s - absent\n' "$BEAT_FILE" ;;
    *) age=$(( $(fm_ccw_now) - beat_epoch )); printf '  beat:        %s - %ss old\n' "$BEAT_FILE" "$age" ;;
  esac
  beat_epoch=$(fm_ccw_mtime "$WATCHER_BEAT_FILE")
  case "$beat_epoch" in
    ''|*[!0-9]*) printf '  watcher:     %s - absent\n' "$WATCHER_BEAT_FILE" ;;
    *) age=$(( $(fm_ccw_now) - beat_epoch )); printf '  watcher:     %s - %ss old\n' "$WATCHER_BEAT_FILE" "$age" ;;
  esac
  if [ -f "$LOG_FILE" ]; then
    last_line=$(tail -n 1 "$LOG_FILE" 2>/dev/null || true)
    printf '  journal:     %s\n' "$LOG_FILE"
    printf '  last:        %s\n' "$last_line"
  else
    printf '  journal:     %s - absent\n' "$LOG_FILE"
  fi
  return 0
}

case "${1:-}" in
  run) shift; [ "$#" -eq 0 ] || die_usage 'run takes no arguments'; cmd_run ;;
  step) shift; [ "$#" -eq 0 ] || die_usage 'step takes no arguments'; cmd_step ;;
  measure) shift; [ "$#" -eq 0 ] || die_usage 'measure takes no arguments'; cmd_measure ;;
  answer) shift; cmd_answer "$@" ;;
  check) shift; [ "$#" -eq 0 ] || die_usage 'check takes no arguments'; cmd_check ;;
  status) shift; [ "$#" -eq 0 ] || die_usage 'status takes no arguments'; cmd_status ;;
  -h|--help|'') usage ;;
  *) die_usage "unknown action: $1" ;;
esac
