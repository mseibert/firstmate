#!/usr/bin/env bash
# Tests for bin/fm-verdict-wait.sh: the one reader and bounded waiter for PR
# review verdicts on both forges.
#
# The matrix pins the two opposite comment lifecycles that the helper exists to
# reconcile:
#   Forgejo: crabd edits ONE tracking comment in place, so only updated_at
#            carries the verdict. A created_at newer than the head must not be
#            read as fresh, and a created_at older than the head must not be
#            read as stale.
#   GitHub:  the PR Agent posts a fresh comment per run, so the newest
#            seibert-pr-agent comment carrying a **Verdict:** line is the
#            signal.
# It also pins freshness against the head commit time (including a non-UTC
# commit offset), the CI-green requirement and its --no-ci escape, the
# bounded-timeout diagnostics that must name exactly what is missing, the
# exit-code contract, and the safe failure after repeated read errors.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERDICT_WAIT="$ROOT/bin/fm-verdict-wait.sh"
TMP_ROOT=$(fm_test_tmproot fm-verdict-wait-tests)

# make_world <name>: create one case directory with PATH shims for tea and gh
# driven entirely by fixture files, plus a no-op sleep so polling cases finish
# without wall-clock waits. Echoes the case directory.
make_world() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")

  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"

  cat > "$fakebin/tea" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  logins)
    cat "${FAKE_TEA_LOGINS:?}"
    ;;
  api)
    shift
    if [ "${1:-}" = --login ]; then shift 2; fi
    path=${1:-}
    case "$path" in
      */issues/*/comments*)
        if [ -n "${FAKE_TEA_COMMENTS_SEQ:-}" ]; then
          n=0
          [ -f "${FAKE_TEA_COUNTER:?}" ] && n=$(cat "$FAKE_TEA_COUNTER")
          n=$((n + 1))
          printf '%s\n' "$n" > "$FAKE_TEA_COUNTER"
          f="$FAKE_TEA_COMMENTS_SEQ/call-$n.json"
          [ -f "$f" ] || f="$FAKE_TEA_COMMENTS_SEQ/call-last.json"
          cat "$f"
        else
          cat "${FAKE_TEA_COMMENTS:?}"
        fi
        ;;
      */pulls/*)
        cat "${FAKE_TEA_PR:?}"
        ;;
      */git/commits/*)
        cat "${FAKE_TEA_HEAD:?}"
        ;;
      */commits/*/status)
        cat "${FAKE_TEA_STATUS:?}"
        ;;
      */actions/tasks*)
        cat "${FAKE_TEA_TASKS:?}"
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  *)
    exit 1
    ;;
esac
SH
  chmod +x "$fakebin/tea"

  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  api)
    shift
    path=${1:-}
    case "$path" in
      repos/*/issues/*/comments*)
        printf '['
        cat "${FAKE_GH_COMMENTS:?}"
        printf ']'
        ;;
      repos/*/pulls/*)
        cat "${FAKE_GH_PR:?}"
        ;;
      repos/*/commits/*)
        cat "${FAKE_GH_HEAD:?}"
        ;;
      *)
        exit 1
        ;;
    esac
    ;;
  pr)
    cat "${FAKE_GH_CHECKS:?}"
    ;;
  *)
    exit 1
    ;;
esac
SH
  chmod +x "$fakebin/gh"

  printf '%s\n' "$dir"
}

# forgejo_case <name>: a world whose Forgejo login, PR, head, CI, and comments
# fixtures are ready to be overwritten per case. The head commit carries a
# non-UTC offset on purpose: comparing it against the Zulu verdict timestamp is
# exactly where a naive string comparison would go wrong.
forgejo_case() {
  local dir
  dir=$(make_world "$1")
  printf '%s\n' '[{"name":"test","url":"https://forgejo.example.test","default":"true"}]' > "$dir/logins.json"
  printf '%s\n' '{"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"state":"open","merged":false}' > "$dir/pr.json"
  printf '%s\n' '{"commit":{"committer":{"date":"2026-09-09T12:03:44+02:00"}}}' > "$dir/head.json"
  printf '%s\n' '{"state":"success","total_count":2}' > "$dir/status.json"
  printf '%s\n' '{"workflow_runs":[]}' > "$dir/tasks.json"
  printf '[]' > "$dir/comments.json"
  printf '%s\n' "$dir"
}

# github_case <name>: the same world for GitHub, where the head commit time is
# Zulu and CI comes from `gh pr checks`.
github_case() {
  local dir
  dir=$(make_world "$1")
  printf '%s\n' '{"head":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"state":"open","merged":false}' > "$dir/pr.json"
  printf '%s\n' '{"commit":{"committer":{"date":"2026-09-09T10:03:44Z"}}}' > "$dir/head.json"
  printf '%s\n' '[{"bucket":"pass","name":"ci","state":"SUCCESS"}]' > "$dir/checks.json"
  printf '[]' > "$dir/comments.json"
  printf '%s\n' "$dir"
}

# run_case <dir> <args...>: run the helper with this case's fake PATH and
# fixtures; captures stdout in OUT, stderr in ERR, and the exit code in RC.
run_case() {
  local dir=$1 fakebin
  shift
  fakebin="$dir/fakebin"
  OUT=
  ERR=
  RC=0
  OUT=$(PATH="$fakebin:$PATH" \
    FAKE_TEA_LOGINS="$dir/logins.json" \
    FAKE_TEA_PR="$dir/pr.json" \
    FAKE_TEA_HEAD="$dir/head.json" \
    FAKE_TEA_COMMENTS="$dir/comments.json" \
    FAKE_TEA_STATUS="$dir/status.json" \
    FAKE_TEA_TASKS="$dir/tasks.json" \
    FAKE_GH_PR="$dir/pr.json" \
    FAKE_GH_HEAD="$dir/head.json" \
    FAKE_GH_COMMENTS="$dir/comments.json" \
    FAKE_GH_CHECKS="$dir/checks.json" \
    "$VERDICT_WAIT" "$@" 2> "$dir/err.txt") || RC=$?
  ERR=$(cat "$dir/err.txt")
}

forgejo_verdict_comment() {  # <updated-at> <created-at> <body>
  printf '[{"id":1,"user":{"login":"mseibert"},"created_at":"2026-09-09T07:51:01Z","updated_at":"2026-09-09T07:51:01Z","body":"/review"},{"id":2,"user":{"login":"seibert-pr-agent"},"created_at":"%s","updated_at":"%s","body":"%s"}]' "$2" "$1" "$3"
}

test_forgejo_fresh_lgtm_uses_updated_at() {
  local dir
  dir=$(forgejo_case forgejo-fresh)
  forgejo_verdict_comment \
    "2026-09-09T10:45:53Z" "2026-09-09T09:11:07Z" \
    'Reviewed this pull request — **Good to merge (LGTM).** <!-- crabd:tracking -->' > "$dir/comments.json"

  run_case "$dir" "https://forgejo.example.test/group/project/pulls/186" --timeout 0

  expect_code 0 "$RC" "forgejo fresh LGTM"
  assert_contains "$OUT" 'ready: verdict "Good to merge (LGTM)."' \
    "forgejo fresh LGTM must report the verdict"
  assert_contains "$OUT" 'at 2026-09-09T10:45:53Z' \
    "forgejo freshness must come from updated_at"
  assert_contains "$OUT" 'covers head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (2026-09-09T12:03:44+02:00)' \
    "forgejo fresh LGTM must name the covered head and its offset timestamp"
  assert_contains "$OUT" 'ci green' "forgejo fresh LGTM must report green CI"
  pass "forgejo fresh LGTM reads updated_at, not the stale created_at"
}

test_forgejo_created_at_newer_than_head_is_still_stale() {
  local dir
  dir=$(forgejo_case forgejo-created-at-trap)
  # created_at is NEWER than the head (11:00Z > 10:03:44Z) while updated_at is
  # older. A reader that trusts created_at would call this fresh and let a
  # worker proceed on a verdict that predates the head.
  forgejo_verdict_comment \
    "2026-09-09T09:11:07Z" "2026-09-09T11:00:00Z" \
    'Reviewed this pull request — **Good to merge (LGTM).** <!-- crabd:tracking -->' > "$dir/comments.json"

  run_case "$dir" "https://forgejo.example.test/group/project/pulls/186" --timeout 0

  expect_code 1 "$RC" "forgejo created_at trap"
  assert_contains "$OUT" 'the verdict is older than the head' \
    "forgejo must judge freshness by updated_at"
  assert_not_contains "$OUT" 'ready:' "a verdict older than the head must never read ready"
  pass "forgejo created_at newer than the head does not fake a fresh verdict"
}

test_forgejo_in_flight_is_not_a_verdict() {
  local dir
  dir=$(forgejo_case forgejo-in-flight)
  forgejo_verdict_comment \
    "2026-09-09T10:45:53Z" "2026-09-09T09:11:07Z" \
    '**Seibert PR Agent** is reviewing this pull request... <!-- crabd:tracking -->' > "$dir/comments.json"

  run_case "$dir" "https://forgejo.example.test/group/project/pulls/186" --timeout 0

  expect_code 1 "$RC" "forgejo in-flight"
  assert_contains "$OUT" 'no verdict found (crabd review still in progress)' \
    "an in-flight tracking comment is not a verdict"
  pass "forgejo in-flight tracking comment waits instead of reading a verdict"
}

test_forgejo_missing_updated_at_never_falls_back_to_created_at() {
  local dir
  dir=$(forgejo_case forgejo-no-updated)
  # created_at is newer than the head, so a created_at fallback would fake a
  # fresh verdict; updated_at is the only timestamp that may prove freshness.
  printf '%s' '[{"id":1,"user":{"login":"seibert-pr-agent"},"created_at":"2026-09-09T11:00:00Z","body":"Reviewed this pull request — **Good to merge (LGTM).** <!-- crabd:tracking -->"}]' > "$dir/comments.json"

  run_case "$dir" "https://forgejo.example.test/group/project/pulls/186" --timeout 0

  expect_code 1 "$RC" "forgejo missing updated_at"
  assert_contains "$OUT" 'no verdict found (crabd tracking comment has no updated_at)' \
    "a tracking comment without updated_at must not fall back to created_at"
  pass "forgejo tracking comment without updated_at never reads fresh"
}

test_forgejo_unrecognized_review_line() {
  local dir
  dir=$(forgejo_case forgejo-unrecognized)
  forgejo_verdict_comment \
    "2026-09-09T10:45:53Z" "2026-09-09T09:11:07Z" \
    'Reviewed this pull request but could not produce a verdict. <!-- crabd:tracking -->' > "$dir/comments.json"

  run_case "$dir" "https://forgejo.example.test/group/project/pulls/186" --timeout 0

  expect_code 1 "$RC" "forgejo unrecognized review line"
  assert_contains "$OUT" 'no verdict found (unrecognized verdict text: Reviewed this pull request but could not produce a verdict.)' \
    "an unrecognized final review line must be reported with its text"
  pass "forgejo unrecognized review line reports its text"
}

test_forgejo_missing_tracking_comment() {
  local dir
  dir=$(forgejo_case forgejo-no-tracking)
  printf '%s\n' '[{"id":1,"user":{"login":"mseibert"},"created_at":"2026-09-09T07:51:01Z","updated_at":"2026-09-09T07:51:01Z","body":"/review"}]' > "$dir/comments.json"

  run_case "$dir" "https://forgejo.example.test/group/project/pulls/186" --timeout 0

  expect_code 1 "$RC" "forgejo no tracking comment"
  assert_contains "$OUT" 'no verdict found (no crabd tracking comment on the PR)' \
    "a missing tracking comment must be reported as no verdict"
  pass "forgejo without a crabd tracking comment reports no verdict"
}

test_forgejo_blocking_verdict_is_action_required() {
  local dir
  dir=$(forgejo_case forgejo-blocking)
  forgejo_verdict_comment \
    "2026-09-09T10:45:53Z" "2026-09-09T09:11:07Z" \
    'Reviewed this pull request — **Please address the findings before merging.** (1 inline finding) <!-- crabd:tracking -->' > "$dir/comments.json"

  run_case "$dir" "https://forgejo.example.test/group/project/pulls/186" --timeout 0

  expect_code 3 "$RC" "forgejo blocking verdict"
  assert_contains "$OUT" 'action-required: verdict "Please address the findings before merging."' \
    "a blocking verdict must be reported verbatim as action required"
  pass "forgejo blocking verdict exits action-required instead of waiting"
}

test_forgejo_nits_found_is_mergeable() {
  local dir
  dir=$(forgejo_case forgejo-nits)
  forgejo_verdict_comment \
    "2026-09-09T10:45:53Z" "2026-09-09T09:11:07Z" \
    'Reviewed this pull request — **Nits found.** (2 inline findings) <!-- crabd:tracking -->' > "$dir/comments.json"

  run_case "$dir" "https://forgejo.example.test/group/project/pulls/186" --timeout 0

  expect_code 0 "$RC" "forgejo nits found"
  assert_contains "$OUT" 'ready: verdict "Nits found."' \
    "Nits found. is non-blocking and must read ready"
  pass "forgejo Nits found. is mergeable"
}

test_forgejo_pending_ci_blocks_ready_and_no_ci_escapes() {
  local dir
  dir=$(forgejo_case forgejo-pending-ci)
  forgejo_verdict_comment \
    "2026-09-09T10:45:53Z" "2026-09-09T09:11:07Z" \
    'Reviewed this pull request — **Good to merge (LGTM).** <!-- crabd:tracking -->' > "$dir/comments.json"
  printf '%s\n' '{"state":"pending","total_count":1}' > "$dir/status.json"

  run_case "$dir" "https://forgejo.example.test/group/project/pulls/186" --timeout 0

  expect_code 1 "$RC" "forgejo pending CI"
  assert_contains "$OUT" 'ci not green (state=pending) with a fresh verdict' \
    "a fresh verdict with pending CI must name CI as the missing piece"

  run_case "$dir" "https://forgejo.example.test/group/project/pulls/186" --timeout 0 --no-ci

  expect_code 0 "$RC" "forgejo pending CI with --no-ci"
  assert_contains "$OUT" 'ready: verdict "Good to merge (LGTM)."' \
    "--no-ci must accept a fresh verdict without green CI"
  pass "forgejo pending CI blocks readiness and --no-ci escapes it"
}

test_forgejo_red_ci_is_action_required() {
  local dir
  dir=$(forgejo_case forgejo-red-ci)
  forgejo_verdict_comment \
    "2026-09-09T10:45:53Z" "2026-09-09T09:11:07Z" \
    'Reviewed this pull request — **Good to merge (LGTM).** <!-- crabd:tracking -->' > "$dir/comments.json"
  printf '%s\n' '{"state":"failure","total_count":1}' > "$dir/status.json"

  run_case "$dir" "https://forgejo.example.test/group/project/pulls/186" --timeout 0

  expect_code 4 "$RC" "forgejo red CI"
  assert_contains "$OUT" 'action-required: ci red on head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    "red CI must be reported as action required on the head"
  pass "forgejo red CI exits action-required"
}

test_forgejo_ci_falls_back_to_head_scoped_tasks() {
  local dir
  dir=$(forgejo_case forgejo-ci-tasks)
  forgejo_verdict_comment \
    "2026-09-09T10:45:53Z" "2026-09-09T09:11:07Z" \
    'Reviewed this pull request — **Good to merge (LGTM).** <!-- crabd:tracking -->' > "$dir/comments.json"
  printf '%s\n' '{"state":"","total_count":0}' > "$dir/status.json"
  printf '%s\n' '{"workflow_runs":[{"name":"ci","status":"success","head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"name":"check","status":"success","head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"name":"ci","status":"success","head_sha":"cccccccccccccccccccccccccccccccccccccccc"}]}' > "$dir/tasks.json"

  run_case "$dir" "https://forgejo.example.test/group/project/pulls/186" --timeout 0

  expect_code 0 "$RC" "forgejo CI task fallback"
  assert_contains "$OUT" 'ci green' \
    "head-scoped successful tasks must count as green when no commit status exists"

  printf '%s\n' '{"workflow_runs":[{"name":"ci","status":"failure","head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}' > "$dir/tasks.json"

  run_case "$dir" "https://forgejo.example.test/group/project/pulls/186" --timeout 0

  expect_code 4 "$RC" "forgejo CI task fallback failure"
  pass "forgejo CI falls back to head-scoped tasks when no commit status exists"
}

test_github_fresh_verdict() {
  local dir
  dir=$(github_case github-fresh)
  printf '%s' '[{"user":{"login":"mseibert"},"created_at":"2026-09-09T11:00:00Z","updated_at":"2026-09-09T11:00:00Z","body":"@seibert-pr-agent please review"},{"user":{"login":"seibert-pr-agent[bot]"},"created_at":"2026-09-09T11:05:00Z","updated_at":"2026-09-09T11:05:00Z","body":"## Title\n\nBody text\n\n**Verdict:** Good to merge"}]' > "$dir/comments.json"

  run_case "$dir" "https://github.com/example/repo/pull/42" --timeout 0

  expect_code 0 "$RC" "github fresh verdict"
  assert_contains "$OUT" 'ready: verdict "Good to merge" at 2026-09-09T11:05:00Z' \
    "the newest PR-agent verdict line must be read"
  assert_contains "$OUT" 'covers head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb (2026-09-09T10:03:44Z)' \
    "github readiness must name the covered head"
  pass "github fresh **Verdict:** line in the newest PR-agent comment is ready"
}

test_github_older_verdict_comment_does_not_cover_head() {
  local dir
  dir=$(github_case github-newest-non-verdict)
  # The newest PR-agent comment carries no verdict line; the newest one that
  # does predates the head. Waiting is the correct behavior.
  printf '%s' '[{"user":{"login":"seibert-pr-agent[bot]"},"created_at":"2026-09-09T09:00:00Z","updated_at":"2026-09-09T09:00:00Z","body":"## Title\n\n**Verdict:** Good to merge"},{"user":{"login":"seibert-pr-agent[bot]"},"created_at":"2026-09-09T11:00:00Z","updated_at":"2026-09-09T11:00:00Z","body":"## PR Code Suggestions\n\nNo problems found."}]' > "$dir/comments.json"

  run_case "$dir" "https://github.com/example/repo/pull/42" --timeout 0

  expect_code 1 "$RC" "github stale verdict comment"
  assert_contains "$OUT" 'the verdict is older than the head' \
    "a verdict-bearing comment older than the head must read stale"
  pass "github verdict older than the head is not ready even with a newer non-verdict comment"
}

test_github_blocking_verdict() {
  local dir
  dir=$(github_case github-blocking)
  printf '%s' '[{"user":{"login":"seibert-pr-agent[bot]"},"created_at":"2026-09-09T11:05:00Z","updated_at":"2026-09-09T11:05:00Z","body":"## Title\n\n**Verdict:** Please fix the comments before merging"}]' > "$dir/comments.json"

  run_case "$dir" "https://github.com/example/repo/pull/42" --timeout 0

  expect_code 3 "$RC" "github blocking verdict"
  assert_contains "$OUT" 'action-required: verdict "Please fix the comments before merging"' \
    "a non-Good-to-merge value must be reported verbatim as action required"
  pass "github blocking verdict exits action-required"
}

test_github_missing_verdict_comment() {
  local dir
  dir=$(github_case github-no-verdict)
  printf '%s' '[{"user":{"login":"mseibert"},"created_at":"2026-09-09T11:00:00Z","updated_at":"2026-09-09T11:00:00Z","body":"@seibert-pr-agent please review"},{"user":{"login":"claude[bot]"},"created_at":"2026-09-09T11:02:00Z","updated_at":"2026-09-09T11:02:00Z","body":"## Review summary\n\nLooks fine."}]' > "$dir/comments.json"

  run_case "$dir" "https://github.com/example/repo/pull/42" --timeout 0

  expect_code 1 "$RC" "github no verdict comment"
  assert_contains "$OUT" 'no verdict found (no seibert-pr-agent comment with a **Verdict:** line)' \
    "a non-agent comment must not be read as a verdict"
  pass "github without a PR-agent verdict line reports no verdict"
}

test_github_pending_ci_blocks_ready_and_no_ci_escapes() {
  local dir
  dir=$(github_case github-pending-ci)
  printf '%s' '[{"user":{"login":"seibert-pr-agent[bot]"},"created_at":"2026-09-09T11:05:00Z","updated_at":"2026-09-09T11:05:00Z","body":"**Verdict:** Good to merge"}]' > "$dir/comments.json"
  printf '%s\n' '[{"bucket":"pending","name":"ci","state":"PENDING"}]' > "$dir/checks.json"

  run_case "$dir" "https://github.com/example/repo/pull/42" --timeout 0

  expect_code 1 "$RC" "github pending CI"
  assert_contains "$OUT" 'ci not green (state=pending) with a fresh verdict' \
    "pending CI must be named as the missing piece"

  run_case "$dir" "https://github.com/example/repo/pull/42" --timeout 0 --no-ci

  expect_code 0 "$RC" "github pending CI with --no-ci"
  pass "github pending CI blocks readiness and --no-ci escapes it"
}

test_github_red_ci_is_action_required() {
  local dir
  dir=$(github_case github-red-ci)
  printf '%s' '[{"user":{"login":"seibert-pr-agent[bot]"},"created_at":"2026-09-09T11:05:00Z","updated_at":"2026-09-09T11:05:00Z","body":"**Verdict:** Good to merge"}]' > "$dir/comments.json"
  printf '%s\n' '[{"bucket":"fail","name":"ci","state":"FAILURE"}]' > "$dir/checks.json"

  run_case "$dir" "https://github.com/example/repo/pull/42" --timeout 0

  expect_code 4 "$RC" "github red CI"
  assert_contains "$OUT" 'action-required: ci red on head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    "red CI must be reported as action required"
  pass "github red CI exits action-required"
}

test_github_no_checks_is_unknown_not_green() {
  local dir
  dir=$(github_case github-no-checks)
  printf '%s' '[{"user":{"login":"seibert-pr-agent[bot]"},"created_at":"2026-09-09T11:05:00Z","updated_at":"2026-09-09T11:05:00Z","body":"**Verdict:** Good to merge"}]' > "$dir/comments.json"
  printf '' > "$dir/checks.json"

  run_case "$dir" "https://github.com/example/repo/pull/42" --timeout 0

  expect_code 1 "$RC" "github no checks"
  assert_contains "$OUT" 'ci not green (state=unknown)' \
    "absent CI must read unknown, never green"
  pass "github absent CI is unknown, not green"
}

test_forgejo_host_without_login_is_an_error() {
  local dir
  dir=$(forgejo_case forgejo-host-mismatch)
  forgejo_verdict_comment \
    "2026-09-09T10:45:53Z" "2026-09-09T09:11:07Z" \
    'Reviewed this pull request — **Good to merge (LGTM).** <!-- crabd:tracking -->' > "$dir/comments.json"

  run_case "$dir" "https://forgejo.other.test/group/project/pulls/186" --timeout 0

  expect_code 2 "$RC" "forgejo unknown host"
  assert_contains "$ERR" 'no tea login for host forgejo.other.test' \
    "a Forgejo host with no tea login must be refused, never queried through another login"
  pass "forgejo URL on an unconfigured host is refused"
}

test_bad_usage_is_an_error() {
  local dir
  dir=$(forgejo_case usage)

  run_case "$dir" --timeout 0
  expect_code 2 "$RC" "missing URL"
  assert_contains "$ERR" 'usage: fm-verdict-wait.sh' "missing URL must print usage"

  run_case "$dir" "https://gitlab.example.test/group/project/-/merge_requests/1" --timeout 0
  expect_code 2 "$RC" "unsupported URL"

  run_case "$dir" "https://forgejo.example.test/group/project/pulls/186" --bogus
  expect_code 2 "$RC" "unknown option"

  run_case "$dir" "https://forgejo.example.test/group/project/pulls/186" --timeout nope
  expect_code 2 "$RC" "non-numeric timeout"

  run_case "$dir" "https://forgejo.example.test/group/project/pulls/186" --interval 0
  expect_code 2 "$RC" "zero interval"
  pass "bad usage and unsupported URLs exit 2"
}

test_closed_pr_is_an_error() {
  local dir
  dir=$(forgejo_case closed-pr)
  printf '%s\n' '{"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"state":"closed","merged":true}' > "$dir/pr.json"

  run_case "$dir" "https://forgejo.example.test/group/project/pulls/186" --timeout 0

  expect_code 2 "$RC" "closed PR"
  assert_contains "$ERR" 'PR is not open' "a closed or merged PR must be refused"
  pass "closed PR exits 2"
}

test_repeated_read_errors_fail_loudly() {
  local dir
  dir=$(forgejo_case read-errors)
  rm -f "$dir/pr.json"

  run_case "$dir" "https://forgejo.example.test/group/project/pulls/186" --timeout 600 --interval 1

  expect_code 2 "$RC" "repeated read errors"
  assert_contains "$ERR" 'could not read PR state after 3 attempts' \
    "a broken read must fail loudly instead of looping silently"
  pass "repeated read errors fail after three attempts"
}

test_waiting_loop_returns_as_soon_as_verdict_lands() {
  local dir seq
  dir=$(forgejo_case wait-loop)
  seq="$dir/seq"
  mkdir -p "$seq"
  forgejo_verdict_comment \
    "2026-09-09T09:11:07Z" "2026-09-09T09:11:07Z" \
    'Reviewed this pull request — **Good to merge (LGTM).** <!-- crabd:tracking -->' > "$seq/call-1.json"
  forgejo_verdict_comment \
    "2026-09-09T10:45:53Z" "2026-09-09T09:11:07Z" \
    'Reviewed this pull request — **Good to merge (LGTM).** <!-- crabd:tracking -->' > "$seq/call-2.json"
  cp "$seq/call-2.json" "$seq/call-last.json"

  FAKE_TEA_COMMENTS_SEQ="$seq" FAKE_TEA_COUNTER="$dir/counter" \
    run_case "$dir" "https://forgejo.example.test/group/project/pulls/186" --timeout 600 --interval 1

  expect_code 0 "$RC" "wait loop"
  assert_contains "$OUT" 'ready: verdict "Good to merge (LGTM)."' \
    "the wait loop must return once the verdict becomes fresh"
  [ "$(cat "$dir/counter")" = 2 ] \
    || fail "the wait loop must re-read the comments until the verdict lands (got $(cat "$dir/counter"))"
  assert_contains "$ERR" 'waiting: verdict older than head' \
    "the wait loop must report progress while it waits"
  pass "the bounded wait returns as soon as a fresh verdict lands"
}

test_quiet_suppresses_progress() {
  local dir
  dir=$(forgejo_case quiet)
  forgejo_verdict_comment \
    "2026-09-09T09:11:07Z" "2026-09-09T09:11:07Z" \
    'Reviewed this pull request — **Good to merge (LGTM).** <!-- crabd:tracking -->' > "$dir/comments.json"

  run_case "$dir" "https://forgejo.example.test/group/project/pulls/186" --timeout 0 --quiet

  expect_code 1 "$RC" "quiet timeout"
  [ -z "$ERR" ] || fail "--quiet must suppress progress lines (got '$ERR')"
  pass "--quiet suppresses progress lines"
}

test_forgejo_fresh_lgtm_uses_updated_at
test_forgejo_created_at_newer_than_head_is_still_stale
test_forgejo_in_flight_is_not_a_verdict
test_forgejo_missing_updated_at_never_falls_back_to_created_at
test_forgejo_unrecognized_review_line
test_forgejo_missing_tracking_comment
test_forgejo_blocking_verdict_is_action_required
test_forgejo_nits_found_is_mergeable
test_forgejo_pending_ci_blocks_ready_and_no_ci_escapes
test_forgejo_red_ci_is_action_required
test_forgejo_ci_falls_back_to_head_scoped_tasks
test_github_fresh_verdict
test_github_older_verdict_comment_does_not_cover_head
test_github_blocking_verdict
test_github_missing_verdict_comment
test_github_pending_ci_blocks_ready_and_no_ci_escapes
test_github_red_ci_is_action_required
test_github_no_checks_is_unknown_not_green
test_forgejo_host_without_login_is_an_error
test_bad_usage_is_an_error
test_closed_pr_is_an_error
test_repeated_read_errors_fail_loudly
test_waiting_loop_returns_as_soon_as_verdict_lands
test_quiet_suppresses_progress
