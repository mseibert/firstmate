#!/usr/bin/env bash
# Behavior tests for bin/fm-park.sh - the operating-point release.
#
# These tests pin the release contract hermetically through the executable
# interface firstmate actually calls:
#   1. Eligibility: a done-plus-PR task parks; a working crew, a secondmate, and
#      a task with no provable handoff all refuse loudly without mutating.
#   2. The release artifacts: the fm-park.v1 marker, the paused status line, and
#      the backlog note recorded through the configured-backend gate library (or
#      the printed hand edit on a manual-backend home).
#   3. Idempotency: an already-released task is success with no second exit and
#      no duplicate status line or backlog note.
#   4. Resume: the short relaunch note for merge and decision, marker removal,
#      the wrong-reason refusal, and the guarded resume completing under the
#      real lease guard.
#   5. Clear: the trivial-landing path removes the marker without a relaunch.
#   6. list/status read surfaces, the bounded sweep, and the snapshot's active
#      versus parked occupancy projection.
#
# The control plane, the current-state reader, the clock, and the tasks-axi
# backend are all deterministic seams, so no test touches a real agent, a real
# backlog, or the wall clock.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

PARK="$ROOT/bin/fm-park.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-park)
fm_git_identity fmtest fmtest@example.invalid

# --- fixture ----------------------------------------------------------------

make_case() {  # <name> -> echoes the home directory
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/fakebin"
  fm_git_init_commit "$home/wt"
  git -C "$home/wt" checkout -q -b fm/demo
  cat > "$home/control.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_CONTROL_LOG:?}"
exit "${FM_FAKE_CONTROL_RC:-0}"
SH
  chmod +x "$home/control.sh"
  cat > "$home/crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'state: %s · source: %s · %s\n' \
  "${FM_FAKE_CREW_STATE:-done}" "${FM_FAKE_CREW_SOURCE:-run-step}" "${FM_FAKE_CREW_DETAIL:-fixture}"
SH
  chmod +x "$home/crew-state.sh"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FAKE_AXI_LOG:?}"
case "${1:-}" in
  show)
    body=$(cat "${FAKE_AXI_BODY:?}" 2>/dev/null || true)
    encoded=$(printf '%s' "$body" | perl -MJSON::PP -e 'local $/; my $b = <STDIN>; print encode_json($b)')
    hk=${FAKE_AXI_HOLD_KIND:-'-'}
    hr=${FAKE_AXI_HOLD_REASON:-'-'}
    printf 'task:\n  id: %s\n  state: in_flight\n  blocked: no\n  held: %s\n  hold_kind: %s\n  hold_reason: %s\n  body: %s\n' \
      "$2" "${FAKE_AXI_HELD:-no}" "$hk" "$hr" "$encoded"
    ;;
  update)
    shift 2
    bodyfile=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --body-file) bodyfile=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    cp "$bodyfile" "${FAKE_AXI_BODY:?}"
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$home/fakebin/tasks-axi"
  printf '## In flight\n## Queued\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

write_task() {  # <home> <id> [extra-meta-line...]
  local home=$1 id=$2
  shift 2
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$home/wt" \
    "project=demo" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "spawn_gen=s-$id" \
    "$@"
  : > "$home/state/$id.status"
}

# park_seam_env <home> [ambient]: fill PARK_SEAM_ENV with the fixture seams
# every runner shares, one "NAME=value" per element, so a new seam reaches both
# runners. The values are the pinned fixture defaults; the `ambient` mode also
# honors the fixture variables the unguarded tests drive through the
# environment, while the pinned mode keeps the guarded cases from being
# perturbed from outside. run_park asks for `ambient`; run_park_guarded stays
# pinned.
PARK_SEAM_ENV=()
park_seam_env() {  # <home> [ambient]
  local home=$1 mode=${2:-pinned}
  local crew_state='done' crew_source=run-step crew_detail=fixture axi_held=no
  local hold_kind='' hold_reason=''
  if [ "$mode" = ambient ]; then
    crew_state=${FM_FAKE_CREW_STATE:-$crew_state}
    crew_source=${FM_FAKE_CREW_SOURCE:-$crew_source}
    crew_detail=${FM_FAKE_CREW_DETAIL:-$crew_detail}
    axi_held=${FAKE_AXI_HELD:-$axi_held}
    hold_kind=${FAKE_AXI_HOLD_KIND:-$hold_kind}
    hold_reason=${FAKE_AXI_HOLD_REASON:-$hold_reason}
  fi
  PARK_SEAM_ENV=(
    "PATH=$home/fakebin:$PATH"
    "FM_HOME=$home"
    "FM_STATE_OVERRIDE=$home/state"
    "FM_DATA_OVERRIDE=$home/data"
    "FM_CONFIG_OVERRIDE=$home/config"
    "FM_PARK_CREW_STATE_BIN=$home/crew-state.sh"
    "FM_PARK_NOW_EPOCH=1700000000"
    "FM_TASKS_AXI_COMPATIBLE=1"
    "FM_FAKE_CONTROL_LOG=$home/control.log"
    "FM_FAKE_CREW_STATE=$crew_state"
    "FM_FAKE_CREW_SOURCE=$crew_source"
    "FM_FAKE_CREW_DETAIL=$crew_detail"
    "FAKE_AXI_LOG=$home/axi.log"
    "FAKE_AXI_BODY=$home/axi-body"
    "FAKE_AXI_HELD=$axi_held"
    "FAKE_AXI_HOLD_KIND=$hold_kind"
    "FAKE_AXI_HOLD_REASON=$hold_reason"
  )
}

# run_park <home> <args...>: invoke fm-park.sh against one fixture home with
# every seam pointed at the fixture, honoring the ambient fixture overrides the
# unguarded tests drive through the environment.
run_park() {  # <home> <args...>
  local home=$1
  shift
  park_seam_env "$home" ambient
  env "${PARK_SEAM_ENV[@]}" \
    "FM_PARK_CONTROL_BIN=$home/control.sh" \
    "FM_FAKE_CONTROL_RC=${FM_FAKE_CONTROL_RC:-0}" \
    "$PARK" "$@"
}

marker_value() {  # <home> <key>
  grep "^$2=" "$1/state/t1.parked" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# write_guarded_control <home>: the release's control plane as the real one
# behaves - it sources bin/fm-lease-lib.sh and calls fm_lease_guard for the
# task before its verb runs, then releases its own guard from cleanup. The
# plain control.sh stub never guards, so only this stub exercises the real
# parent-hold/child-guard interplay that deadlocked the release.
write_guarded_control() {  # <home>
  local home=$1
  cat > "$home/control-guarded.sh" <<SH
#!/usr/bin/env bash
set -eu
ID=\${1:-}
STATE="$home/state"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-lease-lib.sh"
fm_lease_guard "\$ID" "lifecycle control (test)"
fm_lease_guard_release
if [ -e "\$STATE/.fm-lease-command.lock" ]; then
  printf '%s lock=held\n' "\$*" >> "$home/control.log"
else
  printf '%s lock=gone\n' "\$*" >> "$home/control.log"
fi
SH
  chmod +x "$home/control-guarded.sh"
}

# run_park_guarded <home> <args...>: run fm-park in a Pi supervision context
# with the REAL lease guard active, bounded so a guard deadlock fails the test
# instead of hanging it. It forces its own control-plane stub and a successful
# exit, and takes the pinned fixture seams so the guarded cases stay hermetic.
run_park_guarded() {  # <home> <args...>
  local home=$1
  shift
  park_seam_env "$home"
  fm_run_timed 20 env PI_CODING_AGENT=true FM_SUPERVISION_ACTOR=main FM_GATE_REFUSE_BYPASS=1 \
    "${PARK_SEAM_ENV[@]}" \
    "FM_PARK_CONTROL_BIN=$home/control-guarded.sh" \
    FM_FAKE_CONTROL_RC=0 \
    "$PARK" "$@"
}

# count_parked <home>: number of park markers present, without ls parsing.
count_parked() {
  local home=$1 marker count=0
  for marker in "$home/state"/*.parked; do
    [ -e "$marker" ] || continue
    count=$((count + 1))
  done
  printf '%s' "$count"
}

# --- eligibility ------------------------------------------------------------

test_done_pr_parks_and_records_the_handoff() {
  local home out rc
  home=$(make_case done-pr)
  write_task "$home" t1 "pr=https://github.com/example/demo/pull/7"
  printf 'done: PR https://github.com/example/demo/pull/7 checks green\n' > "$home/state/t1.status"
  out=$(run_park "$home" park t1); rc=$?
  expect_code 0 "$rc" "a done task with a PR must park"
  assert_contains "$out" "parked t1 reason=merge pointer=https://github.com/example/demo/pull/7" \
    "park did not report the release"

  [ -f "$home/state/t1.parked" ] || fail "park did not write the marker"
  [ "$(marker_value "$home" schema)" = fm-park.v1 ] || fail "marker schema is wrong"
  [ "$(marker_value "$home" task)" = t1 ] || fail "marker task is wrong"
  [ "$(marker_value "$home" reason)" = merge ] || fail "marker reason is wrong"
  [ "$(marker_value "$home" pointer)" = "https://github.com/example/demo/pull/7" ] \
    || fail "marker pointer is wrong"
  [ "$(marker_value "$home" branch)" = fm/demo ] || fail "marker branch is wrong"
  [ "$(marker_value "$home" pr)" = "https://github.com/example/demo/pull/7" ] \
    || fail "marker pr is wrong"
  [ "$(marker_value "$home" epoch)" = 1700000000 ] || fail "marker epoch is wrong"
  [ "$(marker_value "$home" incarnation)" = s-t1 ] || fail "marker incarnation is wrong"
  [ "$(marker_value "$home" state)" = released ] || fail "marker state is not released"

  grep -qxF 'paused [key=park-t1]: released awaiting merge - https://github.com/example/demo/pull/7' \
    "$home/state/t1.status" || fail "park did not append the canonical status line"
  grep -qF 'Park release: awaiting merge - https://github.com/example/demo/pull/7' "$home/axi-body" \
    || fail "park did not record the backlog note through the gate library"
  grep -qF 'Branch: fm/demo' "$home/axi-body" || fail "backlog note is missing the branch"
  grep -qF 'Remaining:' "$home/axi-body" || fail "backlog note is missing what remains open"
  grep -qF 'update t1' "$home/axi.log" || fail "the backlog note was not written through tasks-axi update"
  grep -qF -- '--archive-body' "$home/axi.log" || fail "the backlog note rewrite was not archived"

  [ "$(wc -l < "$home/control.log")" -eq 1 ] || fail "park must stop the worker exactly once"
  grep -qxF 't1 exit' "$home/control.log" || fail "park did not use the control plane's exit verb"
  pass "done plus PR parks with marker, status line, backlog note, and one verified exit"
}

test_park_is_idempotent() {
  local home out rc
  home=$(make_case idempotent)
  write_task "$home" t1 "pr=https://github.com/example/demo/pull/7"
  printf 'done: PR https://github.com/example/demo/pull/7 checks green\n' > "$home/state/t1.status"
  run_park "$home" park t1 >/dev/null || fail "first park failed"
  out=$(run_park "$home" park t1); rc=$?
  expect_code 0 "$rc" "a second park of a released task is success"
  assert_contains "$out" "already-parked t1" "the second park did not report the existing release"
  [ "$(wc -l < "$home/control.log")" -eq 1 ] || fail "the second park called exit again"
  [ "$(grep -cF 'released awaiting merge' "$home/state/t1.status")" -eq 1 ] \
    || fail "the second park duplicated the status line"
  [ "$(grep -cF 'Park release:' "$home/axi-body")" -eq 1 ] \
    || fail "the second park duplicated the backlog note"
  pass "an already-released task is idempotent success without a second exit"
}

test_park_refuses_a_working_crew() {
  local home out rc
  home=$(make_case working)
  write_task "$home" t1 "pr=https://github.com/example/demo/pull/7"
  printf 'done: PR https://github.com/example/demo/pull/7 checks green\n' > "$home/state/t1.status"
  out=$(FM_FAKE_CREW_STATE=working run_park "$home" park t1 2>&1); rc=$?
  expect_code 1 "$rc" "a working crew must refuse parking"
  assert_contains "$out" "actively working" "the refusal did not name the active worker"
  [ ! -e "$home/state/t1.parked" ] || fail "a refused park wrote a marker"
  [ ! -e "$home/control.log" ] || fail "a refused park stopped the worker"
  pass "an actively working crew is refused"
}

test_park_refuses_a_secondmate() {
  local home out rc
  home=$(make_case secondmate)
  fm_write_meta "$home/state/mate.meta" \
    "window=firstmate:fm-mate" \
    "worktree=$home/wt" \
    "kind=secondmate" \
    "mode=secondmate"
  printf 'done: idle\n' > "$home/state/mate.status"
  out=$(run_park "$home" park mate 2>&1); rc=$?
  expect_code 1 "$rc" "a secondmate must refuse parking"
  assert_contains "$out" "secondmates are never parked" "the refusal did not name the secondmate rule"
  [ ! -e "$home/state/mate.parked" ] || fail "a refused secondmate park wrote a marker"
  pass "a persistent secondmate is refused"
}

test_park_refuses_without_a_pointer() {
  local home out rc
  home=$(make_case no-pointer)
  write_task "$home" t1
  printf 'done: report ready\n' > "$home/state/t1.status"
  out=$(run_park "$home" park t1 2>&1); rc=$?
  expect_code 1 "$rc" "a task with no handoff pointer must refuse parking"
  assert_contains "$out" "no provable handoff" "the refusal did not name the missing pointer"
  [ ! -e "$home/state/t1.parked" ] || fail "a refused park wrote a marker"
  pass "a task with no provable handoff is refused"
}

test_park_refuses_an_unknown_id() {
  local home out rc
  home=$(make_case unknown-id)
  out=$(run_park "$home" park nope 2>&1); rc=$?
  expect_code 1 "$rc" "an unknown task id must refuse"
  assert_contains "$out" "no task 'nope'" "the refusal did not name the missing task"
  pass "an unknown task id is refused"
}

# --- decisions --------------------------------------------------------------

test_decision_key_parks_and_resume_carries_the_decision() {
  local home out rc
  home=$(make_case decision)
  write_task "$home" t1
  printf 'needs-decision [key=nm-run-fix-review2]: choose a route\n' > "$home/state/t1.status"
  out=$(FM_FAKE_CREW_STATE=parked FM_FAKE_CREW_SOURCE=status-log run_park "$home" park t1); rc=$?
  expect_code 0 "$rc" "a documented decision wait must park"
  assert_contains "$out" "parked t1 reason=decision pointer=key=nm-run-fix-review2" \
    "park did not report the decision release"
  [ "$(marker_value "$home" pointer)" = "key=nm-run-fix-review2" ] || fail "marker pointer is wrong"
  grep -qF 'Park release: awaiting decision - key=nm-run-fix-review2' "$home/axi-body" \
    || fail "the backlog note did not record the decision pointer"

  out=$(run_park "$home" resume t1 --reason decision --note "Use option B."); rc=$?
  expect_code 0 "$rc" "resume for a decision must succeed"
  assert_contains "$out" "resumed t1 reason=decision" "resume did not report the task"
  grep -qF 'relaunch --note Use option B.' "$home/control.log" \
    || fail "resume did not pass the decision words as the relaunch note"
  grep -qF 'The decision recorded at key=nm-run-fix-review2 is being delivered through your instruction inbox' "$home/control.log" \
    || fail "the relaunch note did not name the decision pointer"
  [ ! -e "$home/state/t1.parked" ] || fail "resume did not remove the marker"
  pass "a keyed decision parks and resume carries the decision into the short run"
}

test_captain_held_row_parks() {
  local home out rc
  home=$(make_case captain-hold)
  write_task "$home" t1
  printf 'done: report ready\n' > "$home/state/t1.status"
  out=$(FAKE_AXI_HOLD_KIND=captain FAKE_AXI_HOLD_REASON='pick a route' FM_FAKE_CREW_STATE=parked FM_FAKE_CREW_SOURCE=status-log \
    run_park "$home" park t1); rc=$?
  expect_code 0 "$rc" "a captain-held row must park"
  assert_contains "$out" "reason=decision pointer=captain-hold: pick a route" \
    "park did not carry the hold reason as the pointer"
  pass "a captain-held backlog row is a documented wait"
}

test_resume_refuses_the_wrong_reason() {
  local home out rc
  home=$(make_case wrong-reason)
  write_task "$home" t1 "pr=https://github.com/example/demo/pull/7"
  printf 'done: PR https://github.com/example/demo/pull/7 checks green\n' > "$home/state/t1.status"
  run_park "$home" park t1 >/dev/null || fail "park failed"
  out=$(run_park "$home" resume t1 --reason decision 2>&1); rc=$?
  expect_code 1 "$rc" "resuming a merge-parked task as a decision must refuse"
  assert_contains "$out" "parked for reason=merge" "the refusal did not name the recorded reason"
  [ -e "$home/state/t1.parked" ] || fail "a refused resume removed the marker"
  [ "$(wc -l < "$home/control.log")" -eq 1 ] || fail "a refused resume relaunched the worker"
  pass "resume refuses a reason that does not match the marker"
}

test_resume_refuses_a_task_that_is_not_parked() {
  local home out rc
  home=$(make_case not-parked)
  write_task "$home" t1 "pr=https://github.com/example/demo/pull/7"
  out=$(run_park "$home" resume t1 --reason merge 2>&1); rc=$?
  expect_code 1 "$rc" "resuming a task that is not parked must refuse"
  assert_contains "$out" "is not parked" "the refusal did not name the missing marker"
  pass "resume refuses a task with no marker"
}

# --- clear and read surfaces ------------------------------------------------

test_clear_removes_the_marker_without_relaunch() {
  local home out rc
  home=$(make_case clear)
  write_task "$home" t1 "pr=https://github.com/example/demo/pull/7"
  printf 'done: PR https://github.com/example/demo/pull/7 checks green\n' > "$home/state/t1.status"
  run_park "$home" park t1 >/dev/null || fail "park failed"
  out=$(run_park "$home" clear t1 --reason 'landed cleanly'); rc=$?
  expect_code 0 "$rc" "clear must succeed for a parked task"
  assert_contains "$out" "cleared t1 state=released reason=landed cleanly" "clear did not report the removal"
  [ ! -e "$home/state/t1.parked" ] || fail "clear did not remove the marker"
  [ "$(wc -l < "$home/control.log")" -eq 1 ] || fail "clear relaunched the worker"
  pass "clear resolves the marker without a worker relaunch"
}

test_list_and_status_report_the_parked_set() {
  local home out rc
  home=$(make_case list-status)
  write_task "$home" t1 "pr=https://github.com/example/demo/pull/7"
  printf 'done: PR https://github.com/example/demo/pull/7 checks green\n' > "$home/state/t1.status"
  run_park "$home" park t1 >/dev/null || fail "park failed"
  out=$(run_park "$home" list); rc=$?
  expect_code 0 "$rc" "list must succeed"
  assert_contains "$out" "t1	merge	https://github.com/example/demo/pull/7	fm/demo	https://github.com/example/demo/pull/7	1700000000	s-t1	released" \
    "list did not print the parked row"
  out=$(run_park "$home" status t1); rc=$?
  expect_code 0 "$rc" "status must succeed for a parked task"
  assert_contains "$out" "parked t1 reason=merge" "status did not report the parked task"
  assert_contains "$out" "state=released" "status did not report the release state"
  run_park "$home" clear t1 >/dev/null || fail "clear failed"
  out=$(run_park "$home" status t1); rc=$?
  expect_code 1 "$rc" "status must exit 1 for a task that is not parked"
  assert_contains "$out" "not-parked t1" "status did not report the unparked task"
  pass "list and status report the parked set"
}

# --- backlog note gate and manual fallback ----------------------------------

test_manual_backend_prints_the_owed_note() {
  local home out rc
  home=$(make_case manual-backend)
  write_task "$home" t1 "pr=https://github.com/example/demo/pull/7"
  printf 'done: PR https://github.com/example/demo/pull/7 checks green\n' > "$home/state/t1.status"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf 'original body\n' > "$home/axi-body"
  out=$(run_park "$home" park t1 2>&1); rc=$?
  expect_code 0 "$rc" "a manual-backend home still parks"
  assert_contains "$out" "Backlog: add this note by hand to $home/data/backlog.md:" \
    "the manual fallback did not name the owed hand edit"
  assert_contains "$out" "Park release: awaiting merge - https://github.com/example/demo/pull/7" \
    "the manual fallback did not print the note"
  [ "$(cat "$home/axi-body")" = 'original body' ] || fail "the manual path wrote the backlog body"
  pass "a manual-backend home is told the exact note owed"
}

# --- lease guard across the release -----------------------------------------

# guard_release_case <case> <fresh|releasing> <label>: park t1 under the real
# lease guard. The release holds the lease-command lock while it runs the
# control plane, which guards the same task; before the guard hold was
# inheritable the child waited forever on the parent's non-reentrant lock, so a
# deadlock fails the test through the timeout instead of hanging it.
guard_release_case() {  # <case> <fresh|releasing> <label>
  local case=$1 retry=$2 label=$3
  local home out rc
  home=$(make_case "$case")
  write_task "$home" t1 "pr=https://github.com/example/demo/pull/7"
  printf 'done: PR https://github.com/example/demo/pull/7 checks green\n' > "$home/state/t1.status"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf '%s\n' "$$" > "$home/state/.lock"
  write_guarded_control "$home"
  if [ "$retry" = releasing ]; then
    # The exact retry a sweep or a later session runs after an interrupted
    # release: the marker is already recorded at state=releasing.
    printf 'schema=fm-park.v1\ntask=t1\nreason=merge\npointer=https://github.com/example/demo/pull/7\nbranch=fm/demo\npr=https://github.com/example/demo/pull/7\nepoch=1699999999\nincarnation=s-t1\nstate=releasing\n' \
      > "$home/state/t1.parked"
  fi
  out=$(run_park_guarded "$home" park t1 2>&1); rc=$?
  expect_code 0 "$rc" "$label must complete while its own guard is held (a deadlock times out): $out"
  assert_contains "$out" "parked t1 reason=merge" "$label did not report the release"
  [ "$(marker_value "$home" state)" = released ] || fail "$label did not commit the verified release"
  grep -qxF 't1 exit lock=held' "$home/control.log" \
    || fail "$label: the guarded child did not run under the parent's lock or dropped it: $(cat "$home/control.log" 2>/dev/null)"
  [ ! -e "$home/state/.fm-lease-command.lock" ] || fail "$label left the guard lock behind"
  pass "$label completes with the real lease guard active and the child cannot drop the parent's lock"
}

test_park_release_completes_under_the_real_guard() {
  guard_release_case guard-release fresh "a park release"
}

test_releasing_retry_completes_under_the_real_guard() {
  guard_release_case guard-retry releasing "the releasing retry a sweep runs"
}

test_resume_completes_under_the_real_guard() {
  local home out rc
  home=$(make_case guard-resume)
  write_task "$home" t1 "pr=https://github.com/example/demo/pull/7"
  printf 'done: PR https://github.com/example/demo/pull/7 checks green\n' > "$home/state/t1.status"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf '%s\n' "$$" > "$home/state/.lock"
  write_guarded_control "$home"
  run_park_guarded "$home" park t1 >/dev/null || fail "park failed under the real guard"
  # resume holds the same guard while the control plane relaunches the task, so
  # the same deadlock applies to it; before the guard hold was inheritable this
  # call waited forever on the parent's non-reentrant lock.
  out=$(run_park_guarded "$home" resume t1 --reason merge 2>&1); rc=$?
  expect_code 0 "$rc" "a resume must complete while its own guard is held (a deadlock times out): $out"
  assert_contains "$out" "resumed t1 reason=merge" "the guarded resume did not report the task"
  grep -q 't1 relaunch --note.*lock=held' "$home/control.log" \
    || fail "the guarded resume's child did not run under the parent's lock: $(cat "$home/control.log" 2>/dev/null)"
  [ ! -e "$home/state/t1.parked" ] || fail "the guarded resume did not remove the marker"
  [ ! -e "$home/state/.fm-lease-command.lock" ] || fail "the guarded resume left the guard lock behind"
  pass "a resume completes with the real lease guard active and the child cannot drop the parent's lock"
}

test_releasing_retry_restores_the_status_line() {
  local home out rc
  home=$(make_case releasing-retry)
  write_task "$home" t1 "pr=https://github.com/example/demo/pull/7"
  printf 'done: PR https://github.com/example/demo/pull/7 checks green\n' > "$home/state/t1.status"
  # Simulate a release interrupted between the marker and the status line.
  printf 'schema=fm-park.v1\ntask=t1\nreason=merge\npointer=https://github.com/example/demo/pull/7\nbranch=fm/demo\npr=https://github.com/example/demo/pull/7\nepoch=1699999999\nincarnation=s-t1\nstate=releasing\n' \
    > "$home/state/t1.parked"
  out=$(run_park "$home" park t1); rc=$?
  expect_code 0 "$rc" "a releasing marker must be retried to completion"
  assert_contains "$out" "parked t1 reason=merge" "the retry did not report the release"
  grep -qxF 'paused [key=park-t1]: released awaiting merge - https://github.com/example/demo/pull/7' \
    "$home/state/t1.status" || fail "the releasing retry did not restore the status handoff"
  [ "$(marker_value "$home" state)" = released ] || fail "the retry did not commit the verified release"
  [ "$(wc -l < "$home/control.log")" -eq 1 ] || fail "the retry did not stop the worker exactly once"
  pass "a releasing retry restores the status line and commits the verified release"
}

test_stale_marker_from_an_earlier_incarnation() {
  local home out rc
  home=$(make_case stale-marker)
  write_task "$home" t1 "pr=https://github.com/example/demo/pull/7"
  printf 'done: PR https://github.com/example/demo/pull/7 checks green\n' > "$home/state/t1.status"
  # A released marker from an earlier worker: a control-plane relaunch started a
  # new incarnation outside fm-park, so the marker must not free the slot.
  printf 'schema=fm-park.v1\ntask=t1\nreason=merge\npointer=https://github.com/example/demo/pull/7\nbranch=fm/demo\npr=https://github.com/example/demo/pull/7\nepoch=1699999999\nincarnation=s-old\nstate=released\n' \
    > "$home/state/t1.parked"
  out=$(run_park "$home" status t1 2>&1); rc=$?
  expect_code 1 "$rc" "status must not read a stale marker as parked"
  assert_contains "$out" "stale t1" "status did not report the stale marker"
  # A fresh park drops the stale marker and writes its own release.
  out=$(run_park "$home" park t1 2>&1); rc=$?
  expect_code 0 "$rc" "park must replace a stale marker with a fresh release"
  assert_contains "$out" "parked t1 reason=merge" "the fresh park did not report the release"
  [ "$(marker_value "$home" incarnation)" = s-t1 ] || fail "the fresh marker did not record the current incarnation"
  [ "$(wc -l < "$home/control.log")" -eq 1 ] || fail "the fresh park must stop the worker exactly once"
  pass "a marker from an earlier incarnation is stale and a fresh park replaces it"
}

test_resume_resolves_a_raw_launch_harness() {
  local home out rc
  home=$(make_case raw-harness)
  write_task "$home" t1 "pr=https://github.com/example/demo/pull/7" "harness=grok-2"
  printf 'done: PR https://github.com/example/demo/pull/7 checks green\n' > "$home/state/t1.status"
  run_park "$home" park t1 >/dev/null || fail "park failed for a raw-launch harness task"
  out=$(run_park "$home" resume t1 --reason merge); rc=$?
  expect_code 0 "$rc" "resume must work for a raw-launch harness task"
  assert_contains "$out" "resumed t1 reason=merge" "resume did not report the task"
  grep -qF 'relaunch --harness grok --note' "$home/control.log" \
    || fail "resume did not pass the resolved adapter family for a raw-launch harness"
  pass "resume passes the resolved adapter family for a raw launch command"
}

# --- run-step gates ---------------------------------------------------------

test_ask_user_gate_parks_as_decision() {
  local home out rc
  home=$(make_case ask-user-gate)
  write_task "$home" t1 "pr=https://github.com/example/demo/pull/7"
  printf 'needs-decision [key=nm-run-review]: ask-user findings=f4\n' > "$home/state/t1.status"
  out=$(FM_FAKE_CREW_STATE=parked FM_FAKE_CREW_SOURCE=run-step \
    FM_FAKE_CREW_DETAIL='parked at review: 1 finding(s) (ask-user: authority decision)' \
    run_park "$home" park t1); rc=$?
  expect_code 0 "$rc" "an ask-user-gated run must park as a decision wait"
  assert_contains "$out" "reason=decision pointer=key=nm-run-review" \
    "the ask-user gate did not take its keyed decision pointer"
  [ "$(marker_value "$home" pointer)" = "key=nm-run-review" ] || fail "the gate pointer is wrong"
  pass "an ask-user-gated run parks as a decision wait with the gate key"
}

test_fix_review_gate_refuses() {
  local home out rc
  home=$(make_case fix-review-gate)
  write_task "$home" t1 "pr=https://github.com/example/demo/pull/7"
  printf 'working: at the fix-review gate\n' > "$home/state/t1.status"
  # The real reader emits the gate's step name, never its status, and omits the
  # authority marker for a fix_review gate even when its findings carry an
  # ask-user action: the pipeline's fix round is in flight.
  out=$(FM_FAKE_CREW_STATE=parked FM_FAKE_CREW_SOURCE=run-step \
    FM_FAKE_CREW_DETAIL='parked at review: 2 finding(s)' \
    run_park "$home" park t1 2>&1); rc=$?
  expect_code 1 "$rc" "a fix-review-gated run must refuse parking"
  assert_contains "$out" "gate the worker must answer" "the refusal did not name the worker-owned gate"
  [ ! -e "$home/state/t1.parked" ] || fail "a refused fix-review gate wrote a marker"
  [ ! -e "$home/control.log" ] || fail "a refused fix-review gate stopped the worker"
  pass "a fix-review-gated run is refused because the worker must answer it"
}

test_ask_user_gate_without_a_key_refuses() {
  local home out rc
  home=$(make_case ask-user-gate-no-key)
  write_task "$home" t1 "pr=https://github.com/example/demo/pull/7"
  printf 'working: at the authority gate\n' > "$home/state/t1.status"
  out=$(FM_FAKE_CREW_STATE=parked FM_FAKE_CREW_SOURCE=run-step \
    FM_FAKE_CREW_DETAIL='parked at review: 1 finding(s) (ask-user: authority decision)' \
    run_park "$home" park t1 2>&1); rc=$?
  expect_code 1 "$rc" "an ask-user gate without a recorded key must refuse"
  assert_contains "$out" "no keyed decision is recorded" "the refusal did not name the missing gate key"
  [ ! -e "$home/state/t1.parked" ] || fail "a refused gate wrote a marker"
  pass "an ask-user gate without a recorded decision key refuses rather than guessing"
}

# --- sweep ------------------------------------------------------------------

test_sweep_parks_eligible_tasks_and_skips_working_ones() {
  local home out rc
  home=$(make_case sweep)
  write_task "$home" t1 "pr=https://github.com/example/demo/pull/7"
  write_task "$home" t2 "pr=https://github.com/example/demo/pull/8"
  write_task "$home" t3 "pr=https://github.com/example/demo/pull/9"
  printf 'done: PR https://github.com/example/demo/pull/7 checks green\n' > "$home/state/t1.status"
  printf 'done: PR https://github.com/example/demo/pull/8 checks green\n' > "$home/state/t2.status"
  printf 'done: PR https://github.com/example/demo/pull/9 checks green\n' > "$home/state/t3.status"
  out=$(FM_FAKE_CREW_STATE=working run_park "$home" sweep --limit 2); rc=$?
  expect_code 0 "$rc" "a bounded sweep must exit 0"
  [ -z "$out" ] || fail "a clean sweep must be silent (got: $out)"
  [ ! -e "$home/state/t1.parked" ] || fail "the sweep parked a working task"
  [ ! -e "$home/state/t2.parked" ] || fail "the sweep parked a working task"
  [ ! -e "$home/state/t3.parked" ] || fail "the sweep parked a working task"

  out=$(run_park "$home" sweep --limit 1); rc=$?
  expect_code 0 "$rc" "the sweep must exit 0"
  [ -z "$out" ] || fail "a clean sweep must be silent (got: $out)"
  local parked
  parked=$(count_parked "$home")
  [ "$parked" -eq 1 ] || fail "sweep --limit 1 parked $parked tasks instead of one"
  run_park "$home" sweep --limit 5 >/dev/null || fail "the follow-up sweep failed"
  parked=$(count_parked "$home")
  [ "$parked" -eq 3 ] || fail "the follow-up sweep did not park the remaining tasks"
  pass "the sweep parks eligible tasks only, bounded by --limit, and stays silent"
}

test_sweep_surfaces_the_manual_backlog_note() {
  local home out rc
  home=$(make_case sweep-manual)
  write_task "$home" t1 "pr=https://github.com/example/demo/pull/7"
  printf 'done: PR https://github.com/example/demo/pull/7 checks green\n' > "$home/state/t1.status"
  printf 'manual\n' > "$home/config/backlog-backend"
  out=$(run_park "$home" sweep 2>&1); rc=$?
  expect_code 0 "$rc" "a manual-backend sweep must exit 0"
  assert_contains "$out" "Backlog: add this note by hand to $home/data/backlog.md:" \
    "the sweep discarded the owed manual backlog note"
  [ "$(marker_value "$home" state)" = released ] || fail "the sweep did not release the task"
  pass "the sweep surfaces the owed manual backlog note instead of discarding it"
}

test_sweep_reports_a_failed_release() {
  local home out rc
  home=$(make_case sweep-failure)
  write_task "$home" t1 "pr=https://github.com/example/demo/pull/7"
  printf 'done: PR https://github.com/example/demo/pull/7 checks green\n' > "$home/state/t1.status"
  out=$(FM_FAKE_CONTROL_RC=1 run_park "$home" sweep); rc=$?
  expect_code 0 "$rc" "a failed release inside the sweep must not fail the sweep"
  assert_contains "$out" "PARK_SWEEP: could not release t1" "the sweep did not report the failed release"
  [ -f "$home/state/t1.parked" ] || fail "a failed release should leave the durable intent marker"
  [ "$(marker_value "$home" state)" = releasing ] || fail "a failed release must not claim released"
  out=$(run_park "$home" status t1); rc=$?
  expect_code 1 "$rc" "status must exit 1 for an unverified release"
  assert_contains "$out" "releasing t1" "status must not read an unverified release as parked"
  pass "a failed release leaves a releasing marker, prints one PARK_SWEEP line, and status stays honest"
}

# --- snapshot occupancy -----------------------------------------------------

test_snapshot_separates_active_and_parked_tasks() {
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
  local home out
  home=$(make_case occupancy)
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  list-windows)
    sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta
    ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'codex\n' ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    case "$target" in
      *working-task*) printf 'work in progress\nesc to interrupt\n' ;;
      *) printf 'all quiet\n> \n' ;;
    esac
    ;;
esac
exit 0
SH
  cat > "$home/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$home/fakebin/tmux" "$home/fakebin/no-mistakes"
  write_task "$home" working-task
  write_task "$home" parked-task "pr=https://github.com/example/demo/pull/7"
  write_task "$home" done-task "harness=grok"
  printf 'working: in progress\n' > "$home/state/working-task.status"
  local gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" working-task)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" working-task busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  printf 'done: PR https://github.com/example/demo/pull/7 checks green\n' > "$home/state/parked-task.status"
  printf 'done: report ready\n' > "$home/state/done-task.status"
  printf 'schema=fm-park.v1\ntask=parked-task\nreason=merge\npointer=https://github.com/example/demo/pull/7\nbranch=fm/demo\npr=https://github.com/example/demo/pull/7\nepoch=1700000000\nincarnation=s-parked-task\nstate=released\n' \
    > "$home/state/parked-task.parked"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$SNAPSHOT" --json) \
    || fail "the fleet snapshot failed"
  printf '%s' "$out" | jq -e '
    .occupancy.schema == "fm-fleet-occupancy.v1"
      and .occupancy.active == 1
      and .occupancy.parked == 1
      and .occupancy.done == 1
      and .occupancy.active_ids == ["working-task"]
      and .occupancy.parked_ids == ["parked-task"]
  ' >/dev/null || fail "occupancy did not separate active and parked tasks: $out"
  pass "the snapshot counts only working tasks as active and parked tasks separately"
}

test_done_pr_parks_and_records_the_handoff
test_park_is_idempotent
test_park_refuses_a_working_crew
test_park_refuses_a_secondmate
test_park_refuses_without_a_pointer
test_park_refuses_an_unknown_id
test_releasing_retry_restores_the_status_line
test_park_release_completes_under_the_real_guard
test_releasing_retry_completes_under_the_real_guard
test_resume_completes_under_the_real_guard
test_stale_marker_from_an_earlier_incarnation
test_resume_resolves_a_raw_launch_harness
test_decision_key_parks_and_resume_carries_the_decision
test_captain_held_row_parks
test_ask_user_gate_parks_as_decision
test_fix_review_gate_refuses
test_ask_user_gate_without_a_key_refuses
test_resume_refuses_the_wrong_reason
test_resume_refuses_a_task_that_is_not_parked
test_clear_removes_the_marker_without_relaunch
test_list_and_status_report_the_parked_set
test_manual_backend_prints_the_owed_note
test_sweep_parks_eligible_tasks_and_skips_working_ones
test_sweep_surfaces_the_manual_backlog_note
test_sweep_reports_a_failed_release
test_snapshot_separates_active_and_parked_tasks

echo "all fm-park tests passed"
