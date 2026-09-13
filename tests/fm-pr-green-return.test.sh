#!/usr/bin/env bash
# Tests for bin/fm-pr-green-return.sh: the bounded return path for a task's
# PR that is green, mergeable, and policy-clean but has not been merged.
#
# Matrix:
#   (a) a due GitHub PR queues the bound-merge check wake with the verified head
#   (b) the wait boundary is exact (threshold - 1 silent, threshold exact wakes)
#       and a restart keeps the evidence-backed wait start instead of resetting
#   (c) red CI holds the PR and names hard stop 3, never a merge
#   (d) a repo with no checks holds and names hard stop 4
#   (e) a foreign author holds and names hard stop 6
#   (f) a missing or open five-lens gate holds and names hard stop 1
#   (g) a missing, negative, or stale review verdict holds and names hard stop 2
#   (g) the advisory review verdict holds only a blocking verdict or an
#       unreadable channel, and names hard stop 2, while a missing or stale
#       verdict does not hold the merge
#   (h) a sensitive diff path, or an unreadable changed-file list, holds and
#       names hard stop 5
#   (i) a package.json version-only change is not sensitive, a scripts change is
#       held by hard stop 5, and a mergeable lockfile-only change is not held
#       (the policy applies those globs only on conflict)
#   (j) an unreadable policy holds every candidate and names hard stop 7
#   (k) a repo outside the autonomous allowlist is held as the default ask
#   (l) a merged or closed PR leaves no wake and no record
#   (m) a Forgejo PR with a fresh crabd verdict is due, a blocking crabd
#       verdict holds, and a missing or legacy verdict does not hold
#   (n) GitLab has no policy verdict channel and is not held by item 2
#   (o) report is read-only and names the hold
#   (p) the scan cadence suppresses repeated work between configured intervals
#   (q) every candidate is evaluated in one scan
#   (r) the watcher invokes the scan and surfaces the main-owned check wake
#   (s) an invalid wait configuration stops the scan before any wake
#   (t) config/pr-green-return sets the wait when no env override is present
#   (u) a task without a pr= line, and a secondmate meta, are not candidates
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GREEN="$ROOT/bin/fm-pr-green-return.sh"
WATCH_CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-green-return-tests)

HEAD=1111111111111111111111111111111111111111
BASE=2222222222222222222222222222222222222222
HEAD_TIME=2026-01-01T00:00:00Z
VERDICT_TIME=2026-01-01T00:10:00Z
VERDICT_EPOCH=1767226200
# 800 seconds after the fresh verdict: past the 600s default wait.
NOW_LATE=1767227000

# make_case <name> echoes a fresh sandbox directory with home/, fix/, fakebin/.
make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  rm -rf "$dir"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data" "$dir/fakebin" "$dir/fix"
  ln -sf "$(command -v jq)" "$dir/fakebin/jq"
  : > "$dir/fix/calls.log"
  add_stubs "$dir"
  printf '%s\n' "$dir"
}

# add_stubs <dir>: provider stand-ins that answer only read calls from the
# fixture directory. A merge or any other verb exits 1, and every invocation is
# logged so a case can prove that no merge was ever attempted.
add_stubs() {
  local dir=$1
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$FM_TEST_LOG"
fixed=$FM_TEST_FIX
case "${1:-} ${2:-}" in
  "pr view") cat "$fixed/gh-view.json" ;;
  "pr diff") cat "$fixed/gh-files" ;;
  "pr merge") exit 1 ;;
  "api user") cat "$fixed/gh-login" ;;
  "api -H")
    ref=${4##*ref=}
    path=${4#*/contents/}
    path=${path%%\?*}
    file="$fixed/raw-${ref}-$(printf '%s' "$path" | tr '/' '_')"
    if [ -f "$file" ]; then cat "$file"; else exit 1; fi
    ;;
  "api "*)
    case "$2" in
      */issues/*/comments) cat "$fixed/gh-comments.json" ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
  cat > "$dir/fakebin/tea" <<'SH'
#!/usr/bin/env bash
printf 'tea %s\n' "$*" >> "$FM_TEST_LOG"
fixed=$FM_TEST_FIX
case "${1:-} ${2:-}" in
  "api /user") cat "$fixed/tea-user.json" ;;
  "api "*)
    case "$2" in
      */pulls/*/files) cat "$fixed/tea-files.json" ;;
      */pulls/*) cat "$fixed/tea-pull.json" ;;
      */git/commits/*) cat "$fixed/tea-commit.json" ;;
      */commits/*/status) cat "$fixed/tea-status.json" ;;
      */issues/*/comments) cat "$fixed/tea-comments.json" ;;
      */raw/*)
        ref=${2##*ref=}
        path=${2#*/raw/}
        path=${path%%\?*}
        file="$fixed/raw-${ref}-$(printf '%s' "$path" | tr '/' '_')"
        if [ -f "$file" ]; then cat "$file"; else exit 1; fi
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
  cat > "$dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
printf 'glab %s\n' "$*" >> "$FM_TEST_LOG"
fixed=$FM_TEST_FIX
case "${1:-} ${2:-}" in
  "mr view") cat "$fixed/glab-mr.json" ;;
  "mr merge") exit 1 ;;
  "api user") cat "$fixed/glab-user.json" ;;
  "api "*)
    case "$2" in
      */merge_requests/*/changes) cat "$fixed/glab-changes.json" ;;
      */repository/commits/*) cat "$fixed/glab-commit.json" ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
  chmod 0755 "$dir/fakebin/gh" "$dir/fakebin/tea" "$dir/fakebin/glab"
}

write_policy() { # <dir> <allowlisted repo name...>
  local dir=$1
  shift
  {
    printf '# PR-Merge-Policy\n\n'
    printf '## The rule\n\nDefault is ask.\n\n'
    printf '| Repo | [Autonomous | Ask] | Why |\n|---|---|---|\n'
    local repo
    for repo in "$@"; do
      printf '| %s | Autonomous | fixture |\n' "$repo"
    done
    cat <<'EOF'
## Hard-stops

### 5. Diff touches sensitive ground

```bash
# GitHub
gh pr diff <pr> --name-only
```

against:

```
.github/workflows/**  bamboo-specs/**  Dockerfile*  docker-compose*
**/*migration*  **/*.sql
.env*  **/secrets*  **/*credential*  **/*.pem  **/*.key
**/auth/**  **/authz/**  **/permission*  **/role*  **/*policy*  **/middleware*
pnpm-lock.yaml  package-lock.json  yarn.lock        (only on conflict)
package.json                                        (only the scripts block)
```

### 6. Not the operator PR
EOF
  } > "$dir/fix/policy.md"
}

write_meta() { # <dir> <id> <url> [project-name]
  local dir=$1 id=$2 url=$3 project=${4:-project}
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "kind=ship" \
    "mode=direct-PR" \
    "project=$dir/projects/$project" \
    "pr=$url" \
    "pr_head=$HEAD"
}

gh_green() { # <dir>
  local dir=$1
  jq -n --arg head "$HEAD" --arg base "$BASE" --arg time "$HEAD_TIME" '{
    state: "OPEN",
    isDraft: false,
    mergeable: "MERGEABLE",
    headRefOid: $head,
    baseRefOid: $base,
    author: {login: "op"},
    body: "## Five-lens gate\n\n| Lens | Ran | Findings | Fixed |\n|---|---|---|---|\n| code-review | yes | 0 | 0 |\n| maintainability-review | yes | 0 | 0 |\n| architecture-system-design-reviewer | yes | 0 | 0 |\n| design-decision-questioner | yes | 0 | 0 |\n| self-containment-review | yes | 0 | 0 |\n\nResult: clean\n",
    commits: [{oid: $head, committedDate: $time}],
    statusCheckRollup: [{__typename: "CheckRun", status: "COMPLETED", conclusion: "SUCCESS", name: "Lint"}]
  }' > "$dir/fix/gh-view.json"
  printf 'op\n' > "$dir/fix/gh-login"
  jq -n --arg time "$VERDICT_TIME" '[[{user: {login: "seibert-pr-agent"}, created_at: $time, updated_at: $time, body: "**Verdict:** Good to merge\n"}]]' \
    > "$dir/fix/gh-comments.json"
  printf 'src/app.ts\n' > "$dir/fix/gh-files"
}

gh_set_checks() { # <dir> <json>
  local dir=$1 tmp
  tmp=$(mktemp)
  jq --argjson checks "$2" '.statusCheckRollup = $checks' "$dir/fix/gh-view.json" > "$tmp"
  mv "$tmp" "$dir/fix/gh-view.json"
}

gh_set_author() { # <dir> <login>
  local dir=$1 tmp
  tmp=$(mktemp)
  jq --arg login "$2" '.author.login = $login' "$dir/fix/gh-view.json" > "$tmp"
  mv "$tmp" "$dir/fix/gh-view.json"
}

gh_set_body() { # <dir> <body>
  local dir=$1 tmp
  tmp=$(mktemp)
  jq --arg body "$2" '.body = $body' "$dir/fix/gh-view.json" > "$tmp"
  mv "$tmp" "$dir/fix/gh-view.json"
}

gh_set_state() { # <dir> <state>
  local dir=$1 tmp
  tmp=$(mktemp)
  jq --arg state "$2" '.state = $state' "$dir/fix/gh-view.json" > "$tmp"
  mv "$tmp" "$dir/fix/gh-view.json"
}

gh_set_verdict() { # <dir> <verdict-value|none> [timestamp]
  local dir=$1 value=$2 time=${3:-$VERDICT_TIME} tmp
  tmp=$(mktemp)
  if [ "$value" = none ]; then
    printf '%s\n' '[[]]' > "$tmp"
  else
    jq -n --arg time "$time" --arg value "$value" \
      '[[{user: {login: "seibert-pr-agent"}, created_at: $time, updated_at: $time, body: ("**Verdict:** " + $value + "\n")}]]' \
      > "$tmp"
  fi
  mv "$tmp" "$dir/fix/gh-comments.json"
}

gh_set_head_time() { # <dir> <time>
  local dir=$1 tmp
  tmp=$(mktemp)
  jq --arg time "$2" '.commits = [.commits[0] | .committedDate = $time]' "$dir/fix/gh-view.json" > "$tmp"
  mv "$tmp" "$dir/fix/gh-view.json"
}

gh_set_files() { # <dir> <newline list>
  printf '%s\n' "$2" > "$dir/fix/gh-files"
}

tea_green() { # <dir>
  local dir=$1
  jq -n --arg head "$HEAD" --arg base "$BASE" '{
    state: "open",
    merged: false,
    mergeable: true,
    head: {sha: $head},
    base: {sha: $base},
    user: {login: "op"},
    body: "## Five-Lens-Block\n\n**1. `code-review` — Verdikt: kein Blocker.**\n**2. `maintainability-review` — Verdikt: kein Blocker.**\n**3. `architecture-system-design-reviewer` — Verdikt: kein Blocker.**\n**4. `design-decision-questioner` — Verdikt: kein Blocker.**\n**5. `self-containment-review` — Verdikt: kein Blocker.**\n"
  }' > "$dir/fix/tea-pull.json"
  jq -n --arg head "$HEAD" '{sha: $head, state: "success", total_count: 2}' > "$dir/fix/tea-status.json"
  jq -n --arg time "$HEAD_TIME" '{created: $time}' > "$dir/fix/tea-commit.json"
  jq -n --arg time "$VERDICT_TIME" \
    '[{user: {login: "seibert-pr-agent"}, updated_at: $time, body: "Reviewed this pull request — **Good to merge (LGTM).**\n<!-- crabd:tracking -->"}]' \
    > "$dir/fix/tea-comments.json"
  jq -n '[{filename: "src/app.ts"}]' > "$dir/fix/tea-files.json"
  printf '%s\n' '{"login":"op"}' > "$dir/fix/tea-user.json"
}

tea_set_verdict() { # <dir> <body-json>
  local dir=$1
  jq -n --arg time "$VERDICT_TIME" --arg body "$2" \
    '[{user: {login: "seibert-pr-agent"}, updated_at: $time, body: $body}]' \
    > "$dir/fix/tea-comments.json"
}

glab_green() { # <dir>
  local dir=$1
  jq -n --arg head "$HEAD" --arg base "$BASE" '{
    state: "opened",
    draft: false,
    detailed_merge_status: "mergeable",
    has_conflicts: false,
    blocking_discussions_resolved: true,
    sha: $head,
    diff_refs: {base_sha: $base},
    author: {username: "op"},
    description: "## Five-lens gate\n\nResult: clean\n",
    head_pipeline: {status: "success", sha: $head}
  }' > "$dir/fix/glab-mr.json"
  printf '%s\n' '{"username":"op"}' > "$dir/fix/glab-user.json"
  jq -n --arg time "$HEAD_TIME" '{committed_date: $time}' > "$dir/fix/glab-commit.json"
  jq -n '{changes: [{new_path: "src/app.ts"}]}' > "$dir/fix/glab-changes.json"
}

raw_pair() { # <dir> <base-scripts> <head-scripts>
  local dir=$1 base_scripts=$2 head_scripts=$3
  printf '{"name":"pkg","version":"1.0.0","scripts":%s}\n' "$base_scripts" > "$dir/fix/raw-${BASE}-package.json"
  printf '{"name":"pkg","version":"1.1.0","scripts":%s}\n' "$head_scripts" > "$dir/fix/raw-${HEAD}-package.json"
}

queue_keys() { # <dir>
  awk -F'\t' 'NF >= 5 { print $4 }' "$1/home/state/.wake-queue" 2>/dev/null || true
}

queue_rows() { # <dir>
  cat "$1/home/state/.wake-queue" 2>/dev/null || true
}

scan_case() { # <dir> <now> [extra env pairs...]
  local dir=$1 now=$2
  shift 2
  env FM_HOME="$dir/home" \
    FM_PR_GREEN_RETURN_POLICY="$dir/fix/policy.md" \
    FM_TEST_FIX="$dir/fix" FM_TEST_LOG="$dir/fix/calls.log" \
    FM_PR_GREEN_RETURN_SECS=600 FM_PR_GREEN_RETURN_FORCE=1 \
    FM_PR_GREEN_RETURN_NOW="$now" PATH="$dir/fakebin:$PATH" \
    "$@" "$GREEN" scan 2>"$dir/scan.err"
}

report_case() { # <dir> <now> [extra env pairs...]
  local dir=$1 now=$2
  shift 2
  env FM_HOME="$dir/home" \
    FM_PR_GREEN_RETURN_POLICY="$dir/fix/policy.md" \
    FM_TEST_FIX="$dir/fix" FM_TEST_LOG="$dir/fix/calls.log" \
    FM_PR_GREEN_RETURN_SECS=600 \
    FM_PR_GREEN_RETURN_NOW="$now" PATH="$dir/fakebin:$PATH" \
    "$@" "$GREEN" report 2>"$dir/report.err"
}

# scan_hold_wake <dir> <now> [extra env pairs...]: a held PR is reported only
# after the hold itself has persisted the wait, so run the observation and the
# elapsed second scan that a live poll loop would run.
scan_hold_wake() { # <dir> <now> [extra env pairs...]
  local dir=$1 now=$2
  shift 2
  scan_case "$dir" "$now" "$@" >/dev/null
  scan_case "$dir" "$((now + 600))" "$@" >/dev/null
}

test_due_github_pr_wakes_the_bound_merge() {
  local dir keys rows
  dir=$(make_case due-gh)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  scan_case "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return:t1" "due wake key missing"
  assert_not_contains "$keys" "pr-green-return-hold:t1" "due PR also queued a hold"
  assert_contains "$rows" "check: green-return t1 due:" "due payload missing the due marker"
  assert_contains "$rows" "head $HEAD" "due payload missing the verified head"
  assert_contains "$rows" "bin/fm-pr-merge.sh t1 https://github.com/op/project/pull/7" "due payload missing the bound merge command"
  assert_grep "class=due" "$dir/home/state/pr-green-return/t1" "marker class is not due"
  assert_grep "since=$VERDICT_EPOCH" "$dir/home/state/pr-green-return/t1" "marker did not keep the evidence-backed wait start"
  assert_grep "notified=due:$HEAD" "$dir/home/state/pr-green-return/t1" "marker did not record the notification"
  assert_no_grep "pr merge" "$dir/fix/calls.log" "the scan attempted a merge verb"
  assert_no_grep "mr merge" "$dir/fix/calls.log" "the scan attempted a merge verb"
  pass "a due GitHub PR queues the bound-merge wake with the verified head"
}

test_wait_boundary_is_exact_and_persists() {
  local dir keys
  dir=$(make_case wait)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  scan_case "$dir" "$((VERDICT_EPOCH + 599))" >/dev/null
  keys=$(queue_keys "$dir")
  [ -z "$keys" ] || fail "a PR inside the wait already woke: $keys"
  assert_grep "class=due" "$dir/home/state/pr-green-return/t1" "marker class is not due inside the wait"
  assert_grep "since=$VERDICT_EPOCH" "$dir/home/state/pr-green-return/t1" "wait start is not the fresh verdict time"
  assert_no_grep "notified=due:" "$dir/home/state/pr-green-return/t1" "inside the wait recorded a notification"
  scan_case "$dir" "$((VERDICT_EPOCH + 600))" >/dev/null
  keys=$(queue_keys "$dir")
  assert_contains "$keys" "pr-green-return:t1" "the exact wait threshold did not wake"
  assert_grep "since=$VERDICT_EPOCH" "$dir/home/state/pr-green-return/t1" "the second scan reset the wait start"
  scan_case "$dir" "$((VERDICT_EPOCH + 1200))" >/dev/null
  [ "$(queue_keys "$dir" | grep -c 'pr-green-return:t1')" = 1 ] || fail "an already-notified PR was queued twice"
  pass "the wait boundary is exact and a later scan does not reset or duplicate it"
}

test_red_checks_hold_and_name_hard_stop_3() {
  local dir keys rows marker
  dir=$(make_case red)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  gh_set_checks "$dir" '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE","name":"Lint"}]'
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  marker="$dir/home/state/pr-green-return/t1"
  assert_contains "$keys" "pr-green-return-hold:t1" "red CI did not queue the hold wake"
  assert_not_contains "$keys" "pr-green-return:t1" "red CI queued a merge wake"
  assert_contains "$rows" "hard stop 3" "red CI payload did not name hard stop 3"
  assert_contains "$rows" "do not merge" "red CI payload did not forbid the merge"
  assert_grep "class=held" "$marker" "red CI marker class is not held"
  assert_no_grep "merge " "$dir/fix/calls.log" "the scan attempted a merge verb"
  pass "red CI holds the PR and names hard stop 3, never a merge"
}

test_no_checks_hold_and_name_hard_stop_4() {
  local dir keys rows
  dir=$(make_case nochecks)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  gh_set_checks "$dir" '[]'
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return-hold:t1" "a repo without checks did not hold"
  assert_not_contains "$keys" "pr-green-return:t1" "a repo without checks queued a merge wake"
  assert_contains "$rows" "hard stop 4" "the hold payload did not name hard stop 4"
  pass "a repo with no checks holds and names hard stop 4"
}

test_foreign_pr_holds_hard_stop_6() {
  local dir keys rows
  dir=$(make_case foreign)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  gh_set_author "$dir" bot-renovate
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return-hold:t1" "a foreign PR did not hold"
  assert_contains "$rows" "hard stop 6" "the hold payload did not name hard stop 6"
  assert_not_contains "$keys" "pr-green-return:t1" "a foreign PR queued a merge wake"
  pass "a foreign PR holds and names hard stop 6"
}

test_gate_holds_hard_stop_1() {
  local dir keys rows
  dir=$(make_case gate)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  gh_set_body "$dir" "No gate block here."
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return-hold:t1" "a missing gate block did not hold"
  assert_contains "$rows" "hard stop 1" "the hold payload did not name hard stop 1"

  dir=$(make_case gate-open)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  gh_set_body "$dir" $'## Five-lens gate\n\n| Lens | Ran | Findings | Fixed |\n|---|---|---|---|\n| code-review | yes | 3 | 0 |\n| maintainability-review | yes | 0 | 0 |\n| architecture-system-design-reviewer | yes | 0 | 0 |\n| design-decision-questioner | yes | 0 | 0 |\n| self-containment-review | yes | 0 | 0 |\n\nResult: 3 findings, 1 open\n'
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  assert_contains "$(queue_keys "$dir")" "pr-green-return-hold:t1" "an open gate finding did not hold"
  pass "a missing or open five-lens gate holds and names hard stop 1"
}

test_verdict_channel_is_advisory_and_holds_only_on_a_blocking_read() {
  local dir keys rows
  # A verdict that never arrives does not hold the merge (policy, 2026-09-13).
  dir=$(make_case verdict-missing)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  gh_set_verdict "$dir" none
  scan_case "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  assert_contains "$keys" "pr-green-return:t1" "a missing verdict held the merge"
  assert_not_contains "$keys" "pr-green-return-hold:t1" "a missing verdict queued a hold"

  # A blocking verdict is held for the captain's own read, naming item 2.
  dir=$(make_case verdict-negative)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  gh_set_verdict "$dir" "Please fix the comments before merging"
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return-hold:t1" "a blocking verdict did not hold"
  assert_contains "$rows" "hard stop 2" "a blocking verdict did not name hard stop 2"
  assert_not_contains "$keys" "pr-green-return:t1" "a blocking verdict queued a merge wake"

  # A positive verdict older than the head is advisory like any other: the
  # merge it once approved is still allowed, provided nothing else holds.
  dir=$(make_case verdict-stale)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  gh_set_head_time "$dir" "2026-01-01T00:12:00Z"
  scan_case "$dir" "$NOW_LATE" >/dev/null
  assert_contains "$(queue_keys "$dir")" "pr-green-return:t1" "a stale positive verdict held the merge"

  # A channel that cannot be read still holds: a blocking verdict could be
  # hiding behind the failed read.
  dir=$(make_case verdict-unreadable)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  rm -f "$dir/fix/gh-comments.json"
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  assert_contains "$(queue_keys "$dir")" "pr-green-return-hold:t1" "an unreadable verdict channel did not hold"
  assert_contains "$(queue_rows "$dir")" "hard stop 2" "an unreadable verdict channel did not name hard stop 2"
  pass "the advisory verdict holds only a blocking or unreadable read"
}

test_sensitive_diff_holds_hard_stop_5() {
  local dir keys rows
  dir=$(make_case sensitive)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  gh_set_files "$dir" $'.github/workflows/ci.yml\nsrc/app.ts'
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return-hold:t1" "a sensitive diff did not hold"
  assert_contains "$rows" "hard stop 5" "a sensitive diff did not name hard stop 5"
  assert_contains "$rows" ".github/workflows/ci.yml" "the hold payload did not name the sensitive path"
  assert_not_contains "$keys" "pr-green-return:t1" "a sensitive diff queued a merge wake"

  # An unreadable changed-file list is no proof that the diff stays off the
  # policy's sensitive ground, so hard stop 5 fails closed.
  dir=$(make_case sensitive-unreadable)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  rm -f "$dir/fix/gh-files"
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return-hold:t1" "an unreadable file list did not hold"
  assert_contains "$rows" "hard stop 5" "an unreadable file list did not name hard stop 5"
  assert_not_contains "$keys" "pr-green-return:t1" "an unreadable file list queued a merge wake"
  pass "a sensitive diff path holds and names hard stop 5"
}

test_lockfile_only_change_is_not_sensitive_on_a_mergeable_pr() {
  local dir keys
  dir=$(make_case lockfile)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  gh_set_files "$dir" $'pnpm-lock.yaml\nsrc/app.ts'
  scan_case "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  assert_contains "$keys" "pr-green-return:t1" "a mergeable lockfile-only change was held"
  assert_not_contains "$keys" "pr-green-return-hold:t1" "a mergeable lockfile-only change queued a hold"
  pass "a lockfile change is not sensitive on a mergeable PR (policy: only on conflict)"
}

test_package_json_scripts_qualifier() {
  local dir keys rows
  dir=$(make_case pkg-version)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  gh_set_files "$dir" $'package.json'
  raw_pair "$dir" '{"build":"tsc"}' '{"build":"tsc"}'
  scan_case "$dir" "$NOW_LATE" >/dev/null
  assert_contains "$(queue_keys "$dir")" "pr-green-return:t1" "a version-only package.json change was not due"

  dir=$(make_case pkg-scripts)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  gh_set_files "$dir" $'package.json'
  raw_pair "$dir" '{"build":"tsc"}' '{"build":"tsc && rm -rf /"}'
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return-hold:t1" "a scripts change did not hold"
  assert_contains "$rows" "hard stop 5" "a scripts change did not name hard stop 5"
  assert_not_contains "$keys" "pr-green-return:t1" "a scripts change queued a merge wake"
  pass "package.json is sensitive only when its scripts block changes"
}

test_unreadable_policy_holds_hard_stop_7() {
  local dir keys rows
  dir=$(make_case policy-missing)
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  scan_hold_wake "$dir" "$NOW_LATE" \
    FM_PR_GREEN_RETURN_POLICY="$dir/fix/absent-policy.md" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return-hold:t1" "an unreadable policy did not hold"
  assert_contains "$rows" "hard stop 7" "an unreadable policy did not name hard stop 7"
  assert_not_contains "$keys" "pr-green-return:t1" "an unreadable policy queued a merge wake"
  pass "an unreadable policy holds every candidate and names hard stop 7"
}

test_allowlist_default_ask_holds() {
  local dir keys rows
  dir=$(make_case ask)
  write_policy "$dir" some-other-repo
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return-hold:t1" "an unlisted repo did not hold"
  assert_contains "$rows" "the policy default ask" "the hold payload did not name the default ask"
  assert_not_contains "$keys" "pr-green-return:t1" "an unlisted repo queued a merge wake"
  pass "a repo outside the allowlist is held as the policy default ask"
}

test_merged_pr_leaves_no_wake_or_record() {
  local dir keys
  dir=$(make_case merged)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  gh_set_state "$dir" MERGED
  scan_case "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  [ -z "$keys" ] || fail "a merged PR queued a wake: $keys"
  assert_absent "$dir/home/state/pr-green-return/t1" "a merged PR kept a wait record"
  pass "a merged PR leaves no wake and no record"
}

test_forgejo_due_with_fresh_crabd_verdict() {
  local dir keys rows
  dir=$(make_case forgejo-due)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  scan_case "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return:t1" "a green Forgejo PR with a fresh crabd verdict was not due"
  assert_contains "$rows" "due" "the Forgejo due payload is missing"
  assert_no_grep "merge " "$dir/fix/calls.log" "the scan attempted a merge verb"
  pass "a Forgejo PR with a fresh crabd verdict is due"
}

test_forgejo_verdict_channel() {
  local dir
  dir=$(make_case forgejo-noverdict)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  printf '%s\n' '[]' > "$dir/fix/tea-comments.json"
  scan_case "$dir" "$NOW_LATE" >/dev/null
  assert_contains "$(queue_keys "$dir")" "pr-green-return:t1" "a missing crabd verdict held the merge"
  assert_not_contains "$(queue_keys "$dir")" "pr-green-return-hold:t1" "a missing crabd verdict queued a hold"

  dir=$(make_case forgejo-legacy)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  tea_set_verdict "$dir" $'**Verdict:** Good to merge\n<!-- crabd:tracking -->\n<!-- pr-agent-rate-limit -->'
  scan_case "$dir" "$NOW_LATE" >/dev/null
  assert_contains "$(queue_keys "$dir")" "pr-green-return:t1" "a legacy Qodo verdict held the merge"
  assert_not_contains "$(queue_keys "$dir")" "pr-green-return-hold:t1" "a legacy Qodo verdict queued a hold"

  dir=$(make_case forgejo-blocking)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  tea_set_verdict "$dir" $'Reviewed this pull request — **Please address the findings before merging.**\n<!-- crabd:tracking -->'
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  assert_contains "$(queue_keys "$dir")" "pr-green-return-hold:t1" "a blocking crabd verdict did not hold"
  assert_contains "$(queue_rows "$dir")" "hard stop 2" "a blocking crabd verdict did not name hard stop 2"
  pass "a missing or legacy Forgejo verdict does not hold, a blocking one does"
}

test_gitlab_needs_no_verdict_channel() {
  local dir keys
  dir=$(make_case gitlab)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://gitlab.example/group/project/-/merge_requests/7"
  glab_green "$dir"
  scan_case "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  assert_contains "$keys" "pr-green-return:t1" "a GitLab MR without a policy verdict channel was not due"
  assert_not_contains "$keys" "pr-green-return-hold:t1" "a GitLab MR queued a verdict hold"
  pass "GitLab has no policy verdict channel, and a verdict that cannot arrive does not hold"
}

test_report_is_read_only_and_names_the_hold() {
  local dir out
  dir=$(make_case report)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  gh_set_checks "$dir" '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE","name":"Lint"}]'
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" "held" "report did not classify the red PR as held"
  assert_contains "$out" "hard-stop-3" "report did not name hard stop 3"
  assert_contains "$out" "$HEAD" "report did not show the head"
  assert_absent "$dir/home/state/.wake-queue" "report wrote a wake queue"
  assert_absent "$dir/home/state/pr-green-return/t1" "report wrote a wait record"
  pass "report is read-only and names the hold"
}

test_scan_cadence_suppresses_repeat_work() {
  local dir keys
  dir=$(make_case cadence)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  scan_case "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  assert_contains "$keys" "pr-green-return:t1" "the first scan did not queue the due wake"
  gh_set_checks "$dir" '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE","name":"Lint"}]'
  env FM_HOME="$dir/home" \
    FM_PR_GREEN_RETURN_POLICY="$dir/fix/policy.md" \
    FM_TEST_FIX="$dir/fix" FM_TEST_LOG="$dir/fix/calls.log" \
    FM_PR_GREEN_RETURN_SECS=600 FM_PR_GREEN_RETURN_INTERVAL=999999 \
    FM_PR_GREEN_RETURN_NOW="$((NOW_LATE + 60))" PATH="$dir/fakebin:$PATH" \
    "$GREEN" scan >/dev/null 2>&1
  assert_not_contains "$(queue_keys "$dir")" "pr-green-return-hold:t1" "the cadence gate did not suppress a repeat scan"
  pass "the scan cadence suppresses repeated work between configured intervals"
}

test_every_candidate_is_evaluated_in_one_scan() {
  local dir keys
  dir=$(make_case two-tasks)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  write_meta "$dir" t2 "https://github.com/op/project/pull/8"
  gh_green "$dir"
  scan_case "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  assert_contains "$keys" "pr-green-return:t1" "the first candidate was not evaluated"
  assert_contains "$keys" "pr-green-return:t2" "the second candidate was not evaluated"
  pass "every candidate is evaluated in one scan"
}

test_watcher_surfaces_the_green_return_check_wake() {
  local dir status=0
  dir=$(make_case watcher)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  FM_HOME="$dir/home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_PR_GREEN_RETURN_POLICY="$dir/fix/policy.md" \
    FM_TEST_FIX="$dir/fix" FM_TEST_LOG="$dir/fix/calls.log" \
    FM_PR_GREEN_RETURN_SECS=600 FM_PR_GREEN_RETURN_NOW="$NOW_LATE" \
    PATH="$dir/fakebin:$PATH" \
    "$WATCH_CHECKPOINT" --seconds 6 >"$dir/watch.out" 2>"$dir/watch.err" || status=$?
  expect_code 0 "$status" "watcher checkpoint exit"
  assert_contains "$(cat "$dir/watch.out")" "check: pr-green-return" "the watcher did not surface the green-return wake"
  assert_grep "pr-green-return:t1" "$dir/home/state/.wake-queue" "the watcher cycle did not queue the due wake"
  pass "the watcher invokes the scan and surfaces the main-owned check wake"
}

test_invalid_wait_config_fails_closed() {
  local dir status=0 keys
  dir=$(make_case bad-config)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  printf '%s\n' 'ten minutes' > "$dir/home/config/pr-green-return"
  env FM_HOME="$dir/home" \
    FM_PR_GREEN_RETURN_POLICY="$dir/fix/policy.md" \
    FM_TEST_FIX="$dir/fix" FM_TEST_LOG="$dir/fix/calls.log" \
    FM_PR_GREEN_RETURN_FORCE=1 FM_PR_GREEN_RETURN_NOW="$NOW_LATE" \
    PATH="$dir/fakebin:$PATH" \
    "$GREEN" scan >/dev/null 2>"$dir/scan.err" || status=$?
  expect_code 2 "$status" "invalid wait config exit"
  assert_contains "$(cat "$dir/scan.err")" "pr-green-return" "the invalid config error did not name the file"
  keys=$(queue_keys "$dir")
  [ -z "$keys" ] || fail "an invalid wait config still queued a wake: $keys"
  pass "an invalid wait configuration stops the scan before any wake"
}

test_config_file_sets_the_wait() {
  local dir keys
  dir=$(make_case config-wait)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  printf '%s\n' 601 > "$dir/home/config/pr-green-return"
  env FM_HOME="$dir/home" \
    FM_PR_GREEN_RETURN_POLICY="$dir/fix/policy.md" \
    FM_TEST_FIX="$dir/fix" FM_TEST_LOG="$dir/fix/calls.log" \
    FM_PR_GREEN_RETURN_SECS= FM_PR_GREEN_RETURN_FORCE=1 \
    FM_PR_GREEN_RETURN_NOW="$((VERDICT_EPOCH + 600))" \
    PATH="$dir/fakebin:$PATH" \
    "$GREEN" scan >/dev/null 2>&1
  keys=$(queue_keys "$dir")
  [ -z "$keys" ] || fail "config/pr-green-return was not honored (woke inside its wait): $keys"
  assert_grep "class=due" "$dir/home/state/pr-green-return/t1" "the config-wait marker is missing"
  pass "config/pr-green-return sets the wait when no env override is present"
}

test_non_candidates_are_ignored() {
  local dir keys
  dir=$(make_case non-candidates)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  fm_write_meta "$dir/home/state/t9.meta" \
    "window=firstmate:fm-t9" \
    "kind=ship" \
    "mode=direct-PR"
  fm_write_secondmate_meta "$dir/home/state/mate1.meta" "$dir/mate-home"
  gh_green "$dir"
  scan_case "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  assert_contains "$keys" "pr-green-return:t1" "the PR candidate was not evaluated"
  assert_not_contains "$keys" "pr-green-return:t9" "a task without a pr= line became a candidate"
  assert_not_contains "$keys" "pr-green-return:mate1" "a secondmate route became a candidate"
  pass "a task without a pr= line, and a secondmate meta, are not candidates"
}

test_due_github_pr_wakes_the_bound_merge
test_wait_boundary_is_exact_and_persists
test_red_checks_hold_and_name_hard_stop_3
test_no_checks_hold_and_name_hard_stop_4
test_foreign_pr_holds_hard_stop_6
test_gate_holds_hard_stop_1
test_verdict_channel_is_advisory_and_holds_only_on_a_blocking_read
test_sensitive_diff_holds_hard_stop_5
test_lockfile_only_change_is_not_sensitive_on_a_mergeable_pr
test_package_json_scripts_qualifier
test_unreadable_policy_holds_hard_stop_7
test_allowlist_default_ask_holds
test_merged_pr_leaves_no_wake_or_record
test_forgejo_due_with_fresh_crabd_verdict
test_forgejo_verdict_channel
test_gitlab_needs_no_verdict_channel
test_report_is_read_only_and_names_the_hold
test_scan_cadence_suppresses_repeat_work
test_every_candidate_is_evaluated_in_one_scan
test_watcher_surfaces_the_green_return_check_wake
test_invalid_wait_config_fails_closed
test_config_file_sets_the_wait
test_non_candidates_are_ignored
