#!/usr/bin/env bash
# tests/fm-watch-dead-worker.test.sh - the captain's dead-worker reality rule
# built into bin/fm-watch.sh: a task recorded as in flight must have a running
# process, and a task without a running process on an idle machine is a DEAD
# WORKER, not a declared wait - no matter what its status line says, including
# a paused: declaration (a task without a running process is not a declared
# wait). The rule exists for the 2026-09 pc-316 incident: a worker OOM-killed
# in its tmux-spawn scope took its window with it, leaving an in-flight task
# with no endpoint and no stale signal, while a paused: line had disarmed the
# very guard that should have reported it.
#
# The underlying "is a live agent running" signal is fm_backend_agent_alive,
# whose per-harness classification is already proven with real processes in
# tests/fm-tmux-agent-liveness.test.sh and live-guarded for every installed
# harness by tests/fm-harness-liveness-drift-live-e2e.test.sh (live-harness-optin
# family). This test therefore needs no new live guard: it pins the NEW
# classifier logic - the in-flight/idle/declaration combination - hermetically
# with the backend readers overridden, then proves the whole decision against
# REAL processes and REAL tmux on a private socket (skipping when tmux is
# absent), so CI enforces the rule everywhere it runs tmux.
#
# Deterministic seams exercised here: FM_DEAD_WORKER_LOADAVG pins the machine
# load, FM_DEAD_WORKER_KERNEL_LOG points the OOM reader at a canned kernel log,
# and FM_DEAD_WORKER_GRACE bounds the spawn freshness grace.
# shellcheck disable=SC2030,SC2031,SC2329 # this test's whole point is overriding the watcher's backend readers and load seam inside ( ) subshells, invoked indirectly by the sourced functions under test
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-watch-dead-worker)
STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"

# Source the watcher with an isolated state/home. The guard returns before the
# lock/loop, so only the functions load.
export FM_STATE_OVERRIDE="$STATE_DIR"
export FM_ROOT_OVERRIDE="$ROOT"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-watch.sh"

# wake() exits the watcher cycle in production; tests override it to capture the
# reason instead. SLEEP_BIN is captured before any later use, because `command -v`
# would otherwise resolve a shadowing function first and hand the real-process
# section a broken symlink instead of the system sleep binary.
WAKE_LOG="$TMP/wakes"
SLEEP_BIN=$(command -v sleep 2>/dev/null || true)
wake() { printf '%s\n' "$1" >> "$WAKE_LOG"; return 0; }

# Deterministic machine load: the machine is idle exactly when the pinned load1
# is below 1 (the /proc/loadavg / sysctl reader itself is covered below).
export FM_DEAD_WORKER_LOADAVG=0.10

reset_state() {
  rm -f "$STATE_DIR"/*.meta "$STATE_DIR"/*.status \
    "$STATE_DIR"/.dead-worker-* "$STATE_DIR"/.paused-* \
    "$STATE_DIR"/.paused-rechecked-* "$STATE_DIR"/.wake-queue \
    "$STATE_DIR"/.wake-queue.seq "$STATE_DIR"/.watch-triage.log 2>/dev/null || true
  : > "$WAKE_LOG"
}

mk_meta() {  # <task> <window> [extra kv...]
  local task=$1 win=$2
  shift 2
  fm_write_meta "$STATE_DIR/$task.meta" "window=$win" "backend=tmux" \
    "endpoint_task_id=$task" "worktree=$TMP/wt-$task" "harness=dev-server" \
    "kind=ship" "mode=no-mistakes" "yolo=off" "$@"
}

backdate() {  # <task> - the meta is rewritten on spawn/relaunch, so a dead
  touch -d '10 minutes ago' "$STATE_DIR/$1.meta"
}

wake_count() {
  wc -l < "$WAKE_LOG" | tr -d '[:space:]'
}

# --- machine load: the machine-idle half -------------------------------------

if ! machine_load1_below_one; then
  fail "a load1 of 0.10 must count as machine idle"
fi
pass "dead-worker: load1 below 1 counts as machine idle"

( export FM_DEAD_WORKER_LOADAVG=1.00; machine_load1_below_one ) \
  && fail "a load1 of exactly 1 must NOT count as machine idle"
( export FM_DEAD_WORKER_LOADAVG=7.50; machine_load1_below_one ) \
  && fail "a load1 of 7.5 must NOT count as machine idle"
( export FM_DEAD_WORKER_LOADAVG=not-a-number; machine_load1_below_one ) \
  && fail "an unreadable load must NOT count as machine idle (fail-closed)"
pass "dead-worker: a load at or above 1, or unreadable, is never machine idle"

# --- in-flight semantics: what counts as expecting a live worker --------------

expects() {  # <status-line> -> 0 iff task_expects_live_worker is true
  local task=$1 line=$2 expect=$3 rc
  printf '%s\n' "$line" > "$STATE_DIR/$task.status"
  task_expects_live_worker "$task"
  rc=$?
  if [ "$expect" = yes ]; then
    [ "$rc" -eq 0 ] || fail "status '$line' must expect a live worker"
  else
    [ "$rc" -ne 0 ] || fail "status '$line' must not expect a live worker"
  fi
}

expects exp-paused "paused: waiting for the upstream release" yes
expects exp-working "working: building the thing" yes
expects exp-decision "needs-decision: which option" yes
expects exp-empty "" yes
expects exp-done "done: PR https://github.com/example/repo/pull/1" no
expects exp-failed "failed: validation went red" no
expects exp-held "captain-held [key=route]: tracked by task-decision-route" no
expects exp-dpv "done-pending-verify: delivered, awaiting verification" no
pass "dead-worker: paused, working, needs-decision and empty status still expect a live worker; done, failed, captain-held and done-pending-verify do not"

# --- OOM evidence: the wake reason must name the cause when the kernel log does

klog() {  # <lines...> - a canned kernel log served through the reader seam
  local file=$1
  shift
  cat > "$file" <<SH
#!/usr/bin/env bash
printf '%s\\n' "$@"
SH
  chmod +x "$file"
}

KLOG="$TMP/klog"
OOM_LOG="$TMP/oom-log.sh"

klog "$OOM_LOG" \
  "Jun 6 03:50:01 host kernel: Out of memory: Killed process 1234 (dev-server) total-vm:1400000kB, anon-rss:1200000kB, file-rss:0kB, UID:1000" \
  "Jun 6 03:50:01 host kernel: Task in /system.slice/tmux-spawn-1234.scope killed as a result of limit of /system.slice/tmux-spawn-1234.scope"
reset_state
mk_meta oom-task "tmux:win-oom"
backdate oom-task
FM_DEAD_WORKER_KERNEL_LOG="$OOM_LOG" \
  fm_oom_evidence oom-task "$TMP/wt-oom-task" > "$TMP/oom-out"
assert_contains "$(cat "$TMP/oom-out")" \
  "kernel OOM-killed the worker process (dev-server)" \
  "an OOM line naming this task's harness process must be the strongest tie"
pass "dead-worker: OOM evidence names the worker process when the harness matches"

klog "$OOM_LOG" \
  "Jun 6 03:50:01 host kernel: Out of memory: Killed process 999 (node) UID:1000" \
  "$TMP/wt-oom2-task appears in the log lines below"
reset_state
mk_meta oom2-task "tmux:win-oom2"
backdate oom2-task
FM_DEAD_WORKER_KERNEL_LOG="$OOM_LOG" \
  fm_oom_evidence oom2-task "$TMP/wt-oom2-task" > "$TMP/oom-out"
assert_contains "$(cat "$TMP/oom-out")" "kernel OOM evidence names the worker worktree" \
  "an OOM line naming the worker's worktree must be the second tier"
pass "dead-worker: OOM evidence names the worker worktree when the log contains it"

klog "$OOM_LOG" "Jun 6 03:50:01 host kernel: Out of memory: Killed process 888 (chrome) UID:1000"
reset_state
mk_meta oom3-task "tmux:win-oom3"
backdate oom3-task
FM_DEAD_WORKER_KERNEL_LOG="$OOM_LOG" \
  fm_oom_evidence oom3-task "$TMP/wt-oom3-task" > "$TMP/oom-out"
assert_contains "$(cat "$TMP/oom-out")" "recent OOM-kill on this machine" \
  "an OOM line naming neither the harness nor the worktree must still be reported as machine evidence"
pass "dead-worker: OOM evidence falls back to a plain recent machine OOM-kill"

klog "$OOM_LOG" "Jun 6 03:50:01 host kernel: everything is fine"
reset_state
mk_meta oom4-task "tmux:win-oom4"
backdate oom4-task
FM_DEAD_WORKER_KERNEL_LOG="$OOM_LOG" \
  fm_oom_evidence oom4-task "$TMP/wt-oom4-task" > "$TMP/oom-out"
[ ! -s "$TMP/oom-out" ] || fail "a kernel log with no OOM kill must produce no evidence: $(cat "$TMP/oom-out")"
pass "dead-worker: a kernel log without an OOM kill produces no invented evidence"

reset_state
mk_meta oom5-task "tmux:win-oom5"
backdate oom5-task
FM_DEAD_WORKER_KERNEL_LOG="$TMP/does-not-exist.sh" \
  fm_oom_evidence oom5-task "$TMP/wt-oom5-task" > "$TMP/oom-out"
[ ! -s "$TMP/oom-out" ] || fail "an unreadable kernel log must be a silent no-op: $(cat "$TMP/oom-out")"
pass "dead-worker: an unreadable kernel log is a silent no-op (fail-closed)"

# A kernel-log reader that never finishes must be killed at the wall-clock
# bound and contribute nothing, so a hung journal can never stall the watcher.
cat > "$TMP/slow-oom-log.sh" <<'SH'
#!/usr/bin/env bash
sleep 30
printf '%s\n' 'Jun 6 03:50:01 host kernel: Out of memory: Killed process 1234 (dev-server)'
SH
chmod +x "$TMP/slow-oom-log.sh"
reset_state
mk_meta oom6-task "tmux:win-oom6"
backdate oom6-task
start=$(date +%s)
FM_DEAD_WORKER_KERNEL_LOG="$TMP/slow-oom-log.sh" \
  fm_oom_evidence oom6-task "$TMP/wt-oom6-task" > "$TMP/oom-out" || true
elapsed=$(( $(date +%s) - start ))
[ ! -s "$TMP/oom-out" ] || fail "a hung kernel log must contribute no evidence: $(cat "$TMP/oom-out")"
[ "$elapsed" -lt 10 ] || fail "a hung kernel log must be bounded, took ${elapsed}s"
pass "dead-worker: a hung kernel-log reader is killed at the bound and contributes nothing"

# --- the reality check itself, backend readers overridden --------------------
# Each case runs in a subshell that overrides the endpoint readers, so the
# in-flight/idle/declaration logic is pinned without any real backend.

reset_state
mk_meta dw-live "tmux:win-live"
backdate dw-live
printf 'working: mid-build\n' > "$STATE_DIR/dw-live.status"
(
  fm_backend_agent_alive() { printf 'alive'; }
  fm_dead_worker_reality_check "tmux:win-live" dw-live "$(window_key "tmux:win-live")" ship
) && fail "a live agent must never escalate a dead worker"
[ "$(wake_count)" = 0 ] || fail "a live agent must not wake: $(cat "$WAKE_LOG")"
[ ! -e "$STATE_DIR/.dead-worker-tmux_win-live" ] || fail "a live agent must leave no dead-worker marker"
pass "dead-worker: a live agent is never a dead worker"

reset_state
mk_meta dw-fresh "tmux:win-fresh"
printf 'working: mid-build\n' > "$STATE_DIR/dw-fresh.status"
(
  fm_backend_agent_alive() { printf 'dead'; }
  fm_dead_worker_reality_check "tmux:win-fresh" dw-fresh "$(window_key "tmux:win-fresh")" ship
) && fail "a too-fresh spawn must never escalate (the worker has not had time to start)"
[ "$(wake_count)" = 0 ] || fail "a too-fresh spawn must not wake"
pass "dead-worker: a fresh spawn gets its grace before a missing process can be dead"

reset_state
mk_meta dw-secondmate "tmux:win-secondmate" "kind=secondmate"
backdate dw-secondmate
printf 'paused: waiting for routed work\n' > "$STATE_DIR/dw-secondmate.status"
(
  fm_backend_agent_alive() { printf 'dead'; }
  fm_dead_worker_reality_check "tmux:win-secondmate" dw-secondmate "$(window_key "tmux:win-secondmate")" secondmate
) && fail "a secondmate must never escalate as a dead worker (its idle pane is healthy by design)"
[ "$(wake_count)" = 0 ] || fail "a secondmate must not wake"
pass "dead-worker: a secondmate endpoint is never a dead worker"

reset_state
mk_meta dw-done "tmux:win-done"
backdate dw-done
printf 'done: PR https://github.com/example/repo/pull/1\n' > "$STATE_DIR/dw-done.status"
(
  fm_backend_agent_alive() { printf 'dead'; }
  fm_dead_worker_reality_check "tmux:win-done" dw-done "$(window_key "tmux:win-done")" ship
) && fail "a task that reported done must never escalate as a dead worker"
[ "$(wake_count)" = 0 ] || fail "a done task must not wake"
pass "dead-worker: a task that reported done is not expected to hold a worker"

# A done-pending-verify worker parks without an agent BY DESIGN (the expected
# parked state of a delivered-but-unconfirmed task), so a dead endpoint on an
# idle machine must never escalate it as a dead worker - exactly like done:.
reset_state
mk_meta dw-dpv "tmux:win-dpv"
backdate dw-dpv
printf 'done-pending-verify: PR offen - CI gruen, KEIN Merge (captain verifies)\n' > "$STATE_DIR/dw-dpv.status"
(
  fm_backend_agent_alive() { printf 'dead'; }
  fm_dead_worker_reality_check "tmux:win-dpv" dw-dpv "$(window_key "tmux:win-dpv")" ship
) && fail "a done-pending-verify worker must never escalate as a dead worker (its agent exiting is expected)"
[ "$(wake_count)" = 0 ] || fail "a done-pending-verify worker must not wake: $(cat "$WAKE_LOG")"
[ ! -e "$STATE_DIR/.dead-worker-tmux_win-dpv" ] || fail "a done-pending-verify worker must leave no dead-worker marker"
pass "dead-worker: a done-pending-verify worker is not a dead worker (expected parked state)"

reset_state
mk_meta dw-unknown "tmux:win-unknown"
backdate dw-unknown
printf 'working: mid-build\n' > "$STATE_DIR/dw-unknown.status"
(
  fm_backend_agent_alive() { printf 'unknown'; }
  fm_backend_target_exists() { return 0; }
  fm_dead_worker_reality_check "tmux:win-unknown" dw-unknown "$(window_key "tmux:win-unknown")" ship
) && fail "an unreadable agent read over an existing endpoint must not escalate (transient, fail-closed)"
[ "$(wake_count)" = 0 ] || fail "an unreadable-but-present endpoint must not wake"
pass "dead-worker: an unreadable agent read over an existing endpoint is fail-closed"

reset_state
mk_meta dw-unknown-gone "tmux:win-unknown-gone"
backdate dw-unknown-gone
printf 'working: mid-build\n' > "$STATE_DIR/dw-unknown-gone.status"
(
  fm_backend_agent_alive() { printf 'unknown'; }
  fm_backend_target_exists() { return 1; }
  fm_dead_worker_reality_check "tmux:win-unknown-gone" dw-unknown-gone "$(window_key "tmux:win-unknown-gone")" ship
)
assert_contains "$(cat "$WAKE_LOG")" "dead worker: dw-unknown-gone" \
  "an endpoint confirmed gone, whatever the agent read, leaves no possible live worker"
pass "dead-worker: an endpoint confirmed gone is a dead worker even when the agent read is unknown"

# --- the core rule: paused: declaration must NOT suppress the escalation ------

reset_state
mk_meta dw-paused "tmux:win-paused"
backdate dw-paused
printf 'paused: waiting for the upstream release\n' > "$STATE_DIR/dw-paused.status"
(
  fm_backend_agent_alive() { printf 'dead'; }
  fm_dead_worker_reality_check "tmux:win-paused" dw-paused "$(window_key "tmux:win-paused")" ship
)
assert_contains "$(cat "$WAKE_LOG")" "dead worker: dw-paused" \
  "a paused: declaration must not suppress the dead-worker escalation"
assert_contains "$(cat "$WAKE_LOG")" "no live process while the machine is idle" \
  "the dead-worker reason must state the reality verdict"
[ -e "$STATE_DIR/.dead-worker-tmux_win-paused" ] || fail "the dead-worker marker must be written after escalation"
pass "dead-worker: a paused: declaration does not suppress the escalation (the captain's reality rule)"

# Idempotency: one escalation per dead stretch, no matter how often the check runs.
(
  fm_backend_agent_alive() { printf 'dead'; }
  fm_dead_worker_reality_check "tmux:win-paused" dw-paused "$(window_key "tmux:win-paused")" ship
) && fail "a second dead-worker verdict must not re-escalate the same stretch"
[ "$(wake_count)" = 1 ] || fail "idempotency: exactly one wake per dead stretch, got $(cat "$WAKE_LOG")"
pass "dead-worker: one escalation per dead stretch (idempotent)"

# A busy machine (load >= 1) never escalates, even with a dead agent.
reset_state
mk_meta dw-busy "tmux:win-busy"
backdate dw-busy
printf 'working: mid-build\n' > "$STATE_DIR/dw-busy.status"
(
  export FM_DEAD_WORKER_LOADAVG=2.50
  fm_backend_agent_alive() { printf 'dead'; }
  fm_dead_worker_reality_check "tmux:win-busy" dw-busy "$(window_key "tmux:win-busy")" ship
) && fail "a busy machine must never escalate a missing process as dead"
[ "$(wake_count)" = 0 ] || fail "a busy machine must not wake"
pass "dead-worker: a busy machine (load >= 1) never escalates"

# Another in-flight task with a live agent also keeps the machine busy.
reset_state
mk_meta dw-target "tmux:win-target"
backdate dw-target
printf 'working: mid-build\n' > "$STATE_DIR/dw-target.status"
mk_meta dw-other "tmux:win-other"
backdate dw-other
printf 'working: mid-build\n' > "$STATE_DIR/dw-other.status"
(
  fm_backend_agent_alive() {
    case "$2" in
      "tmux:win-other") printf 'alive' ;;
      *) printf 'dead' ;;
    esac
  }
  fm_dead_worker_reality_check "tmux:win-target" dw-target "$(window_key "tmux:win-target")" ship
) && fail "another in-flight task with a live agent must keep the machine busy"
[ "$(wake_count)" = 0 ] || fail "a machine with another live worker must not wake"
pass "dead-worker: another live in-flight worker keeps the machine busy"

# Recovery clears the marker: a live agent again ends the dead stretch.
reset_state
mk_meta dw-recover "tmux:win-recover"
backdate dw-recover
printf 'paused: waiting for the upstream release\n' > "$STATE_DIR/dw-recover.status"
(
  fm_backend_agent_alive() { printf 'dead'; }
  fm_dead_worker_reality_check "tmux:win-recover" dw-recover "$(window_key "tmux:win-recover")" ship
)
[ -e "$STATE_DIR/.dead-worker-tmux_win-recover" ] || fail "the dead-worker marker must exist before recovery is proven"
(
  fm_backend_agent_alive() { printf 'alive'; }
  fm_dead_worker_reality_check "tmux:win-recover" dw-recover "$(window_key "tmux:win-recover")" ship
) && fail "a live agent again must never escalate"
[ ! -e "$STATE_DIR/.dead-worker-tmux_win-recover" ] || fail "recovery must clear the dead-worker marker"
[ "$(wake_count)" = 1 ] || fail "recovery must not add a second wake"
pass "dead-worker: recovery clears the marker and ends the dead stretch"

# A done: task clears a stale dead-worker marker too.
reset_state
mk_meta dw-clear "tmux:win-clear"
backdate dw-clear
printf 'paused: waiting for the upstream release\n' > "$STATE_DIR/dw-clear.status"
(
  fm_backend_agent_alive() { printf 'dead'; }
  fm_dead_worker_reality_check "tmux:win-clear" dw-clear "$(window_key "tmux:win-clear")" ship
)
printf 'done: PR https://github.com/example/repo/pull/2\n' > "$STATE_DIR/dw-clear.status"
(
  fm_backend_agent_alive() { printf 'dead'; }
  fm_dead_worker_reality_check "tmux:win-clear" dw-clear "$(window_key "tmux:win-clear")" ship
) && fail "a task that finished must never escalate"
[ ! -e "$STATE_DIR/.dead-worker-tmux_win-clear" ] || fail "a finished task must clear its dead-worker marker"
pass "dead-worker: a finished task clears its dead-worker marker"

# --- the declared-pause absorb path now routes through the reality check ------
# pause_state_class is where a "paused:" line used to disarm the guard. With a
# dead agent on an idle machine it must escalate instead of absorbing.

reset_state
mk_meta pw-paused "tmux:win-pw"
backdate pw-paused
printf 'paused: waiting for the upstream release\n' > "$STATE_DIR/pw-paused.status"
KEY=$(window_key "tmux:win-pw")
touch "$STATE_DIR/.paused-$KEY"
touch "$STATE_DIR/.paused-rechecked-$KEY"
(
  fm_backend_agent_alive() { printf 'dead'; }
  pause_state_class "tmux:win-pw" pw-paused > /dev/null
)
assert_contains "$(cat "$WAKE_LOG")" "dead worker: pw-paused" \
  "the declared-pause absorb path must escalate a dead worker on an idle machine"
pass "dead-worker: the declared-pause absorb path escalates a dead agent on an idle machine"

reset_state
mk_meta pw-busy "tmux:win-pw2"
backdate pw-busy
printf 'paused: waiting for the upstream release\n' > "$STATE_DIR/pw-busy.status"
KEY=$(window_key "tmux:win-pw2")
touch "$STATE_DIR/.paused-$KEY"
touch "$STATE_DIR/.paused-rechecked-$KEY"
(
  export FM_DEAD_WORKER_LOADAVG=2.50
  fm_backend_agent_alive() { printf 'dead'; }
  pause_state_class "tmux:win-pw2" pw-busy > /dev/null
)
[ "$(wake_count)" = 0 ] || fail "the declared-pause absorb must hold on a busy machine: $(cat "$WAKE_LOG")"
pass "dead-worker: the declared-pause absorb still holds on a busy machine"

# --- real processes, real tmux: the endpoint-liveness signal drives the rule --
# A real tmux server on a private socket and a real long-running process named
# like a harness. Killed, the window is gone with the process - the pc-316
# shape - and the rule must escalate despite the paused: declaration.
if command -v tmux >/dev/null 2>&1 && [ -n "$SLEEP_BIN" ]; then
  REAL_TMUX=$(command -v tmux)
  SOCKET="fm-deadworker-$$"
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-deadworker.XXXXXX")
  SESSION=dwtest

  # A `tmux` shim on PATH so bin/backends/tmux.sh's bare `tmux` calls reach the
  # private socket and never touch the host's real sessions.
  mkdir -p "$LAB/shim"
  cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
  chmod +x "$LAB/shim/tmux"
  PATH="$LAB/shim:$PATH"
  export PATH

  # Stand-in "harness" binary: a symlink to a real long-running system binary,
  # whose symlink name is what the kernel records as the executable identity.
  ln -s "$SLEEP_BIN" "$LAB/claude"

  fm_backend_source tmux || fail "fm_backend_source tmux failed"

  "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n idle -c "$TMP" \
    || fail "could not start the private tmux server"

  wait_alive() {  # <target> <expected> [tries]
    local target=$1 expected=$2 tries=${3:-100} got i=0
    while [ "$i" -lt "$tries" ]; do
      got=$(fm_backend_agent_alive tmux "$target")
      [ "$got" = "$expected" ] && return 0
      sleep 0.1
      i=$((i + 1))
    done
    printf 'last verdict for %s was %s (expected %s)\n' "$target" "${got:-<none>}" "$expected" >&2
    return 1
  }

  reset_state
  mk_meta dw-real "dwtest:live"
  backdate dw-real
  printf 'paused: waiting for the upstream release\n' > "$STATE_DIR/dw-real.status"
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n live -c "$TMP" -- "$LAB/claude" 900 \
    || fail "could not create the live window"
  wait_alive "dwtest:live" alive || fail "the live harness-named process must classify alive"
  fm_dead_worker_reality_check "dwtest:live" dw-real "$(window_key "dwtest:live")" ship \
    && fail "a live real worker must never escalate as dead"
  [ "$(wake_count)" = 0 ] || fail "a live real worker must not wake"
  pass "dead-worker (real): a live real worker is never a dead worker"

  # The OOM shape: the worker's window is killed, gone together with the process.
  KLOG="$TMP/real-oom-log.sh"
  klog "$KLOG" \
    "Jun 6 03:50:01 host kernel: Out of memory: Killed process 1234 (dev-server) total-vm:1400000kB, anon-rss:1200000kB, UID:1000" \
    "Jun 6 03:50:01 host kernel: Task in /system.slice/tmux-spawn-1234.scope killed as a result of limit of /system.slice/tmux-spawn-1234.scope"
  "$REAL_TMUX" -L "$SOCKET" kill-window -t "$SESSION:live" \
    || fail "could not kill the live window"
  wait_alive "dwtest:live" dead || fail "the killed window must classify dead/missing"
  FM_DEAD_WORKER_KERNEL_LOG="$KLOG" \
    fm_dead_worker_reality_check "dwtest:live" dw-real "$(window_key "dwtest:live")" ship
  assert_contains "$(cat "$WAKE_LOG")" "dead worker: dw-real" \
    "a real window killed along with its process must escalate as a dead worker"
  assert_contains "$(cat "$WAKE_LOG")" "no live process while the machine is idle" \
    "the real dead-worker reason must state the reality verdict"
  assert_contains "$(cat "$WAKE_LOG")" "kernel OOM-killed the worker process (dev-server)" \
    "the real dead-worker reason must carry the kernel OOM evidence"
  [ -e "$STATE_DIR/.dead-worker-dwtest_live" ] || fail "the real dead-worker marker must be written"
  FM_DEAD_WORKER_KERNEL_LOG="$KLOG" \
    fm_dead_worker_reality_check "dwtest:live" dw-real "$(window_key "dwtest:live")" ship \
    && fail "the real dead-worker verdict must be idempotent"
  [ "$(wake_count)" = 1 ] || fail "the real dead-worker stretch must wake exactly once"
  pass "dead-worker (real): a window killed with its process escalates as a dead worker, with OOM evidence, once"

  # A busy machine still holds: a second killed window on a busy load must not
  # escalate (its own marker is absent, so this is not idempotency masking).
  reset_state
  mk_meta dw-real2 "dwtest:live2"
  backdate dw-real2
  printf 'working: mid-build\n' > "$STATE_DIR/dw-real2.status"
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n live2 -c "$TMP" -- "$LAB/claude" 900 \
    || fail "could not create the second live window"
  wait_alive "dwtest:live2" alive || fail "the second live process must classify alive"
  "$REAL_TMUX" -L "$SOCKET" kill-window -t "$SESSION:live2" \
    || fail "could not kill the second window"
  wait_alive "dwtest:live2" dead || fail "the second killed window must classify dead/missing"
  ( export FM_DEAD_WORKER_LOADAVG=2.50
    fm_dead_worker_reality_check "dwtest:live2" dw-real2 "$(window_key "dwtest:live2")" ship ) \
    && fail "a busy real machine must never escalate a killed window"
  [ "$(wake_count)" = 0 ] || fail "a busy real machine must not wake"
  pass "dead-worker (real): a busy machine never escalates a killed real window"

  # Recovery: the window comes back with a live process and the marker clears.
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n live -c "$TMP" -- "$LAB/claude" 900 \
    || fail "could not recreate the live window"
  wait_alive "dwtest:live" alive || fail "the recreated live process must classify alive"
  fm_dead_worker_reality_check "dwtest:live" dw-real "$(window_key "dwtest:live")" ship \
    && fail "a recreated live real worker must never escalate"
  [ ! -e "$STATE_DIR/.dead-worker-dwtest_live" ] || fail "real recovery must clear the dead-worker marker"
  pass "dead-worker (real): a recreated live worker clears the marker and ends the dead stretch"

  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
else
  echo "skip: tmux or sleep not found, so the real-process dead-worker cases do not run here"
fi

echo "# fm-watch-dead-worker.test.sh: all assertions passed"
