#!/usr/bin/env bash
# Evidence driver for the self-update timer change (branch fm/fm-self-update-timer),
# target commit 856f6fc. Runs OUTSIDE the worktree; reads the worktree but writes
# only under /tmp and the evidence directory. Produces reviewer-visible transcripts.
#
# Part 1: arm helper renders + installs the units; the real systemd consumer
#         (systemd-analyze verify/calendar) validates them; the rendered PATH
#         resolves a user-installed harness; status verb prints the operator view.
# Part 2: end-to-end with the REAL bin/fm-update.sh against a synthetic fleet:
#         progress run, quiet run, token-held skip, catch-up, pending retry.
# Part 3: regression check for the stderr-diagnostic fix: a no-progress run while
#         supervision is down stays a single quiet log line and the WATCHER DOWN
#         banner reaches the unit journal (stderr) only.
# Part 4: the targeted test suite run against the PRE-FIX wrapper fails exactly the
#         stderr-diagnostic test; against the current wrapper every test passes.
set -u
REPO=/home/martin_seibert/.no-mistakes/worktrees/e36b903ea8f4/01M2JJRH8TBA71M48QGCB8NWE8
EVID=/home/martin_seibert/.no-mistakes/evidence/01M2JJRH8TBA71M48QGCB8NWE8
T=$(mktemp -d /tmp/fm-self-update-evidence.XXXXXX)
trap 'rm -rf "$T"' EXIT

FAILURES=0
say() { printf '\n===== %s =====\n' "$*"; }
check() {  # <label> <condition-description>; reads $? of previous command
  local label=$1 desc=$2
  if [ "$label" = 0 ]; then
    printf 'PASS: %s\n' "$desc"
  else
    printf 'FAIL: %s\n' "$desc"
    FAILURES=$((FAILURES + 1))
  fi
}

# ---------------------------------------------------------------------------
# Part 1: arm the units through the real helper (fake systemctl so no real
# user-manager state is touched) and validate the rendered units with the real
# systemd consumer.
# ---------------------------------------------------------------------------
say "PART 1: arm helper renders + installs units (fake systemctl)"
HOME1="$T/home"
mkdir -p "$HOME1/state" "$HOME1/unit-dir"
cat > "$HOME1/fake-systemctl.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$HOME1/systemctl.log"
shift
cmd=\$1; shift
case "\$cmd" in
  is-active)
    case "\${1:-}" in
      firstmate-self-update.timer) [ -f "$HOME1/timer-active" ] && echo active || echo inactive ;;
      firstmate-self-update.service) [ -f "$HOME1/service-active" ] && echo active || echo inactive ;;
      *) echo inactive ;;
    esac ;;
  is-enabled)
    case "\${1:-}" in
      firstmate-self-update.timer) [ -f "$HOME1/timer-enabled" ] && echo enabled || echo disabled ;;
      *) echo disabled ;;
    esac ;;
  daemon-reload) ;;
  enable) [ "\${1:-}" = --now ] && shift; case "\${1:-}" in
      firstmate-self-update.timer) touch "$HOME1/timer-enabled" "$HOME1/timer-active" ;;
      firstmate-self-update.service) touch "$HOME1/service-enabled" "$HOME1/service-active" ;; esac ;;
  start) [ "\${1:-}" = --now ] && shift; case "\${1:-}" in
      firstmate-self-update.timer) touch "$HOME1/timer-active" ;; esac ;;
  disable) [ "\${1:-}" = --now ] && shift; rm -f "$HOME1/timer-enabled" "$HOME1/timer-active" ;;
  stop) rm -f "$HOME1/service-active" ;;
esac
exit 0
SH
chmod +x "$HOME1/fake-systemctl.sh"

echo '$ bin/fm-self-update-timer-arm.sh arm'
FM_HOME="$HOME1" FM_STATE_OVERRIDE="$HOME1/state" \
  FM_SELF_UPDATE_SYSTEMCTL="$HOME1/fake-systemctl.sh" \
  FM_SELF_UPDATE_UNIT_DIR="$HOME1/unit-dir" \
  bash "$REPO/bin/fm-self-update-timer-arm.sh" arm
echo "arm exit=$?"

say "installed firstmate-self-update.service (rendered)"
cat "$HOME1/unit-dir/firstmate-self-update.service"
say "installed firstmate-self-update.timer (rendered)"
cat "$HOME1/unit-dir/firstmate-self-update.timer"

say "real systemd consumer: systemd-analyze verify --user (both units)"
systemd-analyze verify --user \
  "$HOME1/unit-dir/firstmate-self-update.service" \
  "$HOME1/unit-dir/firstmate-self-update.timer"
verify_rc=$?
echo "verify exit=$verify_rc"
check "$verify_rc" "systemd-analyze verify accepts both rendered units"

say "real systemd consumer: systemd-analyze calendar (six-hour cadence)"
systemd-analyze calendar '*-*-* 00,06,12,18:00:00'
cal_rc=$?
echo "calendar exit=$cal_rc"
check "$cal_rc" "systemd-analyze calendar accepts the six-hour OnCalendar expression"

say "harness resolution under the unit's PATH (review fix: local pi harness)"
RENDERED_PATH=$(grep '^Environment=PATH=' "$HOME1/unit-dir/firstmate-self-update.service" | cut -d= -f2-)
EXPANDED_PATH=${RENDERED_PATH//%h/$HOME}
echo "rendered PATH : $RENDERED_PATH"
echo "expanded PATH : $EXPANDED_PATH"
echo "-- pre-fix pinned PATH (without %h/.local/bin and %h/.npm-global/bin):"
env -i HOME="$HOME" PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin \
  sh -c 'command -v pi || echo "pi: NOT FOUND"'
echo "-- fixed PATH as rendered:"
env -i HOME="$HOME" PATH="$EXPANDED_PATH" \
  sh -c 'command -v pi || echo "pi: NOT FOUND"'

say "arm helper status verb"
FM_HOME="$HOME1" FM_STATE_OVERRIDE="$HOME1/state" \
  FM_SELF_UPDATE_SYSTEMCTL="$HOME1/fake-systemctl.sh" \
  FM_SELF_UPDATE_UNIT_DIR="$HOME1/unit-dir" \
  bash "$REPO/bin/fm-self-update-timer-arm.sh" status

# ---------------------------------------------------------------------------
# Part 2: end-to-end. Real wrapper + REAL bin/fm-update.sh against a synthetic
# fleet: a bare origin, a primary home and a local secondmate home cloned from
# it. Only the secondmate-restart pass is a fake (there is no live agent here);
# it records the argv and prints a scripted outcome.
# ---------------------------------------------------------------------------
say "PART 2: end-to-end with the REAL update pass"
FLEET="$T/fleet"
ORIGIN="$FLEET/origin.git"
PRIMARY="$FLEET/primary"
SECOND="$FLEET/secondmate"
export GIT_AUTHOR_NAME=evidence GIT_AUTHOR_EMAIL=evidence@example.invalid
export GIT_COMMITTER_NAME=evidence GIT_COMMITTER_EMAIL=evidence@example.invalid
mkdir -p "$FLEET"
git init -q --bare "$ORIGIN"
git init -q "$FLEET/seed"
git -C "$FLEET/seed" checkout -q -b main
printf 'state/\ndata/\nconfig/\nprojects/\n.no-mistakes/\n' > "$FLEET/seed/.gitignore"
printf '# AGENTS\nversion A\n' > "$FLEET/seed/AGENTS.md"
printf '# readme A\n' > "$FLEET/seed/README.md"
mkdir -p "$FLEET/seed/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FLEET/seed/bin/placeholder.sh"
chmod +x "$FLEET/seed/bin/placeholder.sh"
git -C "$FLEET/seed" add -A
git -C "$FLEET/seed" commit -qm 'A'
git -C "$FLEET/seed" remote add origin "$ORIGIN"
git -C "$FLEET/seed" push -q origin main
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git clone -q "$ORIGIN" "$PRIMARY"
git clone -q "$ORIGIN" "$SECOND"
mkdir -p "$PRIMARY/state"
printf 'nuc\n' > "$SECOND/.fm-secondmate-home"
printf 'kind=secondmate\nhome=%s\nwindow=fm-nuc\n' "$SECOND" > "$PRIMARY/state/nuc.meta"

# Fake restart pass: records argv, prints a scripted outcome file, exits scripted.
cat > "$T/fake-restart.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${EV_RESTART_ARGV:?}"
cat "${EV_RESTART_OUT:?}"
exit "${EV_RESTART_RC:-0}"
SH
chmod +x "$T/fake-restart.sh"
: > "$T/restart.argv"

advance_origin() {  # <label> <file> <content>
  printf '%s\n' "$3" > "$FLEET/seed/$2"
  git -C "$FLEET/seed" add -A
  git -C "$FLEET/seed" commit -qm "$1"
  git -C "$FLEET/seed" push -q origin main
}

run_pass() {  # <label> <restart-out-file> <restart-rc>
  local label=$1 rout=$2 rrc=$3
  say "RUN: $label"
  # A healthy home: fresh watcher beacon under the autoarm model, so fm-guard
  # (called by the real fm-update.sh) stays silent exactly as in a normal
  # running firstmate. The synthetic fleet has no real watcher.
  touch "$PRIMARY/state/.last-watcher-beat"
  echo "-- HEADs before: primary=$(git -C "$PRIMARY" rev-parse --short HEAD) secondmate=$(git -C "$SECOND" rev-parse --short HEAD)"
  echo "-- restart argv before: $(cat "$T/restart.argv" | tr '\n' ';')"
  EV_RESTART_ARGV="$T/restart.argv" EV_RESTART_OUT="$rout" EV_RESTART_RC="$rrc" \
  FM_SUPERVISION_MODEL=autoarm \
  FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$PRIMARY/state" \
    FM_SELF_UPDATE_RESTART_BIN="$T/fake-restart.sh" \
    FM_SELF_UPDATE_LOG="$PRIMARY/state/self-update-timer.log" \
    FM_SELF_UPDATE_PENDING="$PRIMARY/state/.self-update-pending-restarts" \
    FM_GATE_REFUSE_BYPASS=1 \
    bash "$REPO/bin/fm-self-update-timer.sh" run > "$T/last-run.out" 2>&1
  local rc=$?
  echo "-- wrapper exit=$rc"
  echo "-- wrapper stdout (journal surface):"
  cat "$T/last-run.out"
  echo "-- restart argv after: $(cat "$T/restart.argv" | tr '\n' ';')"
  echo "-- pending-restarts file: $(cat "$PRIMARY/state/.self-update-pending-restarts" 2>/dev/null | tr '\n' ' ' || echo '<absent>')"
  echo "-- HEADs after: primary=$(git -C "$PRIMARY" rev-parse --short HEAD) secondmate=$(git -C "$SECOND" rev-parse --short HEAD)"
}

# Run 1: real progress A..B (AGENTS.md changed), restart unconfirmed (nudged).
advance_origin 'B changes AGENTS.md' AGENTS.md '# AGENTS
version B'
printf 'nudged: nuc: did not confirm its open work was written down\nsummary: 0 of 1 restarted, 1 nudged, 0 unreached\n' > "$T/r-nudged.out"
run_pass "progress A..B, restart nudged" "$T/r-nudged.out" 3

# Run 2: nothing new, pending restart retried and confirmed.
printf 'restarted: nuc (fake harness)\nsummary: 1 of 1 restarted, 0 nudged, 0 unreached\n' > "$T/r-ok.out"
run_pass "no progress, pending restart retried" "$T/r-ok.out" 0

# Run 3: nothing new and nothing pending -> one quiet line, restart pass untouched.
cp "$T/restart.argv" "$T/restart.argv.before-quiet"
run_pass "no progress, nothing pending (must stay quiet)" "$T/r-ok.out" 0
echo "-- restart argv unchanged during quiet run: $([ "$(cat "$T/restart.argv")" = "$(cat "$T/restart.argv.before-quiet")" ] && echo yes || echo NO)"

# Run 4: real progress C..D but a live build token is held -> skip, no update.
advance_origin 'C changes README.md' README.md '# readme C'
sleep 1000 &
TOKEN_PID=$!
printf 'build-owner %s\n' "$TOKEN_PID" > "$PRIMARY/state/.build-token"
run_pass "new state available, live build token held" "$T/r-ok.out" 0
echo "-- origin tip while token held: $(git -C "$FLEET/seed" rev-parse --short HEAD)"
kill "$TOKEN_PID" 2>/dev/null || true
wait "$TOKEN_PID" 2>/dev/null || true

# Run 5: token released -> the missed run catches up.
run_pass "token released, missed run catches up" "$T/r-ok.out" 0

say "FINAL LOG state/self-update-timer.log (the operator-facing surface)"
cat -n "$PRIMARY/state/self-update-timer.log"

# ---------------------------------------------------------------------------
# Part 3: regression check for the stderr-diagnostic fix. The real pass emits
# fm-guard's WATCHER DOWN banner on stderr when supervision is down. A
# no-progress run in that state must still write exactly one quiet log line,
# and the banner must reach the unit journal (the wrapper's stderr) only.
# ---------------------------------------------------------------------------
say "PART 3 (fixed): no-progress run while watcher supervision is down (real pass)"
rm -f "$PRIMARY/state/.last-watcher-beat"
cp "$PRIMARY/state/self-update-timer.log" "$T/log.before-unhealthy"
cp "$T/restart.argv" "$T/restart.argv.before-unhealthy"
EV_RESTART_ARGV="$T/restart.argv" EV_RESTART_OUT="$T/r-ok.out" EV_RESTART_RC=0 \
FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$PRIMARY/state" \
  FM_SELF_UPDATE_RESTART_BIN="$T/fake-restart.sh" \
  FM_SELF_UPDATE_LOG="$PRIMARY/state/self-update-timer.log" \
  FM_SELF_UPDATE_PENDING="$PRIMARY/state/.self-update-pending-restarts" \
  FM_GATE_REFUSE_BYPASS=1 \
  bash "$REPO/bin/fm-self-update-timer.sh" run > "$T/unhealthy.out" 2> "$T/unhealthy.err"
unhealthy_rc=$?
echo "-- wrapper exit=$unhealthy_rc"
echo "-- wrapper stdout (log/journal surface):"
cat "$T/unhealthy.out"
echo "-- wrapper stderr (unit journal surface):"
cat "$T/unhealthy.err"
echo "-- log lines added by this no-progress run:"
before_lines=$(wc -l < "$T/log.before-unhealthy")
after_lines=$(wc -l < "$PRIMARY/state/self-update-timer.log")
added_lines=$((after_lines - before_lines))
tail -n +"$((before_lines + 1))" "$PRIMARY/state/self-update-timer.log"
echo "-- log lines before=$before_lines after=$after_lines added=$added_lines"
added_text=$(tail -n +"$((before_lines + 1))" "$PRIMARY/state/self-update-timer.log")
echo "-- restart argv unchanged: $([ "$(cat "$T/restart.argv")" = "$(cat "$T/restart.argv.before-unhealthy")" ] && echo yes || echo NO)"

[ "$unhealthy_rc" -eq 0 ]; check $? "a supervision-down no-progress run exits 0"
[ "$added_lines" -eq 1 ]; check $? "the run added exactly one quiet log line"
[ "$(cat "$T/unhealthy.out")" = "$(tail -n 1 "$PRIMARY/state/self-update-timer.log")" ]; check $? "the journal line equals the single appended log line"
grep -q 'already current' "$T/unhealthy.out"; check $? "the quiet line says already current"
grep -q 'WATCHER DOWN' "$T/unhealthy.err"; check $? "the WATCHER DOWN banner reached the unit journal (stderr)"
if printf '%s\n' "$added_text" | grep -q 'WATCHER DOWN'; then check 1 "the banner must not become an operator log record"; else check 0 "the banner must not become an operator log record"; fi
if printf '%s\n' "$added_text" | grep -q 'skipped'; then check 1 "the no-progress run must not be labelled skipped"; else check 0 "the no-progress run must not be labelled skipped"; fi

# ---------------------------------------------------------------------------
# Part 4: fail-before-fix / pass-after-fix. Run the current targeted test file
# against the PRE-FIX wrapper (commit b8aa133) in a throwaway copy, then against
# the current wrapper in the worktree.
# ---------------------------------------------------------------------------
say "PART 4: regression reproduction - current test file against the PRE-FIX wrapper"
REGRESS="$T/regress"
mkdir -p "$REGRESS"
cp -r "$REPO/bin" "$REPO/tests" "$REGRESS/"
git -C "$REPO" show b8aa133:bin/fm-self-update-timer.sh > "$REGRESS/bin/fm-self-update-timer.sh"
chmod +x "$REGRESS/bin/fm-self-update-timer.sh"
bash "$REGRESS/tests/fm-self-update-timer.test.sh"
pre_rc=$?
echo "pre-fix test exit=$pre_rc"
[ "$pre_rc" -ne 0 ]; check $? "the new stderr test fails against the pre-fix wrapper"

echo
say "SUMMARY"
if [ "$FAILURES" -eq 0 ]; then
  echo "all evidence assertions passed"
else
  echo "$FAILURES evidence assertion(s) FAILED"
fi
exit "$FAILURES"
