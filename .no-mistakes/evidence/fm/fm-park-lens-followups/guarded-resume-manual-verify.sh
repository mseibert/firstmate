#!/usr/bin/env bash
# Manual end-to-end verification for the park lease-guard follow-up change.
#
# Runs the real bin/fm-park.sh `park` and `resume` in a Pi supervision context
# with the REAL lease guard active and a control-plane child that itself calls
# fm_lease_guard + fm_lease_guard_release for the same task. The child logs
# whether the parent's lease-command lock was still held after the child's own
# release attempt, and this script prints the persisted marker/lock state so the
# transcript shows the end-user behavior directly.
set -u

ROOT=/home/martin_seibert/.no-mistakes/worktrees/e36b903ea8f4/01M2NSSNWP1X81A9N7T6MSAN3E
PARK="$ROOT/bin/fm-park.sh"
home=$(mktemp -d /tmp/fm-park-manual.XXXXXX)
trap 'rm -rf "$home"' EXIT

mkdir -p "$home/state" "$home/data" "$home/config" "$home/fakebin" "$home/wt"
git -C "$home/wt" init -q
printf '# wt\n' > "$home/wt/README.md"
git -C "$home/wt" add README.md
git -C "$home/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$home/wt" checkout -q -b fm/demo

cat > "$home/state/t1.meta" <<EOF
window=firstmate:fm-t1
endpoint_task_id=t1
worktree=$home/wt
project=demo
harness=claude
kind=ship
mode=no-mistakes
yolo=off
spawn_gen=s-t1
pr=https://github.com/example/demo/pull/7
EOF
printf 'done: PR https://github.com/example/demo/pull/7 checks green\n' > "$home/state/t1.status"
printf 'manual\n' > "$home/config/backlog-backend"
printf '%s\n' "$$" > "$home/state/.lock"

cat > "$home/crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'state: done · source: run-step · fixture\n'
SH
chmod +x "$home/crew-state.sh"

cat > "$home/control-guarded.sh" <<SH
#!/usr/bin/env bash
set -eu
ID=\${1:-}
STATE="$home/state"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-lease-lib.sh"
fm_lease_guard "\$ID" "lifecycle control (manual verify)"
fm_lease_guard_release
if [ -e "\$STATE/.fm-lease-command.lock" ]; then
  printf '%s lock=held\n' "\$*" >> "$home/control.log"
else
  printf '%s lock=gone\n' "\$*" >> "$home/control.log"
fi
SH
chmod +x "$home/control-guarded.sh"

run_guarded() {
  timeout 20 env PI_CODING_AGENT=true FM_SUPERVISION_ACTOR=main FM_GATE_REFUSE_BYPASS=1 \
    PATH="$home/fakebin:$PATH" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_PARK_CONTROL_BIN="$home/control-guarded.sh" \
    FM_PARK_CREW_STATE_BIN="$home/crew-state.sh" \
    FM_PARK_NOW_EPOCH=1700000000 FM_TASKS_AXI_COMPATIBLE=1 \
    FM_FAKE_CONTROL_LOG="$home/control.log" FM_FAKE_CONTROL_RC=0 \
    FM_FAKE_CREW_STATE=done FM_FAKE_CREW_SOURCE=run-step FM_FAKE_CREW_DETAIL=fixture \
    "$PARK" "$@"
}

fail=0
check() {  # <description> <condition-cmd...>
  local label=$1
  shift
  if "$@"; then
    printf 'PASS: %s\n' "$label"
  else
    printf 'FAIL: %s\n' "$label"
    fail=1
  fi
}

printf '=== 1. guarded park: real lease guard held by the fm-park parent ===\n'
out=$(run_guarded park t1 2>&1); rc=$?
printf 'exit=%s\n%s\n' "$rc" "$out"
check "park exits 0" test "$rc" -eq 0
case "$out" in *"parked t1 reason=merge"*) printf 'PASS: park reported the release\n' ;; *) printf 'FAIL: park did not report the release\n'; fail=1 ;; esac

printf '\n--- control.log (child ran with the parent lock held?) ---\n'
cat "$home/control.log"
grep -qxF 't1 exit lock=held' "$home/control.log" \
  && printf 'PASS: child observed the parent lock still held after its own release attempt\n' \
  || { printf 'FAIL: child dropped the parent lock or did not run under it\n'; fail=1; }
[ ! -e "$home/state/.fm-lease-command.lock" ] \
  && printf 'PASS: parent released the guard lock after park\n' \
  || { printf 'FAIL: guard lock left behind after park\n'; fail=1; }

printf '\n--- persisted marker after park ---\n'
cat "$home/state/t1.parked"
grep -q '^state=released$' "$home/state/t1.parked" \
  && printf 'PASS: marker committed state=released\n' \
  || { printf 'FAIL: marker did not commit the release\n'; fail=1; }

printf '\n=== 2. guarded resume: same deadlock fix pinned for resume ===\n'
out=$(run_guarded resume t1 --reason merge 2>&1); rc=$?
printf 'exit=%s\n%s\n' "$rc" "$out"
check "resume exits 0 (no guard deadlock)" test "$rc" -eq 0
case "$out" in *"resumed t1 reason=merge"*) printf 'PASS: resume reported the task\n' ;; *) printf 'FAIL: resume did not report the task\n'; fail=1 ;; esac

printf '\n--- control.log (both guarded children) ---\n'
cat "$home/control.log"
grep -q 't1 relaunch --note.*lock=held' "$home/control.log" \
  && printf 'PASS: resume child ran under the parent lock and could not drop it\n' \
  || { printf 'FAIL: resume child did not run under the parent lock\n'; fail=1; }
[ ! -e "$home/state/t1.parked" ] \
  && printf 'PASS: resume removed the marker\n' \
  || { printf 'FAIL: resume left the marker behind\n'; fail=1; }
[ ! -e "$home/state/.fm-lease-command.lock" ] \
  && printf 'PASS: parent released the guard lock after resume\n' \
  || { printf 'FAIL: guard lock left behind after resume\n'; fail=1; }

printf '\n=== result: %s ===\n' "$([ "$fail" -eq 0 ] && echo ALL CHECKS PASSED || echo CHECKS FAILED)"
exit "$fail"
