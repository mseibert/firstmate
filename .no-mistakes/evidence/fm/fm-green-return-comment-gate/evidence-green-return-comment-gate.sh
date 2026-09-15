#!/usr/bin/env bash
# Evidence for fm/fm-green-return-comment-gate: the green-return scan reads the
# five-lens gate from the captain-designated PR comment on a no-mistakes task,
# while the direct-PR body path and the hard-stop-1 semantics stay unchanged.
#
# The script builds a self-contained fixture (fake gh/tea/glab answering only
# read calls), then drives the real CLI:
#   * the pre-fix script (b16fd45, gate read from the PR body only) reproduces
#     the reported PR #31 failure: a no-mistakes PR with a clean designated
#     comment is held at hard stop 1,
#   * the fixed script (HEAD) reports the same PR due and queues the bound-merge
#     check wake, and
#   * guardrail fixtures (open comment, missing comment, foreign author,
#     direct-PR body) show the unchanged hold semantics.
# Every fixture is read-only apart from the scan's own state dir under the
# throwaway temp root. No source file in the worktree is touched.
set -u

WORKTREE=/home/martin_seibert/.no-mistakes/worktrees/e36b903ea8f4/01M2JQ3ZGP60YWY2Q22VFD4KXR
FIXED="$WORKTREE/bin/fm-pr-green-return.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-green-return-evidence.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# The pre-fix script, with the current bin/ library files reachable beside it.
mkdir -p "$TMP/old-bin"
for f in "$WORKTREE"/bin/*.sh; do
  ln -s "$f" "$TMP/old-bin/$(basename "$f")"
done
rm -f "$TMP/old-bin/fm-pr-green-return.sh"
git -C "$WORKTREE" show b16fd45:bin/fm-pr-green-return.sh > "$TMP/old-bin/fm-pr-green-return.sh"
chmod +x "$TMP/old-bin/fm-pr-green-return.sh"
OLD="$TMP/old-bin/fm-pr-green-return.sh"

HEAD=1111111111111111111111111111111111111111
BASE=2222222222222222222222222222222222222222
HEAD_TIME=2026-01-01T00:00:00Z
VERDICT_TIME=2026-01-01T00:10:00Z
NOW_LATE=1767227000 # 800s after the fresh verdict: past the 600s default wait

FIVE_LENS_TITLE='Findings and fixes from 5-lenses-review'
CLEAN_COMMENT='| Lens | Ran | Findings | Fixed |
|---|---|---|---|
| code-review | yes | 0 | 0 |
| maintainability-review | yes | 0 | 0 |
| architecture-system-design-reviewer | yes | 0 | 0 |
| design-decision-questioner | yes | 0 | 0 |
| self-containment-review | yes | 0 | 0 |

Result: clean - all five lenses ran and no finding remains open.'
OPEN_COMMENT='| Lens | Ran | Findings | Fixed |
|---|---|---|---|
| code-review | yes | 3 | 0 |
| maintainability-review | yes | 0 | 0 |
| architecture-system-design-reviewer | yes | 0 | 0 |
| design-decision-questioner | yes | 0 | 0 |
| self-containment-review | yes | 0 | 0 |

Result: 1 finding open - see code-review'
CLEAN_BODY='## Five-Lens-Block

| Lens | Ran | Findings | Fixed |
|---|---|---|---|
| code-review | yes | 0 | 0 |
| maintainability-review | yes | 0 | 0 |
| architecture-system-design-reviewer | yes | 0 | 0 |
| design-decision-questioner | yes | 0 | 0 |
| self-containment-review | yes | 0 | 0 |
'
OPEN_BODY='## Five-Lens-Block

| Lens | Ran | Findings | Fixed |
|---|---|---|---|
| code-review | yes | 3 | 0 |
| maintainability-review | yes | 0 | 0 |
| architecture-system-design-reviewer | yes | 0 | 0 |
| design-decision-questioner | yes | 0 | 0 |
| self-containment-review | yes | 0 | 0 |
'

make_case() { # <name>
  local name=$1 dir
  dir="$TMP/$name"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data" "$dir/fakebin" "$dir/fix"
  : > "$dir/fix/calls.log"
  add_stubs "$dir"
  write_policy "$dir"
  printf '%s\n' "$dir"
}

add_stubs() { # <dir>
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
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
  cat > "$dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod 0755 "$dir/fakebin/gh" "$dir/fakebin/tea" "$dir/fakebin/glab"
}

write_policy() { # <dir>
  local dir=$1
  {
    printf '# PR-Merge-Policy\n\n'
    printf '## The rule\n\nDefault is ask.\n\n'
    printf '| Repo | [Autonomous | Ask] | Why |\n|---|---|---|\n'
    printf '| programmieren-community | Autonomous | fixture |\n'
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

write_meta() { # <dir> <url> [mode]
  local dir=$1 url=$2 mode=${3:-direct-PR}
  {
    printf 'window=firstmate:fm-t1\n'
    printf 'kind=ship\n'
    printf 'mode=%s\n' "$mode"
    printf 'project=%s/projects/programmieren-community\n' "$dir"
    printf 'pr=%s\n' "$url"
    printf 'pr_head=%s\n' "$HEAD"
  } > "$dir/home/state/t1.meta"
}

tea_green() { # <dir> <body>
  local dir=$1 body=$2
  jq -n --arg head "$HEAD" --arg base "$BASE" --arg body "$body" '{
    state: "open", merged: false, mergeable: true,
    head: {sha: $head}, base: {sha: $base},
    user: {login: "op"}, body: $body
  }' > "$dir/fix/tea-pull.json"
  jq -n --arg head "$HEAD" '{sha: $head, state: "success", total_count: 2}' > "$dir/fix/tea-status.json"
  jq -n --arg time "$HEAD_TIME" '{created: $time}' > "$dir/fix/tea-commit.json"
  jq -n '[{filename: "src/app.ts"}]' > "$dir/fix/tea-files.json"
  printf '%s\n' '{"login":"op"}' > "$dir/fix/tea-user.json"
  tea_comments "$dir"
}

tea_comments() { # <dir> <verdict-comment-body-json-array-extras...>
  local dir=$1
  shift
  jq -n --arg time "$VERDICT_TIME" --argjson extra "${1:-[]}" \
    '[{id: 1, user: {login: "seibert-pr-agent"}, updated_at: $time,
       body: "Reviewed this pull request - **Good to merge (LGTM).**\n<!-- crabd:tracking -->"}] + $extra' \
    > "$dir/fix/tea-comments.json"
}

tea_set_five_lens_comment() { # <dir> <body|none> [title] [author]
  local dir=$1 body=$2 title=${3:-$FIVE_LENS_TITLE} author=${4:-op}
  if [ "$body" = none ]; then
    tea_comments "$dir" '[]'
  else
    tea_comments "$dir" "$(jq -n --arg time "$VERDICT_TIME" --arg title "$title" --arg body "$body" --arg author "$author" \
      '[{id: 2, user: {login: $author}, updated_at: $time, body: ($title + "\n\n" + $body)}]')"
  fi
}

gh_green() { # <dir> <body>
  local dir=$1 body=$2
  jq -n --arg head "$HEAD" --arg base "$BASE" --arg time "$HEAD_TIME" --arg body "$body" '{
    state: "OPEN", isDraft: false, mergeable: "MERGEABLE",
    headRefOid: $head, baseRefOid: $base, author: {login: "op"}, body: $body,
    commits: [{oid: $head, committedDate: $time}],
    statusCheckRollup: [{__typename: "CheckRun", status: "COMPLETED", conclusion: "SUCCESS", name: "Lint"}]
  }' > "$dir/fix/gh-view.json"
  printf 'op\n' > "$dir/fix/gh-login"
  printf 'src/app.ts\n' > "$dir/fix/gh-files"
  gh_set_five_lens_comment "$dir" none
}

gh_set_five_lens_comment() { # <dir> <body|none> [title] [author]
  local dir=$1 body=$2 title=${3:-$FIVE_LENS_TITLE} author=${4:-op}
  if [ "$body" = none ]; then
    jq -n --arg time "$VERDICT_TIME" \
      '[[{user: {login: "seibert-pr-agent"}, created_at: $time, updated_at: $time, body: "**Verdict:** Good to merge\n"}]]' \
      > "$dir/fix/gh-comments.json"
  else
    jq -n --arg time "$VERDICT_TIME" --arg title "$title" --arg body "$body" --arg author "$author" \
      '[[{user: {login: "seibert-pr-agent"}, created_at: $time, updated_at: $time, body: "**Verdict:** Good to merge\n"},
        {user: {login: $author}, created_at: $time, updated_at: $time, body: ($title + "\n\n" + $body)}]]' \
      > "$dir/fix/gh-comments.json"
  fi
}

report_case() { # <dir> <script>
  local dir=$1 script=$2
  env FM_HOME="$dir/home" \
    FM_PR_GREEN_RETURN_POLICY="$dir/fix/policy.md" \
    FM_TEST_FIX="$dir/fix" FM_TEST_LOG="$dir/fix/calls.log" \
    FM_PR_GREEN_RETURN_SECS=600 FM_PR_GREEN_RETURN_NOW="$NOW_LATE" \
    PATH="$dir/fakebin:$PATH" "$script" report 2>&1
}

scan_case() { # <dir> <script>
  local dir=$1 script=$2
  env FM_HOME="$dir/home" \
    FM_PR_GREEN_RETURN_POLICY="$dir/fix/policy.md" \
    FM_TEST_FIX="$dir/fix" FM_TEST_LOG="$dir/fix/calls.log" \
    FM_PR_GREEN_RETURN_SECS=600 FM_PR_GREEN_RETURN_FORCE=1 FM_PR_GREEN_RETURN_NOW="$NOW_LATE" \
    PATH="$dir/fakebin:$PATH" "$script" scan 2>&1
}

banner() { printf '\n===== %s =====\n' "$*"; }
show() { # <label> <command...>
  local label=$1
  shift
  printf '\n$ %s\n' "$label"
  "$@"
}

banner 'FIXTURE: no-mistakes Forgejo task, pipeline-opened body, operator five-lens comment'
CASE=$(make_case nm-forgejo)
write_meta "$CASE" "https://forgejo.example/seibert.group/programmieren-community/pulls/365" no-mistakes
tea_green "$CASE" 'Pipeline-opened body without a gate block.'
tea_set_five_lens_comment "$CASE" "$CLEAN_COMMENT"
printf 'PR body: "Pipeline-opened body without a gate block."\n'
printf 'PR comment (author op, title exactly "%s"):\n%s\n' "$FIVE_LENS_TITLE" "$CLEAN_COMMENT"

banner 'PRE-FIX (b16fd45) report: the PR #31 failure, held at hard stop 1'
show 'bin/fm-pr-green-return.sh report   # pre-fix script' report_case "$CASE" "$OLD"

banner 'FIXED (HEAD) report: the same PR is due'
show 'bin/fm-pr-green-return.sh report   # HEAD' report_case "$CASE" "$FIXED"

banner 'FIXED (HEAD) scan: the bound-merge check wake MAIN receives'
show 'bin/fm-pr-green-return.sh scan' scan_case "$CASE" "$FIXED"
printf '\nqueued wake row:\n'
cat "$CASE/home/state/.wake-queue"

banner 'FIXTURE: PR #31 comment form - title + "Result: clean" only'
MINIMAL_CASE=$(make_case nm-minimal)
write_meta "$MINIMAL_CASE" "https://forgejo.example/seibert.group/programmieren-community/pulls/365" no-mistakes
tea_green "$MINIMAL_CASE" 'Pipeline-opened body without a gate block.'
tea_set_five_lens_comment "$MINIMAL_CASE" 'Result: clean'
show 'report   # HEAD' report_case "$MINIMAL_CASE" "$FIXED"

banner 'FIXTURE: no-mistakes GitHub task, same pipeline body + designated comment'
GHCASE=$(make_case nm-github)
write_meta "$GHCASE" "https://github.com/mseibert/firstmate/pull/31" no-mistakes
gh_green "$GHCASE" 'Pipeline-opened body without a gate block.'
gh_set_five_lens_comment "$GHCASE" "$CLEAN_COMMENT"

banner 'PRE-FIX (b16fd45) report: held at hard stop 1 (the reported failure)'
show 'report   # pre-fix script' report_case "$GHCASE" "$OLD"

banner 'FIXED (HEAD) report: hard stop 1 is cleared; only the GitHub head-binding hold remains'
show 'report   # HEAD' report_case "$GHCASE" "$FIXED"

banner 'GUARDRAILS: hard-stop-1 semantics otherwise unchanged'
OPEN_CASE=$(make_case guard-open)
write_meta "$OPEN_CASE" "https://forgejo.example/seibert.group/programmieren-community/pulls/365" no-mistakes
tea_green "$OPEN_CASE" 'Pipeline-opened body without a gate block.'
tea_set_five_lens_comment "$OPEN_CASE" "$OPEN_COMMENT"
show 'designated comment reports an open finding -> held' report_case "$OPEN_CASE" "$FIXED"

MISSING_CASE=$(make_case guard-missing)
write_meta "$MISSING_CASE" "https://forgejo.example/seibert.group/programmieren-community/pulls/365" no-mistakes
tea_green "$MISSING_CASE" 'Pipeline-opened body without a gate block.'
tea_set_five_lens_comment "$MISSING_CASE" none
show 'no designated comment -> held' report_case "$MISSING_CASE" "$FIXED"

WRONG_TITLE_CASE=$(make_case guard-wrong-title)
write_meta "$WRONG_TITLE_CASE" "https://forgejo.example/seibert.group/programmieren-community/pulls/365" no-mistakes
tea_green "$WRONG_TITLE_CASE" 'Pipeline-opened body without a gate block.'
tea_set_five_lens_comment "$WRONG_TITLE_CASE" "$CLEAN_COMMENT" 'Findings and fixes from five-lens-review'
show 'near title (no "5-lenses") -> held' report_case "$WRONG_TITLE_CASE" "$FIXED"

FOREIGN_CASE=$(make_case guard-foreign)
write_meta "$FOREIGN_CASE" "https://forgejo.example/seibert.group/programmieren-community/pulls/365" no-mistakes
tea_green "$FOREIGN_CASE" 'Pipeline-opened body without a gate block.'
tea_set_five_lens_comment "$FOREIGN_CASE" "$CLEAN_COMMENT" "$FIVE_LENS_TITLE" intruder
show 'exact-titled comment by a foreign author -> held' report_case "$FOREIGN_CASE" "$FIXED"

DIRECT_BODY_CASE=$(make_case guard-direct-body)
write_meta "$DIRECT_BODY_CASE" "https://forgejo.example/seibert.group/programmieren-community/pulls/365"
tea_green "$DIRECT_BODY_CASE" "$CLEAN_BODY"
tea_set_five_lens_comment "$DIRECT_BODY_CASE" "$OPEN_COMMENT"
show 'direct-PR body with its own clean block -> body wins, due' report_case "$DIRECT_BODY_CASE" "$FIXED"

DIRECT_OPEN_CASE=$(make_case guard-direct-open)
write_meta "$DIRECT_OPEN_CASE" "https://forgejo.example/seibert.group/programmieren-community/pulls/365"
tea_green "$DIRECT_OPEN_CASE" "$OPEN_BODY"
tea_set_five_lens_comment "$DIRECT_OPEN_CASE" "$CLEAN_COMMENT"
show 'direct-PR body with an open finding + clean comment -> held' report_case "$DIRECT_OPEN_CASE" "$FIXED"

banner 'FORGEJO PAGINATION HARDENING: non-paginating endpoint with 51 comments'
STATIC_CASE=$(make_case static-endpoint)
write_meta "$STATIC_CASE" "https://forgejo.example/seibert.group/programmieren-community/pulls/365" no-mistakes
tea_green "$STATIC_CASE" 'Pipeline-opened body without a gate block.'
jq -n --arg time "$VERDICT_TIME" --arg body "$CLEAN_COMMENT" \
  '[range(1; 50) | {id: ., user: {login: "someone"}, updated_at: $time, body: ("chatter " + (. | tostring))}]
   + [{id: 50, user: {login: "seibert-pr-agent"}, updated_at: $time, body: "Reviewed this pull request - **Good to merge (LGTM).**\n<!-- crabd:tracking -->"},
      {id: 51, user: {login: "op"}, updated_at: $time, body: ("Findings and fixes from 5-lenses-review\n\n" + $body)}]' \
  > "$STATIC_CASE/fix/tea-comments-page1.json"
cp "$STATIC_CASE/fix/tea-comments-page1.json" "$STATIC_CASE/fix/tea-comments-page2.json"
show 'report (endpoint returns the identical full list for every page)' report_case "$STATIC_CASE" "$FIXED"
printf 'comment-endpoint fetches: %s (stops after the first repeated page; safety cap is 40)\n' \
  "$(grep -c 'comments?limit=50&page=' "$STATIC_CASE/fix/calls.log")"

banner 'DONE'
