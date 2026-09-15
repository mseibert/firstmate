#!/usr/bin/env bash
# Manual end-to-end verification of the remote-job worker ownership fix.
#
# Exercises the end-user surface: a wedged account queue (a dead owner record
# plus a quarantine publish temp left by an untrapped kill), worker startup as
# the supervisor/doctor runs it, a real queued job through the public stage/wait
# API, and a competing second generation that must not displace the live owner.
set -u

REPO=/home/martin_seibert/.no-mistakes/worktrees/e36b903ea8f4/01M2KE0WCA3MSV8ABEQ418ZH26
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-job-e2e.XXXXXX")
OWNER_PID=
CHALLENGER_PID=
FAILED=0
cleanup() {
  [ -z "$OWNER_PID" ] || kill "$OWNER_PID" 2>/dev/null || true
  [ -z "$CHALLENGER_PID" ] || kill "$CHALLENGER_PID" 2>/dev/null || true
  rm -rf -- "$WORK"
}
trap cleanup EXIT

check() { # <label> <condition-result>
  if [ "$2" -eq 0 ]; then
    printf 'PASS  %s\n' "$1"
  else
    printf 'FAIL  %s\n' "$1"
    FAILED=1
  fi
}

REMOTE_ROOT="$WORK/remote-root"
ACCOUNT_HOME="$WORK/account"
REMOTE_HOME="$WORK/remote-home"
STATE="$WORK/state"
mkdir -p "$REMOTE_ROOT/bin" "$ACCOUNT_HOME" "$REMOTE_HOME" "$STATE/jobs" "$STATE/logs" "$STATE/worker.lock"
chmod 700 "$ACCOUNT_HOME" "$REMOTE_HOME" "$STATE" "$STATE/jobs" "$STATE/logs" "$STATE/worker.lock"
cp "$REPO/bin/fm-remote-job-lib.sh" "$REPO/bin/fm-remote-job-worker.sh" "$REPO/bin/fm-remote-delta-read.sh" "$REMOTE_ROOT/bin/"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
cat > "$REMOTE_ROOT/bin/fm-probe-job.sh" <<'SH'
#!/bin/bash
printf 'probe served: home=%s root=%s\n' "$FM_HOME" "$FM_ROOT_OVERRIDE"
SH
chmod +x "$REMOTE_ROOT/bin"/*.sh
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" commit -qm 'e2e fixture'

export FM_REMOTE_JOB_STATE_ROOT="$STATE"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_REMOTE_JOB_QUEUE_TIMEOUT=15
export FM_REMOTE_JOB_TIMEOUT=15
# shellcheck source=bin/fm-remote-job-lib.sh
. "$REPO/bin/fm-remote-job-lib.sh"

run_worker() { # <out> <err>
  HOME="$ACCOUNT_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
    FM_REMOTE_JOB_STATE_ROOT="$STATE" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --serve > "$1" 2> "$2" &
}

echo "== wedge: an untrapped kill left a dead owner record and a quarantine publish temp =="
sleep 0.01 &
DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
printf '%s\n' "$DEAD_PID" > "$STATE/worker.lock/pid"
printf 'stale-start\n' > "$STATE/worker.lock/start"
printf 'stale-command\n' > "$STATE/worker.lock/command"
printf 'active execution could not be confirmed stopped\n' > "$STATE/worker.lock/.quarantine.deadbeef"
chmod 600 "$STATE/worker.lock"/*
touch -t 200001010000 "$STATE/worker.lock"
printf 'lock dir before start: %s\n' "$(ls -A "$STATE/worker.lock" | sort | tr '\n' ' ')"

echo
echo "== start the worker the way the supervisor/doctor does =="
run_worker "$WORK/owner.out" "$WORK/owner.err"
OWNER_PID=$!
for _ in $(seq 1 400); do
  [ -f "$STATE/worker.ready" ] && break
  sleep 0.05
done
[ -f "$STATE/worker.ready" ]
check "wedged queue reclaimed: worker published its readiness heartbeat" $?
OWNER_SERVE_PID=$(cat "$STATE/worker.pid" 2>/dev/null || true)
printf 'worker.pid=%s lock/pid=%s\n' "$OWNER_SERVE_PID" "$(cat "$STATE/worker.lock/pid" 2>/dev/null || true)"
[ -n "$OWNER_SERVE_PID" ] && [ "$(cat "$STATE/worker.lock/pid" 2>/dev/null || true)" = "$OWNER_SERVE_PID" ]
check "the reclaiming worker published its own ownership record" $?
LEFT=$(ls -A "$STATE/worker.lock" 2>/dev/null | grep '^\.quarantine\.' || true)
[ -z "$LEFT" ]
check "the quarantine publish temp file was cleared from the reclaimed lock" $?

echo
echo "== a real queued job through the public stage/wait API =="
fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-probe-job.sh </dev/null >/dev/null
JOB1=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB1" || { printf 'wait failed: %s\n' "$FM_REMOTE_JOB_ERROR"; FAILED=1; }
printf 'job1 id=%s exit=%s stdout=%s\n' "$JOB1" "${FM_REMOTE_JOB_EXIT:-?}" "$(cat "$FM_REMOTE_JOB_STDOUT" 2>/dev/null || true)"
[ "${FM_REMOTE_JOB_EXIT:-1}" -eq 0 ]
check "the reclaimed queue served a probe job to completion" $?
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB1" || true

echo
echo "== a competing second generation must not displace the live owner =="
run_worker "$WORK/challenger.out" "$WORK/challenger.err"
CHALLENGER_PID=$!
for _ in $(seq 1 200); do
  kill -0 "$CHALLENGER_PID" 2>/dev/null || break
  sleep 0.05
done
if kill -0 "$CHALLENGER_PID" 2>/dev/null; then
  printf 'challenger still running after 10s\n'
  kill -KILL "$CHALLENGER_PID" 2>/dev/null || true
  wait "$CHALLENGER_PID" 2>/dev/null || true
  CHALLENGER_PID=
  check "the challenger exited instead of racing the live owner" 1
else
  wait "$CHALLENGER_PID" 2>/dev/null
  CHALLENGER_RC=$?
  CHALLENGER_PID=
  printf 'challenger exited rc=%s; stderr: %s\n' "$CHALLENGER_RC" "$(head -1 "$WORK/challenger.err" 2>/dev/null || true)"
  [ "$CHALLENGER_RC" -eq 0 ]
  check "the challenger exited instead of racing the live owner" $?
fi
[ "$(cat "$STATE/worker.lock/pid" 2>/dev/null || true)" = "$OWNER_SERVE_PID" ]
check "the live owner kept its ownership record" $?
kill -0 "$OWNER_SERVE_PID" 2>/dev/null
check "the live owner kept serving after the challenger left" $?

fm_remote_job_stage "$ACCOUNT_HOME" "$REMOTE_ROOT" "$REMOTE_HOME" fm-probe-job.sh </dev/null >/dev/null
JOB2=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$ACCOUNT_HOME" "$JOB2" || { printf 'wait failed: %s\n' "$FM_REMOTE_JOB_ERROR"; FAILED=1; }
printf 'job2 id=%s exit=%s stdout=%s\n' "$JOB2" "${FM_REMOTE_JOB_EXIT:-?}" "$(cat "$FM_REMOTE_JOB_STDOUT" 2>/dev/null || true)"
[ "${FM_REMOTE_JOB_EXIT:-1}" -eq 0 ]
check "the surviving owner completed a second job" $?
fm_remote_job_reap "$ACCOUNT_HOME" "$JOB2" || true

echo
echo "== owner shutdown releases the queue =="
kill -TERM "$OWNER_SERVE_PID" 2>/dev/null || true
wait "$OWNER_PID" 2>/dev/null || true
OWNER_PID=
[ ! -e "$STATE/worker.lock" ]
check "the owner released the ownership lock on shutdown" $?

echo
if [ "$FAILED" -eq 0 ]; then
  echo "E2E RESULT: PASS"
else
  echo "E2E RESULT: FAIL"
fi
exit "$FAILED"
