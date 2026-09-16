#!/usr/bin/env bash
# Tests for bin/fm-pr-green-return.sh: the bounded return path for a task's
# PR that is green, mergeable, and policy-clean but has not been merged.
#
# Matrix:
#   (a) an otherwise due GitHub PR queues the no-bound-merge hold report because
#       its merge path cannot bind the head, while Forgejo and GitLab queue the
#       bound-merge check wake with the verified head
#   (b) the wait boundary is exact (threshold - 1 silent, threshold exact wakes)
#       and a restart keeps the evidence-backed wait start instead of resetting;
#       a moved head is never counted as notified by the old head's queued
#       mandate and queues its own under the shared key, replacing the stale
#       row, even when the fresh verdict is a hold of the other class
#   (c) red CI holds the PR and names hard stop 3, never a merge; a head green
#       only through the policy's Coolify `deploy / deploy` preview waiver holds
#       for the protected merge path instead of a dead-end mandate; a skipped
#       status is a pass, a combined skipped head and a skipped GitLab pipeline
#       are no checks (hard stop 4), and a combined warning head is red
#   (d) a repo with no checks holds and names hard stop 4
#   (e) a foreign author holds and names hard stop 6
#   (f) a missing or open five-lens gate holds and names hard stop 1, per-lens
#       prose results outside the clean forms hold, a table row naming an open
#       finding or lacking covering counts holds while a covered refuted cell
#       passes, and clean per-lens prose or a clean table passes; a no-mistakes
#       task reads the exact-titled PR comment of the authenticated operator as
#       its gate source, an open, missing, foreign-authored, or untitled
#       comment still holds, and the direct-PR body path is unchanged
#   (g) a missing, negative, or stale review verdict holds and names hard stop 2
#   (g) the advisory review verdict holds only a blocking verdict or an
#       unreadable channel, and names hard stop 2, while a missing or stale
#       verdict does not hold the merge
#   (h) a sensitive diff path, a built-in `.forgejo/workflows` path, a rename
#       out of a sensitive path, an unreadable changed-file list, a Forgejo file
#       list whose sensitive path is beyond a truncated page, and a GitLab
#       changes overflow hold and name hard stop 5
#   (i) a package.json version-only change is not sensitive, a scripts change is
#       held by hard stop 5, and a mergeable lockfile - alone or beside
#       package.json - is not held (the policy applies those globs only on
#       conflict)
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
#   (v) a candidate killed inside a slow provider call still advances the
#       persisted rotation, so the next scan evaluates the candidates behind it
#   (w) an allowlist policy and a denylist policy each parse their posture, a
#       denylist wait-list hit holds while an unlisted repo stays due, a
#       qualified owner/repo row matches in both postures, a denylist row
#       outside ask/deny fails closed under hard stop 7, and a missing or
#       unrecognized posture holds every candidate under hard stop 7
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
[ -z "${FM_TEST_TEA_SLEEP:-}" ] || sleep "$FM_TEST_TEA_SLEEP"
fixed=$FM_TEST_FIX
case "${1:-} ${2:-}" in
  "api /user") cat "$fixed/tea-user.json" ;;
  "api "*)
    case "$2" in
      */pulls/*/files*)
        page=1
        case "$2" in
          *page=*) page=${2##*page=}; page=${page%%&*} ;;
        esac
        if [ -f "$fixed/tea-files-page$page.json" ]; then
          cat "$fixed/tea-files-page$page.json"
        elif [ -f "$fixed/tea-files.json" ]; then
          cat "$fixed/tea-files.json"
        else
          printf '[]\n'
        fi
        ;;
      */pulls/*) cat "$fixed/tea-pull.json" ;;
      */git/commits/*) cat "$fixed/tea-commit.json" ;;
      */commits/*/status) cat "$fixed/tea-status.json" ;;
      */issues/*/comments*)
        page=1
        case "$2" in
          *page=*) page=${2##*page=}; page=${page%%&*} ;;
        esac
        if [ -f "$fixed/tea-comments-page$page.json" ]; then
          cat "$fixed/tea-comments-page$page.json"
        elif [ -f "$fixed/tea-comments.json" ]; then
          cat "$fixed/tea-comments.json"
        else
          printf '[]\n'
        fi
        ;;
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

# policy_tail: the hard-stop-5 glob block every policy fixture shares, so the
# allowlist and denylist writers only vary the header and the rule table.
policy_tail() {
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
}

# write_policy <dir> <allowlisted repo name...>: the allowlist shape, with the
# trailing text after the posture value the real policy file carries.
write_policy() { # <dir> <allowlisted repo name...>
  local dir=$1
  shift
  {
    printf '# PR-Merge-Policy\n\n'
    printf 'Posture: allowlist.  Set up: fixture.\n\n'
    printf '## The rule\n\nDefault is ask.\n\n'
    printf '| Repo | [Autonomous | Ask] | Why |\n|---|---|---|\n'
    local repo
    for repo in "$@"; do
      printf '| %s | Autonomous | fixture |\n' "$repo"
    done
    policy_tail
  } > "$dir/fix/policy.md"
}

# write_denylist_policy <dir> <verdict>:<repo>...: the denylist shape, whose
# third column names the wait list. The verdict is the literal Ask or Deny the
# policy file carries; the repo name is the remote slug.
write_denylist_policy() { # <dir> <verdict>:<repo>...
  local dir=$1 spec verdict repo
  shift
  {
    printf '# PR-Merge-Policy\n\n'
    printf 'Posture: denylist\n\n'
    printf '## The rule\n\nDefault is auto.\n\n'
    printf '| Repo | [Wait | Auto] | Why |\n|---|---|---|\n'
    for spec in "$@"; do
      verdict=${spec%%:*}
      repo=${spec#*:}
      printf '| %s | %s | fixture |\n' "$repo" "$verdict"
    done
    policy_tail
  } > "$dir/fix/policy.md"
}

write_meta() { # <dir> <id> <url> [project-name] [mode]
  local dir=$1 id=$2 url=$3 project=${4:-project} mode=${5:-direct-PR}
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "kind=ship" \
    "mode=$mode" \
    "project=$dir/projects/$project" \
    "pr=$url" \
    "pr_head=$HEAD"
}

# write_gate_table [<code-review findings> [<code-review fixed>]]: the five-lens
# result table the gate fixtures share, with the first row's cells as optional
# parameters; every other lens row stays clean.
write_gate_table() { # [<findings> [<fixed>]]
  printf '| Lens | Ran | Findings | Fixed |\n|---|---|---|---|\n| code-review | yes | %s | %s |\n| maintainability-review | yes | 0 | 0 |\n| architecture-system-design-reviewer | yes | 0 | 0 |\n| design-decision-questioner | yes | 0 | 0 |\n| self-containment-review | yes | 0 | 0 |' "${1:-0}" "${2:-0}"
}

# gate_body_case <name> <body>: build a Forgejo task case whose body is the
# given five-lens block, and echo the case directory.
gate_body_case() { # <name> <body>
  local dir
  dir=$(make_case "$1")
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  tea_set_body "$dir" "$2"
  printf '%s\n' "$dir"
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

# gh_set_five_lens_comment <dir> <body|none> [title] [author]: rewrite the
# GitHub comment fixture with the verdict comment and, unless `none`, one
# designated five-lens comment. The title and the comment author can be
# overridden to pin the exact-title and operator-author rules.
gh_set_five_lens_comment() { # <dir> <body|none> [title] [author]
  local dir=$1 body=$2 title=${3:-Findings and fixes from 5-lenses-review} author=${4:-op} tmp
  tmp=$(mktemp)
  if [ "$body" = none ]; then
    jq -n --arg time "$VERDICT_TIME" \
      '[[{user: {login: "seibert-pr-agent"}, created_at: $time, updated_at: $time, body: "**Verdict:** Good to merge\n"}]]' > "$tmp"
  else
    jq -n --arg time "$VERDICT_TIME" --arg title "$title" --arg body "$body" --arg author "$author" \
      '[[{user: {login: "seibert-pr-agent"}, created_at: $time, updated_at: $time, body: "**Verdict:** Good to merge\n"},
        {user: {login: $author}, created_at: $time, updated_at: $time, body: ($title + "\n\n" + $body)}]]' > "$tmp"
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
    '[{id: 1, user: {login: "seibert-pr-agent"}, updated_at: $time, body: "Reviewed this pull request — **Good to merge (LGTM).**\n<!-- crabd:tracking -->"}]' \
    > "$dir/fix/tea-comments.json"
  jq -n '[{filename: "src/app.ts"}]' > "$dir/fix/tea-files.json"
  printf '%s\n' '{"login":"op"}' > "$dir/fix/tea-user.json"
}

tea_set_verdict() { # <dir> <body-json>
  local dir=$1
  jq -n --arg time "$VERDICT_TIME" --arg body "$2" \
    '[{id: 1, user: {login: "seibert-pr-agent"}, updated_at: $time, body: $body}]' \
    > "$dir/fix/tea-comments.json"
}

# tea_set_five_lens_comment <dir> <body|none> [title] [author]: rewrite the
# Forgejo comment fixture with the crabd verdict comment and, unless `none`,
# one designated five-lens comment. The title and the comment author can be
# overridden to pin the exact-title and operator-author rules.
tea_set_five_lens_comment() { # <dir> <body|none> [title] [author]
  local dir=$1 body=$2 title=${3:-Findings and fixes from 5-lenses-review} author=${4:-op} tmp
  tmp=$(mktemp)
  if [ "$body" = none ]; then
    jq -n --arg time "$VERDICT_TIME" \
      '[{id: 1, user: {login: "seibert-pr-agent"}, updated_at: $time, body: "Reviewed this pull request - **Good to merge (LGTM).**\n<!-- crabd:tracking -->"}]' > "$tmp"
  else
    jq -n --arg time "$VERDICT_TIME" --arg title "$title" --arg body "$body" --arg author "$author" \
      '[{id: 1, user: {login: "seibert-pr-agent"}, updated_at: $time, body: "Reviewed this pull request - **Good to merge (LGTM).**\n<!-- crabd:tracking -->"},
        {id: 2, user: {login: $author}, updated_at: $time, body: ($title + "\n\n" + $body)}]' > "$tmp"
  fi
  mv "$tmp" "$dir/fix/tea-comments.json"
}

tea_set_body() { # <dir> <body>
  local dir=$1 tmp
  tmp=$(mktemp)
  jq --arg body "$2" '.body = $body' "$dir/fix/tea-pull.json" > "$tmp"
  mv "$tmp" "$dir/fix/tea-pull.json"
}

tea_set_checks() { # <dir> <state> <statuses-json>
  local dir=$1 state=$2 statuses=$3
  jq -n --arg head "$HEAD" --arg state "$state" --argjson statuses "$statuses" \
    '{sha: $head, state: $state, total_count: ($statuses | length), statuses: $statuses}' \
    > "$dir/fix/tea-status.json"
}

# tea_move_head <dir> <head> <commit-time>: move the Forgejo fixture to a new
# head with its own commit time and a fresh matching verdict.
tea_move_head() { # <dir> <head> <time>
  local dir=$1 head=$2 time=$3 tmp
  tmp=$(mktemp)
  jq --arg head "$head" '.head.sha = $head' "$dir/fix/tea-pull.json" > "$tmp"
  mv "$tmp" "$dir/fix/tea-pull.json"
  jq -n --arg head "$head" '{sha: $head, state: "success", total_count: 2}' > "$dir/fix/tea-status.json"
  jq -n --arg time "$time" '{created: $time}' > "$dir/fix/tea-commit.json"
  jq -n --arg time "$time" \
    '[{id: 1, user: {login: "seibert-pr-agent"}, updated_at: $time, body: "Reviewed this pull request — **Good to merge (LGTM).**\n<!-- crabd:tracking -->"}]' \
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
  jq -n '{changes: [{new_path: "src/app.ts"}], overflow: false}' > "$dir/fix/glab-changes.json"
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

# presented_rows <dir>: the drain's newest-row-per-key view of the queue, i.e.
# exactly the rows a wake drain offers main, computed by the same function the
# drain uses.
presented_rows() { # <dir>
  local queue=$1/home/state/.wake-queue
  [ -f "$queue" ] || return 0
  FM_STATE_OVERRIDE="$1/home/state" bash -c '. "$1"; fm_wake_print_deduped "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$queue" 2>/dev/null || true
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

test_github_pr_holds_without_a_bound_merge() {
  local dir keys rows marker
  dir=$(make_case github-nobound)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  marker="$dir/home/state/pr-green-return/t1"
  assert_contains "$keys" "pr-green-return:t1" "an otherwise due GitHub PR did not queue the hold report"
  assert_not_contains "$rows" "merge it bound now" "a GitHub PR queued a bound-merge wake its merge path cannot honor"
  assert_contains "$rows" "no bound merge" "the GitHub hold payload did not say a bound merge is impossible"
  assert_contains "$rows" "do not merge" "the GitHub hold payload did not forbid the merge"
  assert_grep "class=held" "$marker" "the GitHub marker class is not held"
  assert_no_grep "pr merge" "$dir/fix/calls.log" "the scan attempted a merge verb"
  pass "an otherwise due GitHub PR is held because its merge path cannot bind the head"
}

test_wait_boundary_is_exact_and_persists() {
  local dir keys
  dir=$(make_case wait)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
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

test_moved_head_queues_its_own_mandate() {
  local dir keys rows out marker newest presented head2 h2_epoch
  head2=3333333333333333333333333333333333333333
  h2_epoch=$((VERDICT_EPOCH + 1200))
  dir=$(make_case moved-head)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  marker="$dir/home/state/pr-green-return/t1"

  # The verified head holds the wait and queues its mandate.
  out=$(scan_case "$dir" "$NOW_LATE")
  assert_contains "$out" "head $HEAD" "the verified head did not queue its mandate"
  assert_grep "head=$HEAD" "$marker" "the record did not name the verified head"
  assert_grep "notified=due:$HEAD" "$marker" "the verified head was not marked notified"
  [ "$(queue_keys "$dir" | grep -c 'pr-green-return:t1')" = 1 ] || fail "the verified head was not queued exactly once"

  # The branch moves to a new head: the old mandate must not be counted for it.
  tea_move_head "$dir" "$head2" "2026-01-01T00:30:00Z"
  out=$(scan_case "$dir" "$((h2_epoch + 100))")
  assert_not_contains "$out" "head $head2" "the moved head queued a mandate before its wait"
  assert_grep "head=$head2" "$marker" "the record did not name the moved head"
  assert_no_grep "notified=due:$head2" "$marker" "the moved head was claimed notified before its wait"
  [ "$(queue_keys "$dir" | grep -c 'pr-green-return:t1')" = 1 ] || fail "the moved head was queued before its wait"

  # When its own wait elapses, the moved head queues its own mandate under the
  # same key; the newest row for that key is the moved head's, so the stale one
  # is replaced rather than presented beside it.
  out=$(scan_case "$dir" "$((h2_epoch + 600))")
  assert_contains "$out" "head $head2" "the moved head did not queue its own mandate"
  assert_grep "notified=due:$head2" "$marker" "the moved head was not marked notified"
  [ "$(queue_keys "$dir" | grep -c 'pr-green-return:t1')" = 2 ] || fail "the moved head did not queue its own mandate beside the stale row"
  rows=$(queue_rows "$dir")
  newest=$(printf '%s\n' "$rows" | awk -F'\t' '$4 == "pr-green-return:t1" { row = $0 } END { print row }')
  assert_contains "$newest" "head $head2" "the newest queued mandate does not name the moved head"
  presented=$(presented_rows "$dir")
  [ "$(printf '%s\n' "$presented" | grep -c .)" = 1 ] || fail "the drain presentation offered the stale mandate beside the moved head's"
  assert_not_contains "$presented" "head $HEAD" "the presented mandate still names the stale head"

  # An unchanged moved head queues nothing further.
  scan_case "$dir" "$((h2_epoch + 900))" >/dev/null
  [ "$(queue_keys "$dir" | grep -c 'pr-green-return:t1')" = 2 ] || fail "an unchanged head queued a duplicate mandate"
  pass "a moved head queues its own mandate and a stale row is not counted for it"
}

test_cross_class_verdict_supersedes_the_stale_mandate() {
  local dir marker presented head2 h2_epoch
  head2=4444444444444444444444444444444444444444
  h2_epoch=$((VERDICT_EPOCH + 1200))
  dir=$(make_case cross-class)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  marker="$dir/home/state/pr-green-return/t1"

  # The verified head is due and its bound-merge mandate is queued, undrained.
  scan_case "$dir" "$NOW_LATE" >/dev/null
  assert_grep "notified=due:$HEAD" "$marker" "the due head was not marked notified"
  assert_contains "$(presented_rows "$dir")" "merge it bound now" "the due head did not present its mandate"

  # The branch moves to a head whose diff adds .forgejo/workflows ground, so the
  # fresh verdict is a hard-stop-5 hold while the stale mandate is still queued.
  tea_move_head "$dir" "$head2" "2026-01-01T00:30:00Z"
  jq -n '[{filename: ".forgejo/workflows/ci.yml"}, {filename: "src/app.ts"}]' > "$dir/fix/tea-files.json"
  scan_case "$dir" "$h2_epoch" >/dev/null
  scan_case "$dir" "$((h2_epoch + 600))" >/dev/null
  assert_grep "notified=held:$head2:hard-stop-5" "$marker" "the moved head's hold was not recorded"

  presented=$(presented_rows "$dir")
  [ "$(printf '%s\n' "$presented" | grep -c .)" = 1 ] || fail "the drain presentation offered the stale mandate beside the hold"
  assert_contains "$presented" "head $head2" "the presented row does not name the moved head"
  assert_contains "$presented" "hard stop 5" "the presented row does not name the hold reason"
  assert_contains "$presented" "do not merge" "the presented row does not forbid the merge"
  assert_not_contains "$presented" "merge it bound now" "the stale due mandate is still presented beside the hold"

  # The held moved head is notified once: another scan adds no row.
  scan_case "$dir" "$((h2_epoch + 900))" >/dev/null
  presented=$(presented_rows "$dir")
  [ "$(printf '%s\n' "$presented" | grep -c .)" = 1 ] || fail "an unchanged held head queued a duplicate"
  pass "a fresh hold supersedes the stale due mandate under the shared wake key"
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
  assert_contains "$keys" "pr-green-return:t1" "red CI did not queue the hold wake"
  assert_not_contains "$rows" "merge it bound now" "red CI queued a merge wake"
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
  assert_contains "$keys" "pr-green-return:t1" "a repo without checks did not hold"
  assert_not_contains "$rows" "merge it bound now" "a repo without checks queued a merge wake"
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
  assert_contains "$keys" "pr-green-return:t1" "a foreign PR did not hold"
  assert_contains "$rows" "hard stop 6" "the hold payload did not name hard stop 6"
  assert_not_contains "$rows" "merge it bound now" "a foreign PR queued a merge wake"
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
  assert_contains "$keys" "pr-green-return:t1" "a missing gate block did not hold"
  assert_contains "$rows" "hard stop 1" "the hold payload did not name hard stop 1"

  dir=$(make_case gate-open)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  gh_set_body "$dir" $'## Five-lens gate\n\n| Lens | Ran | Findings | Fixed |\n|---|---|---|---|\n| code-review | yes | 3 | 0 |\n| maintainability-review | yes | 0 | 0 |\n| architecture-system-design-reviewer | yes | 0 | 0 |\n| design-decision-questioner | yes | 0 | 0 |\n| self-containment-review | yes | 0 | 0 |\n\nResult: 3 findings, 1 open\n'
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  assert_contains "$(queue_keys "$dir")" "pr-green-return:t1" "an open gate finding did not hold"
  pass "a missing or open five-lens gate holds and names hard stop 1"
}

test_verdict_channel_is_advisory_and_holds_only_on_a_blocking_read() {
  local dir keys rows out
  # A verdict that never arrives trips nothing; on GitHub the only remaining
  # hold is that the merge path cannot bind the head, never item 2.
  dir=$(make_case verdict-missing)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  gh_set_verdict "$dir" none
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" "no-bound-merge" "a missing verdict was not treated as advisory"
  assert_not_contains "$out" "hard-stop-2" "a missing verdict tripped hard stop 2"

  # A blocking verdict is held for the captain's own read, naming item 2.
  dir=$(make_case verdict-negative)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  gh_set_verdict "$dir" "Please fix the comments before merging"
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return:t1" "a blocking verdict did not hold"
  assert_contains "$rows" "hard stop 2" "a blocking verdict did not name hard stop 2"
  assert_not_contains "$rows" "merge it bound now" "a blocking verdict queued a merge wake"

  # A positive verdict older than the head is advisory like any other: it does
  # not trip item 2 on its own.
  dir=$(make_case verdict-stale)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  gh_set_head_time "$dir" "2026-01-01T00:12:00Z"
  out=$(report_case "$dir" "$NOW_LATE")
  assert_not_contains "$out" "hard-stop-2" "a stale positive verdict tripped hard stop 2"

  # A channel that cannot be read still holds: a blocking verdict could be
  # hiding behind the failed read.
  dir=$(make_case verdict-unreadable)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  rm -f "$dir/fix/gh-comments.json"
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  assert_contains "$(queue_keys "$dir")" "pr-green-return:t1" "an unreadable verdict channel did not hold"
  assert_contains "$(queue_rows "$dir")" "hard stop 2" "an unreadable verdict channel did not name hard stop 2"
  pass "the advisory verdict holds only a blocking or unreadable read"
}

test_sensitive_diff_holds_hard_stop_5() {
  local dir keys rows out
  dir=$(make_case sensitive)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  gh_set_files "$dir" $'.github/workflows/ci.yml\nsrc/app.ts'
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return:t1" "a sensitive diff did not hold"
  assert_contains "$rows" "hard stop 5" "a sensitive diff did not name hard stop 5"
  assert_contains "$rows" ".github/workflows/ci.yml" "the hold payload did not name the sensitive path"
  assert_not_contains "$rows" "merge it bound now" "a sensitive diff queued a merge wake"

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
  assert_contains "$keys" "pr-green-return:t1" "an unreadable file list did not hold"
  assert_contains "$rows" "hard stop 5" "an unreadable file list did not name hard stop 5"
  assert_not_contains "$rows" "merge it bound now" "an unreadable file list queued a merge wake"

  # `.forgejo/workflows/**` is built-in ground even though the fixture policy's
  # glob block omits it: a Forgejo workflow change holds under hard stop 5.
  dir=$(make_case sensitive-forgejo-workflow)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  jq -n '[{filename: ".forgejo/workflows/ci.yml"}, {filename: "src/app.ts"}]' > "$dir/fix/tea-files.json"
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return:t1" "a .forgejo/workflows change did not hold"
  assert_contains "$rows" "hard stop 5" "a .forgejo/workflows change did not name hard stop 5"
  assert_contains "$rows" ".forgejo/workflows/ci.yml" "the hold payload did not name the sensitive path"
  assert_not_contains "$rows" "merge it bound now" "a .forgejo/workflows change queued a merge wake"

  # A `.forgejo` path outside the workflows directory stays due, so the
  # built-in ground is exactly `.forgejo/workflows/**`.
  dir=$(make_case sensitive-forgejo-normal)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  jq -n '[{filename: ".forgejo/config.yml"}, {filename: "src/app.ts"}]' > "$dir/fix/tea-files.json"
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" $'t1\tdue\tready' "a non-workflow .forgejo path was held"

  # A legal filename with two consecutive dots still reaches the sensitive
  # globs; only real traversal segments are excluded.
  dir=$(make_case sensitive-forgejo-dotdot)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  jq -n '[{filename: "src/auth/a..b.ts"}]' > "$dir/fix/tea-files.json"
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return:t1" "a double-dot filename on auth ground did not hold"
  assert_contains "$rows" "hard stop 5" "a double-dot filename on auth ground did not name hard stop 5"
  assert_contains "$rows" "src/auth/a..b.ts" "the hold payload did not name the double-dot path"
  assert_not_contains "$rows" "merge it bound now" "a double-dot filename on auth ground queued a merge wake"

  dir=$(make_case sensitive-forgejo-dotdot-normal)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  jq -n '[{filename: "src/a..b.ts"}]' > "$dir/fix/tea-files.json"
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" $'t1\tdue\tready' "a non-sensitive double-dot filename was held"

  # A rename out of a sensitive path contributes its old path, so the change
  # still holds under hard stop 5; a rename within non-sensitive paths stays due.
  dir=$(make_case sensitive-forgejo-rename-out)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  jq -n '[{filename: "src/guard.ts", previous_filename: "src/auth/guard.ts", status: "renamed"}]' > "$dir/fix/tea-files.json"
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return:t1" "a rename out of src/auth did not hold"
  assert_contains "$rows" "hard stop 5" "a rename out of src/auth did not name hard stop 5"
  assert_contains "$rows" "src/auth/guard.ts" "the hold payload did not name the old sensitive path"
  assert_not_contains "$rows" "merge it bound now" "a rename out of src/auth queued a merge wake"

  dir=$(make_case sensitive-forgejo-rename-normal)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  jq -n '[{filename: "src/guard.ts", previous_filename: "src/util/guard.ts", status: "renamed"}]' > "$dir/fix/tea-files.json"
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" $'t1\tdue\tready' "a rename within non-sensitive paths was held"

  # GitLab reports a rename's old path as `old_path`; the sensitive match must
  # see it too, and a within-non-sensitive rename must not falsely hold.
  dir=$(make_case sensitive-gitlab-rename-out)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://gitlab.example/group/project/-/merge_requests/7"
  glab_green "$dir"
  jq -n '{changes: [{new_path: "src/guard.ts", old_path: "src/auth/guard.ts"}], overflow: false}' > "$dir/fix/glab-changes.json"
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return:t1" "a GitLab rename out of src/auth did not hold"
  assert_contains "$rows" "hard stop 5" "a GitLab rename out of src/auth did not name hard stop 5"
  assert_contains "$rows" "src/auth/guard.ts" "the GitLab hold payload did not name the old sensitive path"
  assert_not_contains "$rows" "merge it bound now" "a GitLab rename out of src/auth queued a merge wake"

  dir=$(make_case sensitive-gitlab-rename-normal)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://gitlab.example/group/project/-/merge_requests/7"
  glab_green "$dir"
  jq -n '{changes: [{new_path: "src/guard.ts", old_path: "src/util/guard.ts"}], overflow: false}' > "$dir/fix/glab-changes.json"
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" $'t1\tdue\tready' "a GitLab rename within non-sensitive paths was held"
  pass "a sensitive diff path holds and names hard stop 5"
}

test_lockfile_only_change_is_not_sensitive_on_a_mergeable_pr() {
  local dir keys
  dir=$(make_case lockfile)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  jq -n '[{filename: "pnpm-lock.yaml"}, {filename: "src/app.ts"}]' > "$dir/fix/tea-files.json"
  scan_case "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  assert_contains "$keys" "pr-green-return:t1" "a mergeable lockfile-only change was held"
  assert_not_contains "$(queue_rows "$dir")" "do not merge" "a mergeable lockfile-only change queued a hold"
  pass "a lockfile change is not sensitive on a mergeable PR (policy: only on conflict)"
}

test_package_json_scripts_qualifier() {
  local dir keys rows
  dir=$(make_case pkg-version)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  jq -n '[{filename: "package.json"}]' > "$dir/fix/tea-files.json"
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
  assert_contains "$keys" "pr-green-return:t1" "a scripts change did not hold"
  assert_contains "$rows" "hard stop 5" "a scripts change did not name hard stop 5"
  assert_not_contains "$rows" "merge it bound now" "a scripts change queued a merge wake"
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
  assert_contains "$keys" "pr-green-return:t1" "an unreadable policy did not hold"
  assert_contains "$rows" "hard stop 7" "an unreadable policy did not name hard stop 7"
  assert_not_contains "$rows" "merge it bound now" "an unreadable policy queued a merge wake"
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
  assert_contains "$keys" "pr-green-return:t1" "an unlisted repo did not hold"
  assert_contains "$rows" "the policy default ask" "the hold payload did not name the default ask"
  assert_not_contains "$rows" "merge it bound now" "an unlisted repo queued a merge wake"
  pass "a repo outside the allowlist is held as the policy default ask"
}

test_denylist_wait_list_holds_listed_repos() {
  local dir keys rows verdict
  for verdict in Ask Deny; do
    dir=$(make_case "denylist-hit-$verdict")
    write_denylist_policy "$dir" "$verdict:programmieren-community"
    write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
    tea_green "$dir"
    scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
    keys=$(queue_keys "$dir")
    rows=$(queue_rows "$dir")
    assert_contains "$keys" "pr-green-return:t1" "a $verdict-listed repo did not hold under a denylist policy"
    assert_contains "$rows" "the policy wait list" "the $verdict hold payload did not name the wait list"
    assert_not_contains "$rows" "the policy default ask" "the $verdict hold reused the allowlist default-ask label"
    assert_not_contains "$rows" "merge it bound now" "a $verdict-listed repo queued a merge wake"
  done
  pass "a repo on the denylist wait list is held for every listed verdict"
}

test_denylist_unrecognized_verdict_holds_hard_stop_7() {
  local dir keys rows verdict
  for verdict in Sometimes Autonomous; do
    dir=$(make_case "denylist-bad-verdict-$verdict")
    write_denylist_policy "$dir" "$verdict:programmieren-community"
    write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
    tea_green "$dir"
    scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
    keys=$(queue_keys "$dir")
    rows=$(queue_rows "$dir")
    assert_contains "$keys" "pr-green-return:t1" "a denylist row with a $verdict verdict did not hold"
    assert_contains "$rows" "hard stop 7" "a denylist row with a $verdict verdict did not name hard stop 7"
    assert_not_contains "$rows" "merge it bound now" "a denylist row with a $verdict verdict queued a merge wake"
  done
  pass "a denylist table row outside ask/deny fails closed under hard stop 7"
}

test_denylist_unlisted_repo_is_due() {
  local dir keys rows
  dir=$(make_case denylist-due)
  write_denylist_policy "$dir" "Ask:some-other-repo"
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  scan_case "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return:t1" "an unlisted repo was not due under a denylist policy"
  assert_contains "$rows" "due" "the denylist due payload is missing"
  assert_contains "$rows" "bin/fm-pr-merge.sh t1 https://forgejo.example/seibert.group/programmieren-community/pulls/365 --expected-head $HEAD" "the denylist due payload is missing the head-bound merge command"
  assert_not_contains "$rows" "hard stop 7" "the denylist policy was not read"
  pass "a repo off the denylist wait list is due under the bound merge"
}

test_qualified_policy_rows_match_the_full_path() {
  local dir keys rows
  dir=$(make_case denylist-qualified-hit)
  write_denylist_policy "$dir" "Ask:seibert.group/programmieren-community"
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return:t1" "a qualified denylist row did not hold the repo"
  assert_contains "$rows" "wait list" "a qualified denylist hold did not name the wait list"
  assert_not_contains "$rows" "merge it bound now" "a qualified denylist row queued a merge wake"

  dir=$(make_case allowlist-qualified-hit)
  write_policy "$dir" seibert.group/programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  scan_case "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return:t1" "a qualified allowlist row was not autonomous"
  assert_contains "$rows" "merge it bound now" "a qualified allowlist row queued no bound-merge mandate"
  assert_not_contains "$rows" "hard stop 7" "the qualified allowlist policy was not read"
  pass "a qualified owner/repo policy row matches in both postures"
}

test_missing_or_unknown_posture_holds_hard_stop_7() {
  local dir keys rows name
  for name in missing unknown; do
    dir=$(make_case "policy-posture-$name")
    {
      printf '# PR-Merge-Policy\n\n'
      [ "$name" = unknown ] && printf 'Posture: sometimes\n\n'
      printf '## The rule\n\nDefault is ask.\n\n'
      printf '| Repo | [Autonomous | Ask] | Why |\n|---|---|---|\n'
      printf '| some-other-repo | Autonomous | fixture |\n'
      policy_tail
    } > "$dir/fix/policy.md"
    write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
    tea_green "$dir"
    scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
    keys=$(queue_keys "$dir")
    rows=$(queue_rows "$dir")
    assert_contains "$keys" "pr-green-return:t1" "a $name posture did not hold"
    assert_contains "$rows" "hard stop 7" "a $name posture did not name hard stop 7"
    assert_not_contains "$rows" "merge it bound now" "a $name posture queued a merge wake"
  done
  pass "a missing or unrecognized posture holds every candidate and names hard stop 7"
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
  assert_contains "$rows" "bin/fm-pr-merge.sh t1 https://forgejo.example/seibert.group/programmieren-community/pulls/365 --expected-head $HEAD" "the Forgejo due payload is missing the head-bound merge command"
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
  assert_not_contains "$(queue_rows "$dir")" "do not merge" "a missing crabd verdict queued a hold"

  dir=$(make_case forgejo-legacy)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  tea_set_verdict "$dir" $'**Verdict:** Good to merge\n<!-- crabd:tracking -->\n<!-- pr-agent-rate-limit -->'
  scan_case "$dir" "$NOW_LATE" >/dev/null
  assert_contains "$(queue_keys "$dir")" "pr-green-return:t1" "a legacy Qodo verdict held the merge"
  assert_not_contains "$(queue_rows "$dir")" "do not merge" "a legacy Qodo verdict queued a hold"

  dir=$(make_case forgejo-blocking)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  tea_set_verdict "$dir" $'Reviewed this pull request — **Please address the findings before merging.**\n<!-- crabd:tracking -->'
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  assert_contains "$(queue_keys "$dir")" "pr-green-return:t1" "a blocking crabd verdict did not hold"
  assert_contains "$(queue_rows "$dir")" "hard stop 2" "a blocking crabd verdict did not name hard stop 2"
  pass "a missing or legacy Forgejo verdict does not hold, a blocking one does"
}

test_gitlab_needs_no_verdict_channel() {
  local dir keys rows
  dir=$(make_case gitlab)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://gitlab.example/group/project/-/merge_requests/7"
  glab_green "$dir"
  scan_case "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return:t1" "a GitLab MR without a policy verdict channel was not due"
  assert_not_contains "$rows" "do not merge" "a GitLab MR queued a verdict hold"
  assert_contains "$rows" "bin/fm-pr-merge.sh t1 https://gitlab.example/group/project/-/merge_requests/7 --expected-head $HEAD" "the GitLab due payload is missing the head-bound merge command"
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
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  scan_case "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  assert_contains "$keys" "pr-green-return:t1" "the first scan did not queue the due wake"
  tea_set_checks "$dir" failure '[{"context": "CI / lint (pull_request)", "status": "failure"}]'
  env FM_HOME="$dir/home" \
    FM_PR_GREEN_RETURN_POLICY="$dir/fix/policy.md" \
    FM_TEST_FIX="$dir/fix" FM_TEST_LOG="$dir/fix/calls.log" \
    FM_PR_GREEN_RETURN_SECS=600 FM_PR_GREEN_RETURN_INTERVAL=999999 \
    FM_PR_GREEN_RETURN_NOW="$((NOW_LATE + 60))" PATH="$dir/fakebin:$PATH" \
    "$GREEN" scan >/dev/null 2>&1
  assert_not_contains "$(queue_rows "$dir")" "do not merge" "the cadence gate did not suppress a repeat scan"
  pass "the scan cadence suppresses repeated work between configured intervals"
}

test_every_candidate_is_evaluated_in_one_scan() {
  local dir keys
  dir=$(make_case two-tasks)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  write_meta "$dir" t2 "https://forgejo.example/seibert.group/programmieren-community/pulls/366" programmieren-community
  tea_green "$dir"
  scan_case "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  assert_contains "$keys" "pr-green-return:t1" "the first candidate was not evaluated"
  assert_contains "$keys" "pr-green-return:t2" "the second candidate was not evaluated"
  pass "every candidate is evaluated in one scan"
}

test_slow_candidate_does_not_starve_the_rotation() {
  local dir rc
  dir=$(make_case slow-candidate)
  write_policy "$dir" programmieren-community project
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  write_meta "$dir" t2 "https://gitlab.example/group/project/-/merge_requests/7" project
  tea_green "$dir"
  glab_green "$dir"

  # t1's forge hangs past the scan backstop, so the first scan is killed while
  # t1 is being attempted and its wake is never queued.
  set +e
  scan_case "$dir" "$NOW_LATE" FM_TEST_TEA_SLEEP=10 \
    FM_PR_GREEN_RETURN_BUDGET_SECS=2 FM_PR_GREEN_RETURN_CMD_TIMEOUT=30 >/dev/null
  rc=$?
  set -e
  expect_code 0 "$rc" "slow-candidate: a backstop-killed scan is not a scan failure"
  assert_not_contains "$(queue_keys "$dir")" "pr-green-return:t1" \
    "the slow candidate queued a wake before its provider answered"

  # The next scan starts after the attempted candidate, so the GitLab candidate
  # behind it is evaluated and queues its wake even though t1 hangs again.
  set +e
  scan_case "$dir" "$NOW_LATE" FM_TEST_TEA_SLEEP=10 \
    FM_PR_GREEN_RETURN_BUDGET_SECS=2 FM_PR_GREEN_RETURN_CMD_TIMEOUT=30 >/dev/null
  rc=$?
  set -e
  expect_code 0 "$rc" "slow-candidate: the second backstop-killed scan is not a scan failure"
  assert_contains "$(queue_keys "$dir")" "pr-green-return:t2" \
    "the candidate behind the slow one was starved by the killed scan"
  assert_not_contains "$(queue_keys "$dir")" "pr-green-return:t1" \
    "the slow candidate queued a wake without answering"
  pass "a candidate killed inside a slow provider call advances the rotation for the next scan"
}

test_watcher_surfaces_the_green_return_check_wake() {
  local dir status=0
  dir=$(make_case watcher)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
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
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
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
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  fm_write_meta "$dir/home/state/t9.meta" \
    "window=firstmate:fm-t9" \
    "kind=ship" \
    "mode=direct-PR"
  fm_write_secondmate_meta "$dir/home/state/mate1.meta" "$dir/mate-home"
  tea_green "$dir"
  scan_case "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  assert_contains "$keys" "pr-green-return:t1" "the PR candidate was not evaluated"
  assert_not_contains "$keys" "pr-green-return:t9" "a task without a pr= line became a candidate"
  assert_not_contains "$keys" "pr-green-return:mate1" "a secondmate route became a candidate"
  pass "a task without a pr= line, and a secondmate meta, are not candidates"
}

test_coolify_preview_check_is_waived() {
  local dir keys rows out
  # Only the policy's named Coolify preview poller fails: the head stays
  # policy-clean, but the protected merge path refuses the non-success combined
  # status, so the scan queues the hold report instead of a dead-end mandate.
  dir=$(make_case coolify-waived)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  tea_set_checks "$dir" failure '[{"context": "deploy / deploy (pull_request)", "status": "failure"}, {"context": "CI / test (pull_request)", "status": "success"}]'
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return:t1" "the waived Coolify preview did not queue the merge-path hold"
  assert_contains "$rows" "no bound merge" "the merge-path hold did not name the bound merge"
  assert_contains "$rows" "preview" "the merge-path hold did not name the red preview check"
  assert_not_contains "$rows" "merge it bound now" "the waived Coolify preview queued a dead-end merge mandate"

  # Any other failing check still holds under hard stop 3.
  dir=$(make_case coolify-other-red)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  tea_set_checks "$dir" failure '[{"context": "deploy / deploy (pull_request)", "status": "failure"}, {"context": "CI / lint (pull_request)", "status": "failure"}]'
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return:t1" "a real failing check beside the waived preview did not hold"
  assert_contains "$rows" "hard stop 3" "a real failing check beside the waived preview did not name hard stop 3"
  assert_not_contains "$rows" "merge it bound now" "a red check set queued a merge wake"

  # The GitHub path applies the same waiver; its remaining hold is the unbound
  # merge path, never hard stop 3.
  dir=$(make_case coolify-github)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7"
  gh_green "$dir"
  gh_set_checks "$dir" '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE","name":"deploy / deploy"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS","name":"Lint"}]'
  out=$(report_case "$dir" "$NOW_LATE")
  assert_not_contains "$out" "hard-stop-3" "the waived GitHub preview check tripped hard stop 3"
  assert_contains "$out" "no-bound-merge" "the waived GitHub preview did not fall through to the unbound-merge hold"
  pass "the Coolify preview check is waived while every other failing check still holds"
}

test_skipped_status_semantics() {
  local dir keys rows out tmp
  # A real failure beside a skipped Forgejo status still holds under hard stop 3.
  dir=$(make_case skipped-red)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  tea_set_checks "$dir" failure '[{"context": "CI / test (pull_request)", "status": "failure"}, {"context": "CI / docs (pull_request)", "status": "skipped"}]'
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return:t1" "a real failure beside a skipped status did not hold"
  assert_contains "$rows" "hard stop 3" "a real failure beside a skipped status did not name hard stop 3"
  assert_not_contains "$rows" "merge it bound now" "a real failure beside a skipped status queued a merge wake"

  # A combined `skipped` head is no checks (hard stop 4), and a combined
  # `warning` head is classified through its statuses and holds as red.
  dir=$(make_case skipped-combined)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  tea_set_checks "$dir" skipped '[{"context": "CI / deploy (pull_request)", "status": "skipped"}]'
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return:t1" "a combined skipped head did not hold"
  assert_contains "$rows" "hard stop 4" "a combined skipped head did not name hard stop 4"
  assert_not_contains "$rows" "merge it bound now" "a combined skipped head queued a merge wake"
  assert_not_contains "$rows" "checks-unreadable" "a combined skipped head was parked as unreadable"

  dir=$(make_case warning-combined)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  tea_set_checks "$dir" warning '[{"context": "CI / test (pull_request)", "status": "warning"}]'
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return:t1" "a combined warning head did not hold"
  assert_contains "$rows" "hard stop 3" "a combined warning head did not name hard stop 3"
  assert_not_contains "$rows" "merge it bound now" "a combined warning head queued a merge wake"
  assert_not_contains "$rows" "checks-unreadable" "a combined warning head was parked as unreadable"

  # The waived preview beside a skipped status stays policy-clean but holds for
  # the protected merge path instead of parking as unreadable.
  dir=$(make_case skipped-waived)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  tea_set_checks "$dir" failure '[{"context": "deploy / deploy (pull_request)", "status": "failure"}, {"context": "CI / docs (pull_request)", "status": "skipped"}]'
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" "held" "the waived preview beside a skipped status was not held"
  assert_contains "$out" "no-bound-merge" "the waived preview beside a skipped status did not name the merge-path hold"
  assert_not_contains "$out" "checks-unreadable" "the waived preview beside a skipped status parked as unreadable"
  assert_not_contains "$out" $'t1\tdue\tready' "the waived preview beside a skipped status queued a dead-end mandate"

  # A skipped GitLab head pipeline is no checks: hard stop 4, not a silent park.
  dir=$(make_case skipped-gitlab)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://gitlab.example/group/project/-/merge_requests/7"
  glab_green "$dir"
  tmp=$(mktemp)
  jq '.head_pipeline.status = "skipped"' "$dir/fix/glab-mr.json" > "$tmp"
  mv "$tmp" "$dir/fix/glab-mr.json"
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return:t1" "a skipped GitLab pipeline did not hold"
  assert_contains "$rows" "hard stop 4" "a skipped GitLab pipeline did not name hard stop 4"
  assert_not_contains "$rows" "merge it bound now" "a skipped GitLab pipeline queued a merge wake"
  assert_not_contains "$rows" "checks-unreadable" "a skipped GitLab pipeline was parked as unreadable"
  pass "a skipped check status is a pass, a skipped combined head and pipeline are no checks, and a combined warning is red"
}

test_gate_prose_does_not_accept_open_findings() {
  local dir token out body
  # The reported programmieren-community#365 block: six per-lens prose results,
  # several naming unresolved findings, no table and no literal `Result: clean`.
  dir=$(make_case gate-prose-365)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  # shellcheck disable=SC2016 # Literal gate prose is test data.
  tea_set_body "$dir" '## Five-Lens-Block

**1. `code-review` — Verdikt: "nicht CLEAN", 2 major + 11 minor + 4 nit.**
**2. `maintainability-review` — Verdikt: NEEDS REWORK.**
**3. `architecture-system-design-reviewer` — Verdikt: HOLD.**
**4. `design-decision-questioner` — Verdikt: 6 Leaks.**
**5. `self-containment-review` — Verdikt: kein Blocker.**
**6. `review-gate` — Verdikt: kein Blocker.**
'
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  assert_contains "$(queue_keys "$dir")" "pr-green-return:t1" "the reported #365 prose block was accepted as clean"
  assert_contains "$(queue_rows "$dir")" "hard stop 1" "the #365 prose block did not name hard stop 1"

  # Every named unresolved-finding spelling trips the stop even when five other
  # per-lens entries look clean.
  for token in '3 major findings remain' 'must-fix before merge' 'should-fix items' 'HOLD' 'NEEDS REWORK' 'nicht CLEAN' 'Findings: 3' '1 open finding' '6 Leaks'; do
    dir=$(make_case "gate-prose-$(printf '%s' "$token" | tr -c 'a-z0-9' '-')")
    write_policy "$dir" programmieren-community
    write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
    tea_green "$dir"
    # shellcheck disable=SC2016 # Literal gate prose is test data.
    body='## Five-Lens-Block

**1. `code-review` — Verdikt: kein Blocker.**
**2. `maintainability-review` — Verdikt: kein Blocker.**
**3. `architecture-system-design-reviewer` — Verdikt: kein Blocker.**
**4. `design-decision-questioner` — Verdikt: kein Blocker.**
**5. `self-containment-review` — Verdikt: kein Blocker.**
**6. `review-gate` — Verdikt: '"$token"'.**
'
    tea_set_body "$dir" "$body"
    out=$(report_case "$dir" "$NOW_LATE")
    assert_contains "$out" "hard-stop-1" "the prose token \"$token\" was accepted as clean"
  done

  # Values outside the clean forms - and a clean-looking prefix followed by
  # finding language - trip the stop.
  for entry in 'Result: failed' 'Verdikt: 2 Befunde' 'Result: passed, 2 findings remain'; do
    dir=$(make_case "gate-prose-value-$(printf '%s' "$entry" | tr -c 'a-z0-9' '-')")
    write_policy "$dir" programmieren-community
    write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
    tea_green "$dir"
    # shellcheck disable=SC2016 # Literal gate prose is test data.
    body='## Five-Lens-Block

**1. `code-review` — Verdikt: kein Blocker.**
**2. `maintainability-review` — Verdikt: kein Blocker.**
**3. `architecture-system-design-reviewer` — Verdikt: kein Blocker.**
**4. `design-decision-questioner` — Verdikt: kein Blocker.**
**5. `self-containment-review` — Verdikt: kein Blocker.**
**6. `review-gate` — '"$entry"'.**
'
    tea_set_body "$dir" "$body"
    out=$(report_case "$dir" "$NOW_LATE")
    assert_contains "$out" "hard-stop-1" "the prose value \"$entry\" was accepted as clean"
  done

  # Five clean per-lens prose entries pass (tea_green's own body is exactly
  # that), and so does a clean table without the literal `Result: clean` line.
  dir=$(make_case gate-prose-clean)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" $'t1\tdue\tready' "five clean per-lens prose entries were rejected"

  dir=$(make_case gate-table-clean)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  tea_set_body "$dir" "## Five-Lens-Block

$(write_gate_table)
"
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" $'t1\tdue\tready' "a clean five-lens table without the literal Result line was rejected"

  # Per-lens `Result: passed` entries are a clean form, alone and mixed with the
  # other clean forms.
  dir=$(make_case gate-prose-passed)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  # shellcheck disable=SC2016 # Literal gate prose is test data.
  tea_set_body "$dir" '## Five-Lens-Block

**1. `code-review` — Result: passed.**
**2. `maintainability-review` — Result: passed.**
**3. `architecture-system-design-reviewer` — Result: passed.**
**4. `design-decision-questioner` — Result: passed.**
**5. `self-containment-review` — Result: passed.**
'
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" $'t1\tdue\tready' "five per-lens Result: passed entries were rejected"

  dir=$(make_case gate-prose-mixed)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  # shellcheck disable=SC2016 # Literal gate prose is test data.
  tea_set_body "$dir" '## Five-Lens-Block

**1. `code-review` — Result: clean.**
**2. `maintainability-review` — Result: pass.**
**3. `architecture-system-design-reviewer` — Verdikt: kein Blocker.**
**4. `design-decision-questioner` — Result: passed.**
**5. `self-containment-review` — Verdikt: no blocker.**
'
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" $'t1\tdue\tready' "mixed clean per-lens prose forms were rejected"
  pass "per-lens prose results outside the clean forms hold; clean prose and clean tables pass"
}

test_gate_table_never_drops_a_data_row() {
  local dir out

  # A sixth row that names an open finding must hold even though the five lens
  # rows are numeric-clean, and the trailing Result line must not be skipped.
  dir=$(gate_body_case gate-table-open-row "## Five-Lens-Block

$(write_gate_table)
| security-review (zusaetzlich) | yes | 1 offen | 0 |

Result: 1 finding open - see security-review
")
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  assert_contains "$(queue_keys "$dir")" "pr-green-return:t1" "a sixth row naming an open finding was dropped"
  assert_contains "$(queue_rows "$dir")" "hard stop 1" "the open sixth row did not name hard stop 1"
  assert_not_contains "$(queue_rows "$dir")" "merge it bound now" "the open sixth row queued a merge mandate"

  # The open row holds on its own too, without any trailing Result line.
  dir=$(gate_body_case gate-table-open-row-only "## Five-Lens-Block

$(write_gate_table)
| security-review (zusaetzlich) | yes | 1 offen | 0 |
")
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" "hard-stop-1" "an open table row was accepted without a Result line"

  # A clean table whose trailing Result line names an open finding also holds.
  dir=$(gate_body_case gate-table-open-result "## Five-Lens-Block

$(write_gate_table)

Result: 1 finding open - see security-review
")
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" "hard-stop-1" "a clean table hid an open Result line"

  # A negator in an earlier clause must not reach a later, separate open: a
  # clean table cannot hide `Result: no blocker, 2 findings open`.
  dir=$(gate_body_case gate-table-negation-window "## Five-Lens-Block

$(write_gate_table)

Result: no blocker, 2 findings open
")
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" "hard-stop-1" "a negator in an earlier clause hid an open Result line"

  # The negation does not cross result cells: the 0 in Findings must not
  # negate the `1 offen` in Fixed.
  dir=$(gate_body_case gate-table-cross-cell "## Five-Lens-Block

$(write_gate_table 0 '0 (1 offen)')
")
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" "hard-stop-1" "a zero in Findings negated an open in Fixed"

  # An inflected German open finding and a count-bearing remain phrase must
  # hold even when the table itself is clean.
  dir=$(gate_body_case gate-table-inflected-open "## Five-Lens-Block

$(write_gate_table)

Ergebnis: 2 offene Findings
")
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" "hard-stop-1" "an inflected offene Findings result was accepted"

  dir=$(gate_body_case gate-table-findings-remain "## Five-Lens-Block

$(write_gate_table)

Result: 2 findings remain
")
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" "hard-stop-1" "a count-bearing findings remain result was accepted"

  # A zero count and a negation keep their clean reads.
  dir=$(gate_body_case gate-table-zero-open "## Five-Lens-Block

$(write_gate_table)

Result: 0 open findings
")
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" $'t1\tdue\tready' "a zero-count open findings result was rejected"

  # Negations outside the original word list keep their clean reads too.
  for phrase in 'Result: nothing open' 'Result: none open'; do
    dir=$(gate_body_case "gate-table-negation-$(printf '%s' "$phrase" | tr -c 'a-z0-9' '-')" "## Five-Lens-Block

$(write_gate_table)

$phrase
")
    out=$(report_case "$dir" "$NOW_LATE")
    assert_contains "$out" $'t1\tdue\tready' "the clean negation \"$phrase\" was rejected"
  done

  # A count immediately qualified as fixed/closed/resolved/behoben is a clean
  # summary, not an open finding.
  dir=$(gate_body_case gate-table-fixed-summary "## Five-Lens-Block

$(write_gate_table)

Result: 2 findings fixed, 0 remain
")
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" $'t1\tdue\tready' "a fixed-summary count was held as an open finding"

  # A clause boundary between the count and its qualifier keeps the same clean
  # read: `2 findings, fixed` is the fixed summary, not an open finding.
  dir=$(gate_body_case gate-table-fixed-summary-comma "## Five-Lens-Block

$(write_gate_table)

Result: 2 findings, fixed
")
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" $'t1\tdue\tready' "a comma-qualified fixed summary was held as an open finding"

  # A clause boundary before a remainder count still holds: the count is not
  # qualified as fixed, so the open finding stands.
  dir=$(gate_body_case gate-table-fixed-then-remain "## Five-Lens-Block

$(write_gate_table)

Result: 2 findings, 1 remaining
")
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" "hard-stop-1" "a comma-separated remaining count was accepted"

  dir=$(gate_body_case gate-table-behoben-summary "## Five-Lens-Block

$(write_gate_table)

Ergebnis: 1 Finding behoben, 0 offen
")
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" $'t1\tdue\tready' "a behoben-summary count was held as an open finding"

  # Open, left, and remainder-adjective counts still hold; the remain count is
  # pinned above and the fixed count is exempt.
  for phrase in 'Result: 2 findings open' 'Result: 2 findings left' \
    'Result: 2 findings fixed, 1 remaining' 'Result: 2 findings fixed, 1 unresolved' \
    'Result: 2 findings fixed, 1 outstanding'; do
    dir=$(gate_body_case "gate-table-count-$(printf '%s' "$phrase" | tr -c 'a-z0-9' '-')" "## Five-Lens-Block

$(write_gate_table)

$phrase
")
    out=$(report_case "$dir" "$NOW_LATE")
    assert_contains "$out" "hard-stop-1" "the count phrase \"$phrase\" was accepted"
  done

  # A non-numeric cell whose leading counts cover the findings stays clean.
  dir=$(gate_body_case gate-table-refuted "## Five-Lens-Block

$(write_gate_table 6 '6 (1 widerlegt)')
")
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" $'t1\tdue\tready' "a refuted-but-covered result cell was rejected"

  # A non-numeric row that cannot be classified holds.
  dir=$(gate_body_case gate-table-unclassifiable '## Five-Lens-Block

| Lens | Ran | Findings | Fixed |
|---|---|---|---|
| code-review | yes | 0 | 0 |
| maintainability-review | yes | 0 | 0 |
| architecture-system-design-reviewer | yes | 0 | 0 |
| design-decision-questioner | yes | 0 | 0 |
| self-containment-review | yes | n/a | n/a |
')
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" "hard-stop-1" "an unclassifiable table row was accepted"

  # A non-numeric row whose count does not cover the findings holds.
  dir=$(gate_body_case gate-table-uncovered "## Five-Lens-Block

$(write_gate_table 6 '2 (1 widerlegt)')
")
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" "hard-stop-1" "an uncovered non-numeric row was accepted"
  pass "a table row naming an open finding or lacking covering counts holds; a covered refuted cell passes"
}

test_no_mistakes_gate_reads_the_designated_comment() {
  local dir out clean_comment open_comment

  # The designated comment format: exact title, per-lens table, and a Result
  # line whose trailing explanation says no finding remains open. A no-mistakes
  # task's pipeline-opened body carries no gate block, so the comment alone
  # must clear hard stop 1 and reach the bound-merge wake.
  clean_comment=$(printf '%s\n\nResult: clean - all five lenses ran and no finding remains open.' "$(write_gate_table)")
  open_comment=$(printf '%s\n\nResult: 1 finding open - see code-review' "$(write_gate_table 3 0)")

  # Forgejo: a clean designated comment clears the gate and the PR is due.
  dir=$(make_case nm-comment-forgejo)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community no-mistakes
  tea_green "$dir"
  tea_set_body "$dir" "Pipeline-opened body without a gate block."
  tea_set_five_lens_comment "$dir" "$clean_comment"
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" $'t1\tdue\tready' "a clean designated comment did not clear hard stop 1"
  out=$(scan_case "$dir" "$NOW_LATE")
  assert_contains "$out" "merge it bound now" "the clean comment did not reach the bound-merge wake"

  # GitHub: the same clean comment clears the gate; the GitHub merge path then
  # holds on its own unbound-head reason, never on hard stop 1.
  dir=$(make_case nm-comment-github)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7" project no-mistakes
  gh_green "$dir"
  gh_set_body "$dir" "Pipeline-opened body without a gate block."
  gh_set_five_lens_comment "$dir" "$clean_comment"
  out=$(report_case "$dir" "$NOW_LATE")
  assert_not_contains "$out" "hard-stop-1" "a clean designated comment did not clear hard stop 1 on GitHub"
  assert_contains "$out" "no-bound-merge" "the clean GitHub read did not reach the unbound-merge hold"

  # An open finding in the designated comment still trips hard stop 1.
  dir=$(make_case nm-comment-open)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community no-mistakes
  tea_green "$dir"
  tea_set_body "$dir" "Pipeline-opened body without a gate block."
  tea_set_five_lens_comment "$dir" "$open_comment"
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" "hard-stop-1" "an open finding in the designated comment was accepted"

  # A no-mistakes task with no designated comment, and one whose comment carries
  # any other title, both stay held: the exact title is the evidence.
  dir=$(make_case nm-comment-missing)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community no-mistakes
  tea_green "$dir"
  tea_set_body "$dir" "Pipeline-opened body without a gate block."
  tea_set_five_lens_comment "$dir" none
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" "hard-stop-1" "a no-mistakes task without a designated comment was accepted"

  dir=$(make_case nm-comment-github-missing)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7" project no-mistakes
  gh_green "$dir"
  gh_set_body "$dir" "Pipeline-opened body without a gate block."
  gh_set_five_lens_comment "$dir" none
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" "hard-stop-1" "a GitHub no-mistakes task without a designated comment was accepted"

  dir=$(make_case nm-comment-wrong-title)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community no-mistakes
  tea_green "$dir"
  tea_set_body "$dir" "Pipeline-opened body without a gate block."
  tea_set_five_lens_comment "$dir" "$clean_comment" "Findings and fixes from five-lens-review"
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" "hard-stop-1" "a comment with a near title counted as the gate evidence"

  # A clean exact-titled comment from anyone but the authenticated operator is
  # not the evidence, on either forge.
  dir=$(make_case nm-comment-foreign-forgejo)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community no-mistakes
  tea_green "$dir"
  tea_set_body "$dir" "Pipeline-opened body without a gate block."
  tea_set_five_lens_comment "$dir" "$clean_comment" "Findings and fixes from 5-lenses-review" "intruder"
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" "hard-stop-1" "a foreign-authored comment cleared hard stop 1 on Forgejo"

  dir=$(make_case nm-comment-foreign-github)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://github.com/op/project/pull/7" project no-mistakes
  gh_green "$dir"
  gh_set_body "$dir" "Pipeline-opened body without a gate block."
  gh_set_five_lens_comment "$dir" "$clean_comment" "Findings and fixes from 5-lenses-review" "intruder"
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" "hard-stop-1" "a foreign-authored comment cleared hard stop 1 on GitHub"

  # The designated comment beyond the first API page is still found: 50 first-page
  # comments push the operator's clean comment onto page 2.
  dir=$(make_case nm-comment-paged)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community no-mistakes
  tea_green "$dir"
  tea_set_body "$dir" "Pipeline-opened body without a gate block."
  jq -n --arg time "$VERDICT_TIME" \
    '[range(1; 50) | {id: ., user: {login: "someone"}, updated_at: $time, body: ("chatter " + (. | tostring))}]
     + [{id: 50, user: {login: "seibert-pr-agent"}, updated_at: $time, body: "Reviewed this pull request - **Good to merge (LGTM).**\n<!-- crabd:tracking -->"}]' \
    > "$dir/fix/tea-comments-page1.json"
  jq -n --arg time "$VERDICT_TIME" --arg body "$clean_comment" \
    '[{id: 51, user: {login: "op"}, updated_at: $time, body: ("Findings and fixes from 5-lenses-review\n\n" + $body)}]' \
    > "$dir/fix/tea-comments-page2.json"
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" $'t1\tdue\tready' "the designated comment beyond the first page was not read"

  # A non-paginating forge returns the identical full list for every page: the
  # reader stops at the repeated page and still finds the designated comment.
  dir=$(make_case nm-comment-static)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community no-mistakes
  tea_green "$dir"
  tea_set_body "$dir" "Pipeline-opened body without a gate block."
  jq -n --arg time "$VERDICT_TIME" --arg body "$clean_comment" \
    '[range(1; 50) | {id: ., user: {login: "someone"}, updated_at: $time, body: ("chatter " + (. | tostring))}]
     + [{id: 50, user: {login: "seibert-pr-agent"}, updated_at: $time, body: "Reviewed this pull request - **Good to merge (LGTM).**\n<!-- crabd:tracking -->"},
        {id: 51, user: {login: "op"}, updated_at: $time, body: ("Findings and fixes from 5-lenses-review\n\n" + $body)}]' \
    > "$dir/fix/tea-comments-page1.json"
  cp "$dir/fix/tea-comments-page1.json" "$dir/fix/tea-comments-page2.json"
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" $'t1\tdue\tready' "a non-paginating comment endpoint held the designated comment"
  [ "$(grep -Fc 'comments?limit=50&page=' "$dir/fix/calls.log")" -eq 2 ] || fail "the repeated page was fetched past the first repeat"

  # The direct-PR body path is unchanged: its own clean block still passes, its
  # own open block is never rescued by a clean comment, and a body without a
  # block may fall back to the designated comment.
  dir=$(make_case nm-direct-body-clean)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  tea_set_five_lens_comment "$dir" "$open_comment"
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" $'t1\tdue\tready' "a direct-PR body with its own clean block was not accepted"

  dir=$(make_case nm-direct-body-open)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  tea_set_body "$dir" "## Five-Lens-Block

$(write_gate_table 3 0)
"
  tea_set_five_lens_comment "$dir" "$clean_comment"
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" "hard-stop-1" "a clean comment rescued a direct-PR body that reports an open finding"

  dir=$(make_case nm-direct-body-missing)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  tea_set_body "$dir" "No gate block here."
  tea_set_five_lens_comment "$dir" "$clean_comment"
  out=$(report_case "$dir" "$NOW_LATE")
  assert_contains "$out" $'t1\tdue\tready' "a body without a gate block did not fall back to the designated comment"

  pass "the no-mistakes gate reads the operator's exact-titled comment and the body path is unchanged"
}

test_forgejo_file_list_pagination() {
  local dir keys rows
  # A full first page forces a second request; the sensitive path on that second
  # page must hold instead of being treated as an absent canary.
  dir=$(make_case forgejo-pages-sensitive)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  jq -n '[range(0; 50) | {filename: ("src/module-\(.)/file.ts")}]' > "$dir/fix/tea-files-page1.json"
  jq -n '[{filename: "packages/database/prisma/migrations/20260912090000_add_csg_call_metric/migration.sql"}]' > "$dir/fix/tea-files-page2.json"
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return:t1" "a sensitive file beyond the first page did not hold"
  assert_not_contains "$rows" "merge it bound now" "a sensitive file beyond the first page queued a merge wake"
  assert_contains "$rows" "hard stop 5" "the paginated hold did not name hard stop 5"
  assert_contains "$rows" "migration" "the hold payload did not name the sensitive path"
  assert_grep "page=2" "$dir/fix/calls.log" "the scan did not request the second file page"

  # A short page proves completeness and a full page followed by a clean page
  # still reaches due.
  dir=$(make_case forgejo-pages-complete)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  jq -n '[{filename: "src/a.ts"}, {filename: "src/b.ts"}]' > "$dir/fix/tea-files-page1.json"
  scan_case "$dir" "$NOW_LATE" >/dev/null
  assert_contains "$(queue_keys "$dir")" "pr-green-return:t1" "a complete short file page was not treated as complete"
  assert_no_grep "page=2" "$dir/fix/calls.log" "a short file page still requested a second page"

  dir=$(make_case forgejo-pages-more)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  jq -n '[range(0; 50) | {filename: ("src/module-\(.)/file.ts")}]' > "$dir/fix/tea-files-page1.json"
  jq -n '[{filename: "src/clean.ts"}]' > "$dir/fix/tea-files-page2.json"
  scan_case "$dir" "$NOW_LATE" >/dev/null
  assert_contains "$(queue_keys "$dir")" "pr-green-return:t1" "a full page followed by a clean page held"
  pass "a truncated Forgejo file page holds and a complete paginated read still reaches due"
}

test_gitlab_changes_overflow_holds() {
  local dir keys rows tmp
  dir=$(make_case gitlab-overflow)
  write_policy "$dir" project
  write_meta "$dir" t1 "https://gitlab.example/group/project/-/merge_requests/7"
  glab_green "$dir"
  tmp=$(mktemp)
  jq '.overflow = true' "$dir/fix/glab-changes.json" > "$tmp"
  mv "$tmp" "$dir/fix/glab-changes.json"
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return:t1" "a GitLab changes overflow did not hold"
  assert_not_contains "$rows" "merge it bound now" "a GitLab changes overflow queued a merge wake"
  assert_contains "$rows" "hard stop 5" "a GitLab changes overflow did not name hard stop 5"
  pass "a GitLab changes overflow fails closed under hard stop 5"
}

test_lockfile_does_not_falsely_hold_package_json() {
  local dir keys rows
  dir=$(make_case pkg-lockfile)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  jq -n '[{filename: "package.json"}, {filename: "pnpm-lock.yaml"}]' > "$dir/fix/tea-files.json"
  raw_pair "$dir" '{"build":"tsc"}' '{"build":"tsc"}'
  scan_case "$dir" "$NOW_LATE" >/dev/null
  assert_contains "$(queue_keys "$dir")" "pr-green-return:t1" "a lockfile beside unchanged package.json scripts was falsely held"

  dir=$(make_case pkg-lockfile-scripts)
  write_policy "$dir" programmieren-community
  write_meta "$dir" t1 "https://forgejo.example/seibert.group/programmieren-community/pulls/365" programmieren-community
  tea_green "$dir"
  jq -n '[{filename: "package.json"}, {filename: "pnpm-lock.yaml"}]' > "$dir/fix/tea-files.json"
  raw_pair "$dir" '{"build":"tsc"}' '{"build":"tsc && rm -rf /"}'
  scan_hold_wake "$dir" "$NOW_LATE" >/dev/null
  keys=$(queue_keys "$dir")
  rows=$(queue_rows "$dir")
  assert_contains "$keys" "pr-green-return:t1" "changed package.json scripts beside a lockfile did not hold"
  assert_not_contains "$rows" "pnpm-lock.yaml" "the scripts hold named the lockfile instead of package.json"
  assert_contains "$rows" "package.json" "the scripts hold did not name package.json"
  assert_not_contains "$rows" "merge it bound now" "changed package.json scripts queued a merge wake"
  pass "a lockfile beside package.json is skipped, and only a scripts change holds"
}

test_github_pr_holds_without_a_bound_merge
test_wait_boundary_is_exact_and_persists
test_moved_head_queues_its_own_mandate
test_cross_class_verdict_supersedes_the_stale_mandate
test_red_checks_hold_and_name_hard_stop_3
test_coolify_preview_check_is_waived
test_skipped_status_semantics
test_no_checks_hold_and_name_hard_stop_4
test_foreign_pr_holds_hard_stop_6
test_gate_holds_hard_stop_1
test_gate_prose_does_not_accept_open_findings
test_gate_table_never_drops_a_data_row
test_no_mistakes_gate_reads_the_designated_comment
test_verdict_channel_is_advisory_and_holds_only_on_a_blocking_read
test_sensitive_diff_holds_hard_stop_5
test_forgejo_file_list_pagination
test_gitlab_changes_overflow_holds
test_lockfile_only_change_is_not_sensitive_on_a_mergeable_pr
test_lockfile_does_not_falsely_hold_package_json
test_package_json_scripts_qualifier
test_unreadable_policy_holds_hard_stop_7
test_allowlist_default_ask_holds
test_denylist_wait_list_holds_listed_repos
test_denylist_unrecognized_verdict_holds_hard_stop_7
test_denylist_unlisted_repo_is_due
test_qualified_policy_rows_match_the_full_path
test_missing_or_unknown_posture_holds_hard_stop_7
test_merged_pr_leaves_no_wake_or_record
test_forgejo_due_with_fresh_crabd_verdict
test_forgejo_verdict_channel
test_gitlab_needs_no_verdict_channel
test_report_is_read_only_and_names_the_hold
test_scan_cadence_suppresses_repeat_work
test_every_candidate_is_evaluated_in_one_scan
test_slow_candidate_does_not_starve_the_rotation
test_watcher_surfaces_the_green_return_check_wake
test_invalid_wait_config_fails_closed
test_config_file_sets_the_wait
test_non_candidates_are_ignored
