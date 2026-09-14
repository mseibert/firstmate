#!/usr/bin/env bash
# tests/fm-backlog-readcheck.test.sh - behavior tests for
# bin/fm-backlog-readcheck.sh, the read-only read-time backlog reconciliation.
#
# Coverage:
#   - STALE_INFLIGHT for a terminal In-flight row whose recorded endpoint is
#     authoritatively gone, and silence for a live endpoint, a nonterminal row,
#     a row with no task record, and a terminal row that never existed
#   - endpoint liveness is not PID-based: a live recorded PID does not mask a
#     gone endpoint
#   - SHARED_SLOT for two terminal task records on one worktree, including a
#     trailing-slash spelling of the same path, and silence when one record is
#     still active
#   - --digest bounding, its disclosed remainder, and the (none) clean output
#   - --api mismatch reporting for GitHub and Forgejo, a matching claim, skips
#     with their reason, and the check bound
#   - the run leaves every file under the home byte-identical
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

READCHECK="$ROOT/bin/fm-backlog-readcheck.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-backlog-readcheck-tests)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

# --- world builders ----------------------------------------------------------

# new_world <name>: a home with state/, data/, and a fakebin. Echoes
# "<home>|<fakebin>".
new_world() {
  local name=$1 w home fakebin
  w="$TMP_ROOT/$name"
  home="$w/home"
  fakebin="$w/fakebin"
  mkdir -p "$home/state" "$home/data" "$fakebin"
  printf '%s|%s\n' "$home" "$fakebin"
}

# run_readcheck <home> <fakebin> [args...]: invoke the real script against the
# fixture home with the fakebin ahead of the host PATH.
run_readcheck() {
  local home=$1 fakebin=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    PATH="$fakebin:$BASE_PATH" "$READCHECK" "$@"
}

# make_fake_tmux <fakebin> <live-target>: a tmux boundary that reports exactly
# one live window. list-windows omits any other window, which is the recovery
# classifier's positive `missing`; display-message answers an agent name for
# the live target and a shell name for any other target.
make_fake_tmux() {
  local fakebin=$1 live=$2
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
live='$live'
target=''
format=''
prev=''
for a in "\$@"; do
  [ "\$prev" = '-t' ] && target="\$a"
  prev="\$a"
  case "\$a" in '#{'*) format="\$a" ;; esac
done
case "\${1:-}" in
  list-windows)
    printf 'main\n'
    [ -n "\$live" ] && printf '%s\n' "\${live#*:}"
    exit 0
    ;;
  display-message)
    case "\$format" in
      *pane_current_command*)
        if [ "\$target" = "\$live" ]; then printf 'claude\n'; else printf 'zsh\n'; fi
        ;;
      *pane_tty*)
        [ "\$target" = "\$live" ] && printf '/dev/pts/99\n' || exit 1
        ;;
      *)
        [ "\$target" = "\$live" ] && printf '%%1\n' || exit 1
        ;;
    esac
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
}

# write_backlog_in_flight <home> <id...>: a backlog whose In flight section
# lists exactly the given ids.
write_backlog_in_flight() {
  local home=$1 id
  shift
  {
    printf '# Backlog\n\n## In flight\n'
    for id in "$@"; do
      printf -- '- [ ] %s - test item\n' "$id"
    done
    printf '\n## Queued\n'
  } > "$home/data/backlog.md"
}

# write_meta <home> <id> <window> [extra=value...]
write_meta() {
  local home=$1 id=$2 window=$3 kv
  shift 3
  {
    printf 'window=%s\n' "$window"
    printf 'kind=ship\n'
    for kv in "$@"; do
      printf '%s\n' "$kv"
    done
  } > "$home/state/$id.meta"
}

# --- stale in-flight ---------------------------------------------------------

test_terminal_dead_endpoint_reports_stale() {
  local rec home fakebin out
  rec=$(new_world stale)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_fake_tmux "$fakebin" "fm-sess:live"
  write_backlog_in_flight "$home" stale-1
  write_meta "$home" stale-1 "fm-sess:gone"
  printf 'done: PR https://example.invalid/x\n' > "$home/state/stale-1.status"

  out=$(run_readcheck "$home" "$fakebin")
  assert_contains "$out" "STALE_INFLIGHT: stale-1 (done)" \
    "a terminal In-flight row with a gone endpoint was not reported"

  pass "a terminal In-flight row with a gone endpoint reports STALE_INFLIGHT"
}

test_live_endpoint_and_nonterminal_rows_stay_silent() {
  local rec home fakebin out
  rec=$(new_world silent)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_fake_tmux "$fakebin" "fm-sess:live"
  write_backlog_in_flight "$home" live-1 working-1 orphan-1
  write_meta "$home" live-1 "fm-sess:live"
  printf 'done: PR https://example.invalid/x\n' > "$home/state/live-1.status"
  write_meta "$home" working-1 "fm-sess:gone"
  printf 'working: still at it\n' > "$home/state/working-1.status"
  printf 'done: PR https://example.invalid/y\n' > "$home/state/orphan-1.status"

  out=$(run_readcheck "$home" "$fakebin")
  [ "$out" = "(none)" ] || fail "a live endpoint, a nonterminal row, or a missing task record must not report stale: $out"

  pass "a live endpoint, a nonterminal row, and a missing task record stay silent"
}

test_failed_endpoint_reports_stale() {
  local rec home fakebin out
  rec=$(new_world failed)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_fake_tmux "$fakebin" "fm-sess:live"
  write_backlog_in_flight "$home" broke-1
  write_meta "$home" broke-1 "fm-sess:gone"
  printf 'failed: the build broke\n' > "$home/state/broke-1.status"

  out=$(run_readcheck "$home" "$fakebin")
  assert_contains "$out" "STALE_INFLIGHT: broke-1 (failed)" \
    "a failed In-flight row with a gone endpoint was not reported"

  pass "a failed In-flight row with a gone endpoint reports STALE_INFLIGHT"
}

# Endpoint liveness must never come from a stored PID: after a kernel PID wrap
# a live PID can name an unrelated process. A task record carrying a live PID
# alongside a gone window must still read stale.
test_live_pid_does_not_mask_gone_endpoint() {
  local rec home fakebin out
  rec=$(new_world pid)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_fake_tmux "$fakebin" "fm-sess:live"
  write_backlog_in_flight "$home" pid-1
  write_meta "$home" pid-1 "fm-sess:gone" "endpoint_pid=$$" "endpoint_pid_starttime=1"
  printf 'done: PR https://example.invalid/x\n' > "$home/state/pid-1.status"

  out=$(run_readcheck "$home" "$fakebin")
  assert_contains "$out" "STALE_INFLIGHT: pid-1 (done)" \
    "a live recorded PID masked a gone endpoint; liveness must not be PID-based"

  pass "a live recorded PID never masks a gone endpoint"
}

# --- shared worktree slots ---------------------------------------------------

test_shared_slot_two_terminal_records() {
  local rec home fakebin out
  rec=$(new_world slot)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_fake_tmux "$fakebin" ""
  mkdir -p "$home/wt"
  printf 'worktree=%s\nkind=ship\n' "$home/wt" > "$home/state/slot-a.meta"
  printf 'done: local branch ready\n' > "$home/state/slot-a.status"
  printf 'worktree=%s/\nkind=ship\n' "$home/wt" > "$home/state/slot-b.meta"
  printf 'failed: broke\n' > "$home/state/slot-b.status"

  out=$(run_readcheck "$home" "$fakebin")
  assert_contains "$out" "SHARED_SLOT: slot-a,slot-b share worktree $home/wt" \
    "two terminal records on one worktree (trailing slash included) were not reported"

  pass "two terminal records on one worktree report SHARED_SLOT"
}

test_shared_slot_with_active_record_stays_silent() {
  local rec home fakebin out
  rec=$(new_world slot-active)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_fake_tmux "$fakebin" ""
  mkdir -p "$home/wt"
  printf 'worktree=%s\nkind=ship\n' "$home/wt" > "$home/state/slot-a.meta"
  printf 'done: local branch ready\n' > "$home/state/slot-a.status"
  printf 'worktree=%s\nkind=ship\n' "$home/wt" > "$home/state/slot-b.meta"
  printf 'working: still at it\n' > "$home/state/slot-b.status"

  out=$(run_readcheck "$home" "$fakebin")
  [ "$out" = "(none)" ] || fail "a worktree shared with a still-active record must not report a shared slot: $out"

  pass "a worktree shared with a still-active record stays silent"
}

# --- digest mode -------------------------------------------------------------

test_digest_bounds_findings_and_prints_none() {
  local rec home fakebin out
  rec=$(new_world digest)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_fake_tmux "$fakebin" ""
  write_backlog_in_flight "$home" many-1 many-2 many-3
  local id
  for id in many-1 many-2 many-3; do
    write_meta "$home" "$id" "fm-sess:gone"
    printf 'done: x\n' > "$home/state/$id.status"
  done

  out=$(run_readcheck "$home" "$fakebin" --digest --limit 2)
  assert_contains "$out" "STALE_INFLIGHT: many-1 (done)" "digest bound dropped the first finding"
  assert_contains "$out" "STALE_INFLIGHT: many-2 (done)" "digest bound dropped the second finding"
  assert_not_contains "$out" "STALE_INFLIGHT: many-3 (done)" "digest bound printed past its limit"
  assert_contains "$out" "(1 more finding(s)" "digest bound did not disclose the remainder"

  rm -f "$home/state"/*.meta "$home/state"/*.status
  out=$(run_readcheck "$home" "$fakebin" --digest)
  [ "$out" = "(none)" ] || fail "a clean digest did not print (none): $out"

  pass "digest mode bounds findings, discloses the remainder, and prints (none) when clean"
}

# --- --api -------------------------------------------------------------------

# make_fake_gh <fakebin> <state>: answer `gh pr view` with one state word.
make_fake_gh() {
  local fakebin=$1 state=$2
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' '$state'
exit 0
SH
  chmod +x "$fakebin/gh"
}

write_done_note_backlog() {  # <home> <url>
  local home=$1 url=$2
  {
    printf '# Backlog\n\n## In flight\n\n## Done\n'
    printf -- '- [x] api-1 - note item\n'
    printf '  done-pending-verify: PR %s offen, 11.09.\n' "$url"
  } > "$home/data/backlog.md"
}

test_api_reports_github_mismatch_and_accepts_match() {
  local rec home fakebin out
  rec=$(new_world api-github)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_fake_tmux "$fakebin" ""
  write_done_note_backlog "$home" "https://github.com/o/r/pull/7"
  make_fake_gh "$fakebin" MERGED

  out=$(run_readcheck "$home" "$fakebin" --api)
  assert_contains "$out" \
    "DONE_NOTE_STALE: api-1 https://github.com/o/r/pull/7 (note=open api=merged)" \
    "a done-pending-verify note that disagrees with GitHub was not reported"

  make_fake_gh "$fakebin" OPEN
  out=$(run_readcheck "$home" "$fakebin" --api)
  [ "$out" = "(none)" ] || fail "a note matching the GitHub state must not report: $out"

  pass "--api reports a GitHub mismatch and accepts a matching note"
}

test_api_checks_forgejo_with_token_and_reports_skip() {
  local rec home fakebin out log
  rec=$(new_world api-forgejo)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_fake_tmux "$fakebin" ""
  write_done_note_backlog "$home" "https://forgejo.example.invalid/o/r/pulls/9"
  log="$TMP_ROOT/curl.args"
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > '$log'
printf '{"state":"closed","merged":true,"number":9}\n'
exit 0
SH
  chmod +x "$fakebin/curl"

  out=$(FM_FORGEJO_TOKEN=sekrit run_readcheck "$home" "$fakebin" --api)
  assert_contains "$out" \
    "DONE_NOTE_STALE: api-1 https://forgejo.example.invalid/o/r/pulls/9 (note=open api=merged)" \
    "a done-pending-verify note that disagrees with Forgejo was not reported"
  assert_contains "$(cat "$log")" "Authorization: token sekrit" \
    "the Forgejo API call did not carry the configured token"

  out=$(unset FM_FORGEJO_TOKEN FORGEJO_TOKEN; run_readcheck "$home" "$fakebin" --api)
  assert_contains "$out" "API_SKIP: https://forgejo.example.invalid/o/r/pulls/9 (set FM_FORGEJO_TOKEN" \
    "a Forgejo URL with no token did not disclose the skip"

  pass "--api checks Forgejo with its token and discloses a missing token as a skip"
}

test_api_bounds_network_calls() {
  local rec home fakebin out
  rec=$(new_world api-bound)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_fake_tmux "$fakebin" ""
  {
    printf '# Backlog\n\n## In flight\n\n## Done\n'
    printf -- '- [x] api-1 - note item\n'
    printf '  done-pending-verify: PR https://github.com/o/r/pull/7 offen, 11.09.\n'
    printf -- '- [x] api-2 - second item\n'
    printf '  done-pending-verify: PR https://github.com/o/r/pull/8 offen, 11.09.\n'
  } > "$home/data/backlog.md"
  make_fake_gh "$fakebin" MERGED

  out=$(FM_READCHECK_API_MAX=1 run_readcheck "$home" "$fakebin" --api)
  assert_contains "$out" "DONE_NOTE_STALE: api-1 https://github.com/o/r/pull/7" \
    "the first API check inside the bound was not run"
  assert_contains "$out" "API_SKIP: https://github.com/o/r/pull/8 (API check bound" \
    "the API call bound was not disclosed"

  pass "--api bounds its network calls and discloses the bound"
}

# --- read-only ---------------------------------------------------------------

test_readcheck_mutates_nothing() {
  local rec home fakebin before after
  rec=$(new_world readonly)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  make_fake_tmux "$fakebin" ""
  write_backlog_in_flight "$home" stale-1
  write_meta "$home" stale-1 "fm-sess:gone"
  printf 'done: PR https://example.invalid/x\n' > "$home/state/stale-1.status"

  before=$(cd "$home" && find . -type f | LC_ALL=C sort | xargs cksum)
  run_readcheck "$home" "$fakebin" >/dev/null
  run_readcheck "$home" "$fakebin" --digest >/dev/null
  after=$(cd "$home" && find . -type f | LC_ALL=C sort | xargs cksum)
  [ "$before" = "$after" ] || fail "the read-check changed files under the home"

  pass "the read-check leaves every file under the home byte-identical"
}

test_help_documents_usage() {
  local out
  out=$("$READCHECK" --help)
  assert_contains "$out" "fm-backlog-readcheck.sh [--digest] [--limit N] [--api]" \
    "--help did not print the usage line"

  pass "--help prints the usage line"
}

# --- run ---------------------------------------------------------------------

test_terminal_dead_endpoint_reports_stale
test_live_endpoint_and_nonterminal_rows_stay_silent
test_failed_endpoint_reports_stale
test_live_pid_does_not_mask_gone_endpoint
test_shared_slot_two_terminal_records
test_shared_slot_with_active_record_stays_silent
test_digest_bounds_findings_and_prints_none
test_api_reports_github_mismatch_and_accepts_match
test_api_checks_forgejo_with_token_and_reports_skip
test_api_bounds_network_calls
test_readcheck_mutates_nothing
test_help_documents_usage
