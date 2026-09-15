#!/usr/bin/env bash
# tests/fm-self-update-timer.test.sh - the periodic self-update run wrapper
# (bin/fm-self-update-timer.sh).
#
# The captain's requirement (2026-09-15): check for a new state at least every
# six hours and build it, after three hand-run updates in one day. The run
# wrapper composes the existing fast-forward-only pass with the policy an
# unattended cadence needs, and these tests pin that policy through its
# executable interface with deterministic fakes for the two passes it calls:
#
#   1. A run with nothing to report writes exactly ONE quiet log line and
#      restarts nobody, even though the pass's own summary names every live
#      mate for restart.
#   2. A run that advanced homes restarts only the mates that actually advanced
#      (local and remote), records their old..new lines, and records the pass's
#      reread-firstmate line for the primary session.
#   3. A held build token skips the run (one "skipped: build token held" line,
#      no update), while a stale token - dead owner or ownerless past the
#      20-minute age-rig - does not block it.
#   4. A restart the pass reported as nudged or unreached is retried on the next
#      run even without new progress, and a confirmed restart clears it.
#   5. The pass's skip reasons are logged verbatim, and a hard failure of either
#      pass is reported as failed with a nonzero exit.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUN="$ROOT/bin/fm-self-update-timer.sh"
TMP_ROOT=$(fm_test_tmproot fm-self-update-timer)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# The two composed passes are fakes: each prints a scripted output file, exits a
# scripted code, and records the argv it was handed.
make_fakes() {
  local home=$1
  cat > "$home/fm-update.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_UPDATE_ARGV:?}"
cat "${FM_FAKE_UPDATE_OUT:?}"
exit "${FM_FAKE_UPDATE_RC:-0}"
SH
  cat > "$home/fm-secondmate-restart.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_RESTART_ARGV:?}"
cat "${FM_FAKE_RESTART_OUT:?}"
exit "${FM_FAKE_RESTART_RC:-0}"
SH
  chmod +x "$home/fm-update.sh" "$home/fm-secondmate-restart.sh"
}

write_out() {  # <home> <name> <line>...
  local home=$1 name=$2
  shift 2
  printf '%s\n' "$@" > "$home/$name"
}

# Run one timer pass. The wrapper's stdout lands in <home>/run.out and its
# stderr (the unit journal surface) in <home>/run.err; this function returns the
# wrapper's exit code and FM_FAKE_* must prefix the call.
run_timer() {
  local home=$1
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_SELF_UPDATE_UPDATE_BIN="$home/fm-update.sh" \
    FM_SELF_UPDATE_RESTART_BIN="$home/fm-secondmate-restart.sh" \
    FM_SELF_UPDATE_LOG="$home/state/self-update-timer.log" \
    FM_SELF_UPDATE_PENDING="$home/state/.self-update-pending-restarts" \
    FM_FAKE_UPDATE_ARGV="$home/update.argv" \
    FM_FAKE_RESTART_ARGV="$home/restart.argv" \
    "$RUN" run >"$home/run.out" 2>"$home/run.err"
}

# --- 1. a no-progress run is quiet and restarts nobody -----------------------

test_no_progress_is_one_quiet_line_and_no_restarts() {
  local home out rc log
  home=$(make_home quiet)
  make_fakes "$home"
  write_out "$home" update.out \
    'firstmate: already current' \
    'secondmate nuc: already current' \
    'reread-firstmate: no' \
    'restart-secondmates: fm-nuc' \
    'nudge-secondmates: none'
  FM_FAKE_UPDATE_OUT="$home/update.out" FM_FAKE_RESTART_OUT=/dev/null \
    run_timer "$home"; rc=$?
  out=$(cat "$home/run.out")
  expect_code 0 "$rc" "run exit"
  log="$home/state/self-update-timer.log"
  assert_present "$log" "the run did not write its log"
  [ "$(wc -l < "$log")" -eq 1 ] \
    || fail "a no-progress run must write exactly one line (got $(wc -l < "$log"))"
  assert_grep 'already current' "$log" "the quiet line must say already current"
  assert_absent "$home/restart.argv" "a no-progress run must not call the restart pass"
  assert_not_contains "$out" 'restart-secondmates' \
    "the pass's unconditional restart summary must not leak into the record"
  pass "a no-progress run writes one quiet line and restarts nobody"
}

# --- 2. progress restarts only the advanced mates ----------------------------

test_progress_restarts_only_advanced_mates() {
  local home out rc log argv
  home=$(make_home progress)
  make_fakes "$home"
  write_out "$home" update.out \
    'firstmate: updated 1111111..2222222 (instructions changed: AGENTS.md, bin)' \
    'secondmate nuc: updated 1111111..2222222' \
    'secondmate other: already current' \
    'remote secondmate rem: updated on remote-host (2222222222222222222222222222222222222222)' \
    'reread-firstmate: yes' \
    'restart-secondmates: fm-nuc fm-other fm-rem' \
    'nudge-secondmates: none'
  write_out "$home" restart.out \
    'restarted: nuc (claude)' \
    'restarted: rem on remote-host (claude)' \
    'summary: 2 of 2 restarted, 0 nudged, 0 unreached'
  FM_FAKE_UPDATE_OUT="$home/update.out" FM_FAKE_RESTART_OUT="$home/restart.out" \
    run_timer "$home"; rc=$?
  out=$(cat "$home/run.out")
  expect_code 0 "$rc" "run exit"
  log="$home/state/self-update-timer.log"
  assert_present "$log" "the run did not write its log"
  argv=$(cat "$home/restart.argv")
  assert_contains "$argv" 'nuc rem' "the restart pass must be handed exactly the advanced mates"
  assert_not_contains "$argv" 'other' "an already-current mate must not be restarted"
  assert_contains "$out" 'updated 1111111..2222222' "the old..new line must be recorded"
  assert_contains "$out" 'reread-firstmate: yes' "the reread-firstmate line must be recorded"
  assert_contains "$out" 'restarted: nuc' "the confirmed restart must be recorded"
  assert_contains "$out" 'restarted: rem on remote-host' "the confirmed remote restart must be recorded"
  assert_not_contains "$out" 'other' "an already-current mate must not appear in the record"
  pass "a progress run restarts only the mates that advanced and records the pass lines"
}

# --- 3. the build-token gate -------------------------------------------------

test_live_build_token_skips_the_whole_run() {
  local home out rc log pid
  home=$(make_home token-held)
  make_fakes "$home"
  write_out "$home" update.out 'firstmate: updated 1111111..2222222'
  write_out "$home" restart.out 'restarted: nuc (claude)'
  sleep 1000 &
  pid=$!
  printf 'nuc %s\n' "$pid" > "$home/state/.build-token"
  FM_FAKE_UPDATE_OUT="$home/update.out" FM_FAKE_RESTART_OUT="$home/restart.out" \
    run_timer "$home"; rc=$?
  out=$(cat "$home/run.out")
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$rc" "run exit"
  log="$home/state/self-update-timer.log"
  [ "$(wc -l < "$log")" -eq 1 ] || fail "a held-token run must write exactly one line"
  assert_grep 'skipped: build token held' "$log" "the held-token skip must be recorded"
  assert_absent "$home/update.argv" "the update pass must not run while the build token is held"
  assert_absent "$home/restart.argv" "no restart may be attempted while the build token is held"
  pass "a live build token skips the whole run with one skip line"
}

test_ownerless_token_holds_only_inside_the_age_rig() {
  local home out rc
  home=$(make_home token-ownerless)
  make_fakes "$home"
  write_out "$home" update.out \
    'firstmate: already current' \
    'reread-firstmate: no' \
    'restart-secondmates: none' \
    'nudge-secondmates: none'
  : > "$home/state/.build-token"
  FM_FAKE_UPDATE_OUT="$home/update.out" FM_FAKE_RESTART_OUT=/dev/null \
    run_timer "$home"; rc=$?
  out=$(cat "$home/run.out")
  expect_code 0 "$rc" "young ownerless run exit"
  assert_grep 'skipped: build token held' "$home/state/self-update-timer.log" \
    "a young ownerless token must hold the run"
  assert_absent "$home/update.argv" "the update pass must not run under a young ownerless token"

  touch -d '25 minutes ago' "$home/state/.build-token"
  rm -f "$home/state/self-update-timer.log"
  FM_FAKE_UPDATE_OUT="$home/update.out" FM_FAKE_RESTART_OUT=/dev/null \
    run_timer "$home"; rc=$?
  expect_code 0 "$rc" "stale ownerless run exit"
  assert_present "$home/update.argv" "an ownerless token past the age-rig must not block the pass"
  pass "the ownerless age-rig holds only a young lock and lets a stale one through"
}

test_dead_token_owner_does_not_block_the_run() {
  local home pid
  home=$(make_home token-dead)
  make_fakes "$home"
  write_out "$home" update.out \
    'firstmate: already current' \
    'reread-firstmate: no' \
    'restart-secondmates: none' \
    'nudge-secondmates: none'
  sh -c 'exit 0' &
  pid=$!
  wait "$pid" 2>/dev/null || true
  printf 'nuc %s\n' "$pid" > "$home/state/.build-token"
  FM_FAKE_UPDATE_OUT="$home/update.out" FM_FAKE_RESTART_OUT=/dev/null \
    run_timer "$home" || true
  assert_present "$home/update.argv" "a dead token owner must not block the pass"
  pass "a dead build-token owner is stale and does not block the run"
}

# --- 4. unconfirmed restarts are retried and cleared -------------------------

test_unconfirmed_restart_is_retried_and_cleared() {
  local home out rc
  home=$(make_home retry)
  make_fakes "$home"
  write_out "$home" update.out \
    'firstmate: already current' \
    'secondmate nuc: updated 1111111..2222222' \
    'reread-firstmate: no' \
    'restart-secondmates: fm-nuc' \
    'nudge-secondmates: none'
  write_out "$home" restart.out \
    'nudged: nuc: it did not confirm within 900s that its open work is written down, so its conversation was not spent' \
    'summary: 0 of 1 restarted, 1 nudged, 0 unreached'
  FM_FAKE_UPDATE_OUT="$home/update.out" FM_FAKE_RESTART_OUT="$home/restart.out" \
    FM_FAKE_RESTART_RC=3 run_timer "$home"; rc=$?
  out=$(cat "$home/run.out")
  expect_code 0 "$rc" "nudged run exit"
  assert_grep 'nuc' "$home/state/.self-update-pending-restarts" "the nudged mate must be recorded as pending"
  assert_contains "$out" 'nudged: nuc' "the nudge must be recorded"
  assert_contains "$out" '[retry pending]' "the nudge must be marked for retry"

  rm -f "$home/update.argv" "$home/restart.argv"
  write_out "$home" update.out \
    'firstmate: already current' \
    'secondmate nuc: already current' \
    'reread-firstmate: no' \
    'restart-secondmates: fm-nuc' \
    'nudge-secondmates: none'
  write_out "$home" restart.out \
    'restarted: nuc (claude)' \
    'summary: 1 of 1 restarted, 0 nudged, 0 unreached'
  FM_FAKE_UPDATE_OUT="$home/update.out" FM_FAKE_RESTART_OUT="$home/restart.out" \
    run_timer "$home"; rc=$?
  out=$(cat "$home/run.out")
  expect_code 0 "$rc" "retry run exit"
  assert_contains "$(cat "$home/restart.argv")" 'nuc' \
    "a pending restart must be retried even without new progress"
  assert_absent "$home/state/.self-update-pending-restarts" "a confirmed restart must clear the pending entry"
  assert_contains "$out" 'restarted: nuc' "the confirmed retry must be recorded"
  assert_contains "$out" 'pending restart retry' "the retry-only run must say so"
  pass "an unconfirmed restart is retried without new progress and cleared when confirmed"
}

# --- 5. verbatim skips and hard failures -------------------------------------

test_skips_are_logged_verbatim() {
  local home out
  home=$(make_home skip)
  make_fakes "$home"
  write_out "$home" update.out \
    'firstmate: already current' \
    'secondmate nuc: skipped: dirty working tree' \
    'reread-firstmate: no' \
    'restart-secondmates: none' \
    'nudge-secondmates: none'
  FM_FAKE_UPDATE_OUT="$home/update.out" FM_FAKE_RESTART_OUT=/dev/null \
    run_timer "$home" || true
  out=$(cat "$home/run.out")
  assert_contains "$out" 'secondmate nuc: skipped: dirty working tree' \
    "a skip reason must be logged verbatim"
  assert_absent "$home/restart.argv" "a skipped mate must not be restarted"
  pass "the pass's skip reasons are logged verbatim"
}

test_update_failure_is_reported_and_fails_the_run() {
  local home out rc
  home=$(make_home update-failure)
  make_fakes "$home"
  write_out "$home" update.out 'fatal: could not read from remote repository'
  FM_FAKE_UPDATE_OUT="$home/update.out" FM_FAKE_RESTART_OUT=/dev/null FM_FAKE_UPDATE_RC=1 \
    run_timer "$home"; rc=$?
  out=$(cat "$home/run.out")
  expect_code 1 "$rc" "a failed update pass must fail the run"
  assert_contains "$out" 'failed' "the failure must be recorded"
  assert_contains "$out" 'fatal: could not read from remote repository' "the failure output must be recorded"
  pass "a failed update pass is logged and exits nonzero"
}

test_restart_hard_failure_keeps_the_mate_pending() {
  local home out rc
  home=$(make_home restart-failure)
  make_fakes "$home"
  write_out "$home" update.out \
    'firstmate: already current' \
    'secondmate nuc: updated 1111111..2222222' \
    'reread-firstmate: no' \
    'restart-secondmates: fm-nuc' \
    'nudge-secondmates: none'
  write_out "$home" restart.out 'error: FM_HOME is not set'
  FM_FAKE_UPDATE_OUT="$home/update.out" FM_FAKE_RESTART_OUT="$home/restart.out" \
    FM_FAKE_RESTART_RC=1 run_timer "$home"; rc=$?
  out=$(cat "$home/run.out")
  expect_code 1 "$rc" "a hard restart-pass failure must fail the run"
  assert_grep 'nuc' "$home/state/.self-update-pending-restarts" "the unconfirmed mate must stay pending"
  assert_contains "$out" 'failed' "the failure must be recorded"
  pass "a hard restart-pass failure is reported and keeps the mate pending"
}

test_restart_outcomes_match_ids_exactly() {
  local home out
  home=$(make_home id-prefix)
  make_fakes "$home"
  write_out "$home" update.out \
    'firstmate: already current' \
    'secondmate nuc: updated 1111111..2222222' \
    'reread-firstmate: no' \
    'restart-secondmates: fm-nuc' \
    'nudge-secondmates: none'
  # A longer id's outcome line must not confirm the shorter id.
  write_out "$home" restart.out 'restarted: nuc2 (claude)'
  FM_FAKE_UPDATE_OUT="$home/update.out" FM_FAKE_RESTART_OUT="$home/restart.out" \
    run_timer "$home" || true
  out=$(cat "$home/run.out")
  [ "$(cat "$home/state/.self-update-pending-restarts" 2>/dev/null)" = 'nuc' ] \
    || fail "a restart line for a longer id must not confirm the shorter one"
  assert_contains "$out" 'no outcome reported' "the missing outcome must be reported as unknown"
  pass "restart outcomes are matched against the exact mate id"
}

# --- 6. pass stderr: diagnostics are journalled, recognized skips still count -

test_stderr_diagnostics_do_not_mislabel_a_no_progress_run() {
  local home out err rc log
  home=$(make_home stderr-diagnostics)
  make_fakes "$home"
  # The real pass calls fm-guard.sh, whose WATCHER DOWN banner goes to stderr.
  # The banner must reach the unit journal but must not become log detail or
  # force the run's header to "skipped".
  cat > "$home/fm-update.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '●  WATCHER DOWN - SUPERVISION IS OFF' >&2
printf '%s\n' '●  This is a supervision warning only; the guarded operation WILL still run.' >&2
cat "${FM_FAKE_UPDATE_OUT:?}"
exit "${FM_FAKE_UPDATE_RC:-0}"
SH
  chmod +x "$home/fm-update.sh"
  write_out "$home" update.out \
    'firstmate: already current' \
    'secondmate nuc: already current' \
    'reread-firstmate: no' \
    'restart-secondmates: fm-nuc' \
    'nudge-secondmates: none'
  FM_FAKE_UPDATE_OUT="$home/update.out" FM_FAKE_RESTART_OUT=/dev/null \
    run_timer "$home"; rc=$?
  out=$(cat "$home/run.out")
  err=$(cat "$home/run.err")
  log="$home/state/self-update-timer.log"
  expect_code 0 "$rc" "run exit"
  [ "$(wc -l < "$log")" -eq 1 ] \
    || fail "stderr diagnostics must not add log lines (got $(wc -l < "$log"))"
  assert_grep 'already current' "$log" "the no-progress run must stay the quiet line"
  assert_not_contains "$(cat "$log")" 'WATCHER DOWN' \
    "the guard banner must not become an operator log record"
  assert_contains "$err" 'WATCHER DOWN' \
    "the guard banner must still reach the unit journal on stderr"
  assert_not_contains "$out" 'WATCHER DOWN' "the log surface must stay quiet"
  assert_absent "$home/restart.argv" "a no-progress run must not call the restart pass"
  pass "pass stderr diagnostics are journalled without mislabelling a no-progress run"
}

test_recognized_skip_on_stderr_still_drives_the_skipped_header() {
  local home out rc log
  home=$(make_home stderr-skip)
  make_fakes "$home"
  # fm-update.sh reports an unreachable remote route on stderr; that is a
  # recognized pass skip line, so it must still be recorded and set the header.
  cat > "$home/fm-update.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'remote secondmate rem: skipped on remote-host: unreachable' >&2
cat "${FM_FAKE_UPDATE_OUT:?}"
exit "${FM_FAKE_UPDATE_RC:-0}"
SH
  chmod +x "$home/fm-update.sh"
  write_out "$home" update.out \
    'firstmate: already current' \
    'reread-firstmate: no' \
    'restart-secondmates: none' \
    'nudge-secondmates: none'
  FM_FAKE_UPDATE_OUT="$home/update.out" FM_FAKE_RESTART_OUT=/dev/null \
    run_timer "$home"; rc=$?
  out=$(cat "$home/run.out")
  log="$home/state/self-update-timer.log"
  expect_code 0 "$rc" "run exit"
  assert_grep 'skipped' "$log" "a recognized stderr skip must still set the skipped header"
  assert_contains "$out" 'remote secondmate rem: skipped on remote-host: unreachable' \
    "a recognized stderr skip reason must be recorded verbatim"
  pass "a recognized skip line on stderr still drives the skipped header"
}

test_unrecognized_pass_output_is_recorded_without_a_skip_header() {
  local home out rc log
  home=$(make_home unknown-output)
  make_fakes "$home"
  write_out "$home" update.out \
    'unexpected pass notice on stdout' \
    'firstmate: already current' \
    'reread-firstmate: no' \
    'restart-secondmates: none' \
    'nudge-secondmates: none'
  FM_FAKE_UPDATE_OUT="$home/update.out" FM_FAKE_RESTART_OUT=/dev/null \
    run_timer "$home"; rc=$?
  out=$(cat "$home/run.out")
  log="$home/state/self-update-timer.log"
  expect_code 0 "$rc" "run exit"
  assert_contains "$out" 'unexpected pass notice on stdout' \
    "unrecognized stdout output must not be silently dropped"
  assert_grep 'already current' "$log" "an unrecognized stdout line must not set a skip header"
  assert_no_grep 'skipped' "$log" "an unrecognized stdout line must not set the skipped header"
  pass "unrecognized pass stdout output is recorded without a skip header"
}

test_usage_and_unknown_action() {
  local out rc
  out=$("$RUN" --help 2>&1); rc=$?
  expect_code 0 "$rc" "--help exit"
  assert_contains "$out" 'fm-self-update-timer.sh run' "--help must show the run action"
  out=$("$RUN" bogus 2>&1); rc=$?
  expect_code 2 "$rc" "unknown action exit"
  pass "usage and unknown-action handling are pinned"
}

test_no_progress_is_one_quiet_line_and_no_restarts
test_progress_restarts_only_advanced_mates
test_live_build_token_skips_the_whole_run
test_ownerless_token_holds_only_inside_the_age_rig
test_dead_token_owner_does_not_block_the_run
test_unconfirmed_restart_is_retried_and_cleared
test_skips_are_logged_verbatim
test_update_failure_is_reported_and_fails_the_run
test_restart_hard_failure_keeps_the_mate_pending
test_restart_outcomes_match_ids_exactly
test_stderr_diagnostics_do_not_mislabel_a_no_progress_run
test_recognized_skip_on_stderr_still_drives_the_skipped_header
test_unrecognized_pass_output_is_recorded_without_a_skip_header
test_usage_and_unknown_action
