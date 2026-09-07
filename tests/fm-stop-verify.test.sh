#!/usr/bin/env bash
# tests/fm-stop-verify.test.sh - the captain's capacity-brake stop-verification
# (bin/fm-stop-verify.sh): request a stop, VERIFY it, escalate honestly.
#
# The captain's finding (2026-09-07): the stop call (fm-control exit) is a
# polite request a worker stuck in a long shell command only sees after that
# command ends, and a brake that logged "stopped" after merely REQUESTING a
# stop read better than reality, repeating the same polite request to the same
# victim three times with nothing changed. These tests pin the helper's three
# contracts hermetically through its executable interface:
#
#   1. Honest request vs confirmation: the event log and the printed outcome
#      never read "stopped" (confirmed) for a request; every transition
#      (requested/confirmed/escalated/unconfirmed/cooldown/skipped/
#      unverifiable/failed) is a distinct line.
#   2. Verify, then get harder: after the polite exit the helper verifies the
#      recovery-grade agent state; a still-alive agent gets a hard interrupt,
#      never a repeated polite request; a still-alive agent after that is
#      reported escalated with a durable unconfirmed record.
#   3. Never the same victim on repeat: a fresh unconfirmed victim is in
#      cooldown (reported, nothing repeated), a call with several candidates
#      addresses the first not-in-cooldown one and reports the rest, and a
#      cooldown-expired re-addressing goes straight to the interrupt instead
#      of repeating the polite exit.
#
# The endpoint-liveness signal is driven through the FM_STOP_VERIFY_STATE_BIN
# seam (sequence/static verdicts, plus an optional "the interrupt killed the
# worker" marker), and the control plane through FM_STOP_VERIFY_CONTROL, so
# the whole decision is pinned deterministically without a real agent.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-stop-verify)
STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"
export FM_HOME="$TMP"
export FM_STATE_OVERRIDE="$STATE_DIR"
export FM_ROOT_OVERRIDE="$ROOT"

HELPER="$ROOT/bin/fm-stop-verify.sh"
LOG="$TMP/events.log"
CTL_LOG="$TMP/control.log"

# --- fake control plane -----------------------------------------------------
# Logs every request to control.log; on interrupt touches interrupted/<task>
# (the state bin honors that only when use-interrupt-death/<task> exists).
# Each <task>.<verb> outcome file is `ok` (default) or `unconfirmed`.
cat > "$TMP/fake-control.sh" <<SH
#!/usr/bin/env bash
task=\$1; verb=\$2
printf '%s %s\n' "\$verb" "\$task" >> "$CTL_LOG"
if [ "\$verb" = interrupt ]; then
  touch "$TMP/interrupted/\$task"
fi
out=\$(cat "$TMP/ctl/\$task.\$verb" 2>/dev/null || printf ok)
if [ "\$out" = unconfirmed ]; then
  printf 'error: %s-delivered %s ... exit=unconfirmed\n' "\$verb" "\$task" >&2
  exit 1
fi
if [ "\$verb" = exit ]; then
  printf 'stopped %s harness=test backend=tmux endpoint=ses:fm-%s worktree=%s/wt\n' "\$task" "\$task" "$TMP"
else
  printf 'interrupt-delivered %s harness=test backend=tmux verified=agent-alive\n' "\$task"
fi
exit 0
SH
chmod +x "$TMP/fake-control.sh"
mkdir -p "$TMP/interrupted" "$TMP/ctl"

# --- fake state bin ---------------------------------------------------------
# Verdict for <task>: dead when use-interrupt-death/<task> exists and the
# interrupt has been delivered; else the next line of seq/<task> (its last
# line repeats forever); else static/<task>; else unknown.
cat > "$TMP/fake-state.sh" <<SH
#!/usr/bin/env bash
task=\$1
if [ -f "$TMP/use-interrupt-death/\$task" ] && [ -f "$TMP/interrupted/\$task" ]; then
  printf 'dead\n'; exit 0
fi
if [ -f "$TMP/seq/\$task" ]; then
  f="$TMP/seq/\$task"
  first=\$(head -1 "\$f")
  rest=\$(tail -n +2 "\$f")
  if [ -n "\$rest" ]; then
    printf '%s\n' "\$rest" > "\$f"
  else
    printf '%s\n' "\$first" > "\$f"
  fi
  printf '%s\n' "\$first"
  exit 0
fi
cat "$TMP/static/\$task" 2>/dev/null || printf 'unknown\n'
SH
chmod +x "$TMP/fake-state.sh"
mkdir -p "$TMP/seq" "$TMP/static" "$TMP/use-interrupt-death"

mk_meta() {  # <task> [kind] [extra kv...]
  local task=$1 kind=${2:-ship}
  shift 2
  fm_write_meta "$STATE_DIR/$task.meta" \
    "window=ses:fm-$task" "backend=tmux" \
    "endpoint_task_id=$task" "worktree=$TMP/wt-$task" \
    "project=proj" "harness=dev-server" "kind=$kind" \
    "mode=no-mistakes" "yolo=off" "$@"
}

mk_status() {  # <task> <line>
  printf '%s\n' "$2" > "$STATE_DIR/$1.status"
}

alive() { printf 'alive\n' > "$TMP/static/$1"; }
dead() { printf 'dead\n' > "$TMP/static/$1"; }
unknown() { printf 'unknown\n' > "$TMP/static/$1"; }
seq_verdicts() {  # <task> <verdict...> - last verdict repeats forever
  local task=$1
  shift
  : > "$TMP/seq/$task"
  for v in "$@"; do printf '%s\n' "$v" >> "$TMP/seq/$task"; done
}
ctl_ok() { printf 'ok\n' > "$TMP/ctl/$1.$2"; }
ctl_unconfirmed() { printf 'unconfirmed\n' > "$TMP/ctl/$1.$2"; }
interrupt_kills() { touch "$TMP/use-interrupt-death/$1"; }

reset_state() {
  rm -f "$STATE_DIR"/*.meta "$STATE_DIR"/*.status \
    "$STATE_DIR"/.stop-verify-* "$CTL_LOG" 2>/dev/null || true
  rm -rf "$TMP/seq"/* "$TMP/static"/* "$TMP/ctl"/* \
    "$TMP/interrupted"/* "$TMP/use-interrupt-death"/* 2>/dev/null || true
  mkdir -p "$TMP/seq" "$TMP/static" "$TMP/ctl" "$TMP/interrupted" "$TMP/use-interrupt-death"
  : > "$LOG"
}

run() {  # <args...>; sets RC, OUT
  OUT=$(FM_STOP_VERIFY_CONTROL="$TMP/fake-control.sh" \
        FM_STOP_VERIFY_STATE_BIN="$TMP/fake-state.sh" \
        FM_STOP_VERIFY_LOG="$LOG" \
        "$HELPER" "$@" 2>"$TMP/err.log")
  RC=$?
}

ctl_calls() {  # -> lines of control.log
  [ -f "$CTL_LOG" ] && cat "$CTL_LOG" || true
}

log_verbs() {  # -> verbs of the event log (task/window stripped)
  awk '{print $2}' "$LOG"
}

log_has_verb() {  # <verb> -> 0 iff an event line has exactly this verb
  awk -v v="$1" '$2==v {found=1} END{exit !found}' "$LOG"
}

# --- 1. confirmed through the control plane (requested, then confirmed) -----

reset_state
mk_meta sv-conf "ship"
mk_status sv-conf "working: mid-build"
alive sv-conf
ctl_ok sv-conf exit
run sv-conf
[ "$RC" -eq 0 ] || fail "a control-plane-confirmed stop must exit 0, got $RC ($OUT)"
assert_contains "$OUT" "confirmed" "the outcome must be confirmed"
assert_contains "$OUT" "sv-conf" "the outcome must name the task"
assert_contains "$(ctl_calls)" "exit sv-conf" "the polite exit must have been requested once"
assert_not_contains "$(ctl_calls)" "interrupt" "no interrupt is needed when the exit confirms"
assert_contains "$(log_verbs)" "requested" "the event log must record the request"
log_has_verb confirmed || fail "the event log must record the confirmation"
log_has_verb unconfirmed && fail "no unconfirmed line for a confirmed stop"
assert_absent "$STATE_DIR/.stop-verify-sv-conf" "a confirmed stop leaves no unconfirmed record"
pass "stop-verify: a control-plane-confirmed stop reports confirmed and logs requested then confirmed"

# --- 2. already-stopped (idempotent, no request) ----------------------------

reset_state
mk_meta sv-as "ship"
mk_status sv-as "working: mid-build"
dead sv-as
run sv-as
[ "$RC" -eq 0 ] || fail "an already-stopped worker must exit 0, got $RC ($OUT)"
assert_contains "$OUT" "already-stopped" "the outcome must say already-stopped"
[ -z "$(ctl_calls)" ] || fail "an already-stopped worker must not be requested: $(ctl_calls)"
log_has_verb confirmed || fail "already-stopped must log a confirmation"
log_has_verb requested && fail "already-stopped must not log a request"
pass "stop-verify: an already-stopped worker confirms without any request"

# --- 3. polite exit unconfirmed, then the worker exits during the verify ----
# --- window (late confirmation, no interrupt) -------------------------------

reset_state
mk_meta sv-late "ship"
mk_status sv-late "working: mid-build"
seq_verdicts sv-late alive alive alive dead
ctl_unconfirmed sv-late exit
run --verify-wait 5 --poll 0.1 sv-late
[ "$RC" -eq 0 ] || fail "a late-confirmed stop must exit 0, got $RC ($OUT)"
assert_contains "$OUT" "confirmed" "the outcome must be confirmed"
assert_contains "$OUT" "verified after polite exit" "the late confirmation must be named"
assert_contains "$(ctl_calls)" "exit sv-late" "the polite exit must have been requested once"
assert_not_contains "$(ctl_calls)" "interrupt" "no interrupt when the worker exits during the verify window"
log_has_verb confirmed || fail "the late confirmation must be logged"
pass "stop-verify: a worker that exits during the verify window is confirmed without an interrupt"

# --- 4. polite exit unconfirmed, still alive: get harder with an interrupt --
# --- which kills the worker (confirmed after hard interrupt) ----------------

reset_state
mk_meta sv-hard "ship"
mk_status sv-hard "working: mid-build"
alive sv-hard
ctl_unconfirmed sv-hard exit
ctl_ok sv-hard interrupt
interrupt_kills sv-hard
run --verify-wait 1 --hard-wait 2 --poll 0.1 sv-hard
[ "$RC" -eq 0 ] || fail "a stop confirmed after the hard interrupt must exit 0, got $RC ($OUT)"
assert_contains "$OUT" "confirmed" "the outcome must be confirmed"
assert_contains "$OUT" "verified after hard interrupt" "the interrupt path must be named"
assert_contains "$(ctl_calls)" "exit sv-hard" "the polite exit must have been requested once"
assert_contains "$(ctl_calls)" "interrupt sv-hard" "the hard interrupt must have been delivered"
log_has_verb escalated || fail "the harder step must be logged"
log_has_verb confirmed || fail "the confirmation must be logged"
assert_absent "$STATE_DIR/.stop-verify-sv-hard" "a confirmed stop leaves no unconfirmed record"
pass "stop-verify: a still-alive worker gets a hard interrupt, which confirms the stop"

# --- 5. escalate, still alive: unconfirmed, durable record, exit 1 ----------

reset_state
mk_meta sv-stuck "ship"
mk_status sv-stuck "working: mid-build"
alive sv-stuck
ctl_unconfirmed sv-stuck exit
ctl_ok sv-stuck interrupt
run --verify-wait 1 --hard-wait 1 --poll 0.1 sv-stuck
[ "$RC" -eq 1 ] || fail "an unconfirmed stop must exit 1, got $RC ($OUT)"
assert_contains "$OUT" "escalated" "the outcome must be escalated"
assert_contains "$OUT" "still alive" "the escalation must say the agent is still alive"
assert_contains "$(ctl_calls)" "exit sv-stuck" "the polite exit must have been requested once"
assert_contains "$(ctl_calls)" "interrupt sv-stuck" "the hard interrupt must have been delivered"
log_has_verb requested || fail "the request must be logged"
log_has_verb escalated || fail "the escalation must be logged"
log_has_verb unconfirmed || fail "the unconfirmed outcome must be logged"
log_has_verb confirmed && fail "history must never read confirmed for this stop"
assert_present "$STATE_DIR/.stop-verify-sv-stuck" "an unconfirmed stop must leave a durable record"
grep -q '^outcome=unconfirmed$' "$STATE_DIR/.stop-verify-sv-stuck" \
  || fail "the record must say unconfirmed: $(cat "$STATE_DIR/.stop-verify-sv-stuck")"
pass "stop-verify: a still-alive worker after the interrupt reports escalated with an unconfirmed record"

# --- 6. victim cooldown: the same victim is reported, never repeated --------

reset_state
mk_meta sv-cd "ship"
mk_status sv-cd "working: mid-build"
alive sv-cd
ctl_unconfirmed sv-cd exit
ctl_ok sv-cd interrupt
run --verify-wait 1 --hard-wait 1 --poll 0.1 sv-cd
[ "$RC" -eq 1 ] || fail "the first addressing must escalate, got $RC ($OUT)"
calls_after_first=$(ctl_calls)
requests_before=$(awk '$2=="requested"{n++} END{print n+0}' "$LOG")
run --cooldown 300 sv-cd
[ "$RC" -eq 2 ] || fail "a cooldown decline must exit 2, got $RC ($OUT)"
assert_contains "$OUT" "cooldown" "the outcome must say cooldown"
assert_contains "$OUT" "already addressed" "the cooldown reason must say the victim was addressed"
[ "$(ctl_calls)" = "$calls_after_first" ] || fail "cooldown must not repeat any request: $(ctl_calls)"
requests_after=$(awk '$2=="requested"{n++} END{print n+0}' "$LOG")
[ "$requests_after" = "$requests_before" ] || fail "a cooldown decline must not log a new request"
log_has_verb cooldown || fail "the cooldown decline must be logged"
pass "stop-verify: a fresh unconfirmed victim is in cooldown and nothing is repeated"

# --- 7. cooldown expired: straight to the harder interrupt, no polite repeat

reset_state
mk_meta sv-exp "ship"
mk_status sv-exp "working: mid-build"
alive sv-exp
ctl_unconfirmed sv-exp exit
ctl_ok sv-exp interrupt
run --verify-wait 1 --hard-wait 1 --poll 0.1 sv-exp
[ "$RC" -eq 1 ] || fail "the first addressing must escalate, got $RC ($OUT)"
# The cooldown has expired; the re-addressing must go straight to the harder
# interrupt (no polite exit), and this time the worker dies during the
# post-interrupt verify window.
seq_verdicts sv-exp alive alive alive dead
run --cooldown 0 --verify-wait 1 --hard-wait 1 --poll 0.1 sv-exp
[ "$RC" -eq 0 ] || fail "the cooldown-expired re-addressing must confirm, got $RC ($OUT)"
[ "$(grep -c '^exit ' "$CTL_LOG" 2>/dev/null || true)" -eq 1 ] \
  || fail "the polite exit must never be repeated, got: $(ctl_calls)"
[ "$(grep -c '^interrupt ' "$CTL_LOG" 2>/dev/null || true)" -eq 2 ] \
  || fail "the re-addressing must go straight to the interrupt, got: $(ctl_calls)"
assert_contains "$OUT" "confirmed" "the re-addressing must confirm"
pass "stop-verify: a cooldown-expired victim is re-addressed via interrupt, never the polite exit again"

# --- 8. every candidate in cooldown: report all, address none ---------------

reset_state
for t in sv-all1 sv-all2; do
  mk_meta "$t" "ship"
  mk_status "$t" "working: mid-build"
  alive "$t"
  ctl_unconfirmed "$t" exit
  ctl_ok "$t" interrupt
  run --verify-wait 1 --hard-wait 1 --poll 0.1 "$t"
  [ "$RC" -eq 1 ] || fail "the first addressing of $t must escalate, got $RC ($OUT)"
done
run --cooldown 300 sv-all1 sv-all2
[ "$RC" -eq 2 ] || fail "all-in-cooldown must exit 2, got $RC ($OUT)"
assert_contains "$OUT" "sv-all1" "the report must name the first candidate"
assert_contains "$OUT" "sv-all2" "the report must name the second candidate"
assert_contains "$OUT" "cooldown" "the report must say cooldown"
assert_contains "$OUT" "no candidate addressed" "the report must say nothing was addressed"
pass "stop-verify: when every candidate is in cooldown, all are reported and none addressed"

# --- 9. first candidate in cooldown, second eligible: address the second ---

reset_state
mk_meta sv-cd1 "ship"
mk_status sv-cd1 "working: mid-build"
alive sv-cd1
ctl_unconfirmed sv-cd1 exit
ctl_ok sv-cd1 interrupt
run --verify-wait 1 --hard-wait 1 --poll 0.1 sv-cd1
[ "$RC" -eq 1 ] || fail "the cooldown victim must escalate first, got $RC ($OUT)"
mk_meta sv-cd2 "ship"
mk_status sv-cd2 "working: mid-build"
alive sv-cd2
ctl_ok sv-cd2 exit
run --cooldown 300 sv-cd1 sv-cd2
[ "$RC" -eq 0 ] || fail "the eligible second candidate must be addressed, got $RC ($OUT)"
assert_contains "$OUT" "sv-cd2" "the addressed task must be the second candidate"
assert_contains "$OUT" "confirmed" "the second candidate must confirm"
assert_contains "$(ctl_calls)" "exit sv-cd2" "the second candidate must have been requested"
pass "stop-verify: a cooldown victim is reported and the next eligible candidate is addressed"

# --- 10. non-candidates are skipped, never addressed ------------------------

reset_state
mk_meta sv-mate "secondmate"
mk_status sv-mate "paused: waiting for routed work"
run sv-mate
[ "$RC" -eq 2 ] || fail "a secondmate must be skipped with exit 2, got $RC ($OUT)"
assert_contains "$OUT" "skipped" "a secondmate must be skipped"
[ -z "$(ctl_calls)" ] || fail "a secondmate must never be addressed: $(ctl_calls)"
pass "stop-verify: a secondmate is never a stop candidate"

reset_state
mk_meta sv-done "ship"
mk_status sv-done "done: PR https://github.com/example/repo/pull/1"
run sv-done
[ "$RC" -eq 2 ] || fail "a done task must be skipped, got $RC ($OUT)"
assert_contains "$OUT" "skipped" "a done task must be skipped"
pass "stop-verify: a done task is never a stop candidate"

reset_state
mk_meta sv-failed "ship"
mk_status sv-failed "failed: validation went red"
run sv-failed
[ "$RC" -eq 2 ] || fail "a failed task must be skipped, got $RC ($OUT)"
assert_contains "$OUT" "skipped" "a failed task must be skipped"
pass "stop-verify: a failed task is never a stop candidate"

reset_state
mk_meta sv-held "ship"
mk_status sv-held "captain-held [key=route]: tracked by task-decision-route"
run sv-held
[ "$RC" -eq 2 ] || fail "a captain-held task must be skipped, got $RC ($OUT)"
assert_contains "$OUT" "skipped" "a captain-held task must be skipped"
pass "stop-verify: a captain-held task is never a stop candidate"

reset_state
run sv-nometa
[ "$RC" -eq 2 ] || fail "a task without a record must be skipped, got $RC ($OUT)"
assert_contains "$OUT" "skipped" "a task without a record must be skipped"
pass "stop-verify: a task without a record is never addressed"

reset_state
mk_meta sv-remote "ship" "remote_host=otherhost"
mk_status sv-remote "working: mid-build"
run sv-remote
[ "$RC" -eq 2 ] || fail "a remote placement must be skipped, got $RC ($OUT)"
assert_contains "$OUT" "skipped" "a remote placement must be skipped"
pass "stop-verify: a remote placement is never addressed from this home"

# A mate before a live worker in the list: the mate is skipped, the worker
# is still addressed.
reset_state
mk_meta sv-mate2 "secondmate"
mk_status sv-mate2 "paused: waiting for routed work"
mk_meta sv-worker "ship"
mk_status sv-worker "working: mid-build"
alive sv-worker
ctl_ok sv-worker exit
run sv-mate2 sv-worker
[ "$RC" -eq 0 ] || fail "the live worker after a skipped mate must be addressed, got $RC ($OUT)"
assert_contains "$OUT" "sv-worker" "the worker must be the addressed task"
pass "stop-verify: a skipped mate does not block the next eligible worker"

# --- 11. unverifiable endpoint: fail-closed, nothing addressed --------------

reset_state
mk_meta sv-unk "ship"
mk_status sv-unk "working: mid-build"
unknown sv-unk
run sv-unk
[ "$RC" -eq 2 ] || fail "an unverifiable endpoint must exit 2, got $RC ($OUT)"
assert_contains "$OUT" "unverifiable" "the outcome must say unverifiable"
[ -z "$(ctl_calls)" ] || fail "an unverifiable endpoint must never be addressed: $(ctl_calls)"
pass "stop-verify: an unclassifiable endpoint is never addressed (fail-closed)"

# --- 12. endpoint becomes unclassifiable after the polite exit: no interrupt

reset_state
mk_meta sv-unk2 "ship"
mk_status sv-unk2 "working: mid-build"
seq_verdicts sv-unk2 alive alive unknown
ctl_unconfirmed sv-unk2 exit
run --verify-wait 5 --poll 0.1 sv-unk2
[ "$RC" -eq 2 ] || fail "an unclassifiable-after-exit endpoint must exit 2, got $RC ($OUT)"
assert_contains "$OUT" "unverifiable" "the outcome must say unverifiable"
assert_contains "$(ctl_calls)" "exit sv-unk2" "the polite exit was requested once"
assert_not_contains "$(ctl_calls)" "interrupt" "an unclassifiable endpoint must never be interrupted"
pass "stop-verify: an endpoint that becomes unclassifiable is never interrupted (fail-closed)"

# --- 13. concurrent verification of the same task is refused ----------------

reset_state
mk_meta sv-lock "ship"
mk_status sv-lock "working: mid-build"
alive sv-lock
# A real holder occupies the per-task lock; the helper must refuse instead of
# stealing, addressing, or repeating.
(
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$STATE_DIR/.stop-verify-sv-lock.lock" \
    && printf 'HOLDER-ACQUIRED\n' > "$TMP/holder.out"
  sleep 10
) &
# shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
HOLDER=$!
sleep 0.7
run sv-lock
[ "$RC" -eq 2 ] || fail "a locked task must exit 2, got $RC ($OUT)"
assert_contains "$OUT" "failed" "the outcome must say failed"
assert_contains "$OUT" "already running" "the reason must name the concurrent verification"
[ -z "$(ctl_calls)" ] || fail "a locked task must not be addressed: $(ctl_calls)"
log_has_verb failed || fail "the refusal must be logged honestly"
wait "$HOLDER" 2>/dev/null || true
pass "stop-verify: a concurrent verification of the same task is refused"

# --- 14. --list reports eligibility without addressing ----------------------

reset_state
mk_meta sv-li1 "ship"
mk_status sv-li1 "working: mid-build"
alive sv-li1
mk_meta sv-li2 "ship"
mk_status sv-li2 "done: PR https://github.com/example/repo/pull/2"
mk_meta sv-li3 "ship"
mk_status sv-li3 "working: mid-build"
unknown sv-li3
run --list sv-li1 sv-li2 sv-li3
[ "$RC" -eq 0 ] || fail "--list must exit 0, got $RC ($OUT)"
assert_contains "$OUT" "sv-li1 eligible" "--list must mark the live worker eligible"
assert_contains "$OUT" "sv-li2 skipped" "--list must mark the done task skipped"
assert_contains "$OUT" "sv-li3 unverifiable" "--list must mark the unclassifiable task unverifiable"
[ -z "$(ctl_calls)" ] || fail "--list must not address anything: $(ctl_calls)"
pass "stop-verify: --list reports eligibility without addressing anything"

# --- 15. endpoint becomes unclassifiable after the hard interrupt: reported -
# --- escalated, never confirmed --------------------------------------------

reset_state
mk_meta sv-unk3 "ship"
mk_status sv-unk3 "working: mid-build"
seq_verdicts sv-unk3 alive alive alive alive alive alive alive alive alive \
  alive alive alive alive alive alive alive unknown
ctl_unconfirmed sv-unk3 exit
ctl_ok sv-unk3 interrupt
run --verify-wait 1 --hard-wait 1 --poll 0.1 sv-unk3
[ "$RC" -eq 1 ] || fail "an unclassifiable-after-interrupt stop must exit 1, got $RC ($OUT)"
assert_contains "$OUT" "escalated" "the outcome must be escalated"
assert_contains "$OUT" "unclassifiable" "the escalation must name the unclassifiable endpoint"
assert_contains "$(ctl_calls)" "interrupt sv-unk3" "the interrupt was delivered before the endpoint became unreadable"
log_has_verb confirmed && fail "history must never read confirmed for this stop"
assert_present "$STATE_DIR/.stop-verify-sv-unk3" "an unconfirmed stop must leave a durable record"
pass "stop-verify: an endpoint that becomes unclassifiable after the interrupt is reported escalated, never confirmed"

echo "# fm-stop-verify.test.sh: all assertions passed"
