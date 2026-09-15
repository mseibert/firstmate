#!/usr/bin/env bash
# Reviewer-visible end-to-end transcript for the green-PR return path.
#
# Drives the real bin/fm-pr-green-return.sh scan and the real
# bin/fm-pr-merge.sh against a sandboxed firstmate home whose Forgejo CLI (tea)
# is a recording stub, so the transcript shows what a captain's session sees:
# the queued wake carrying the bound-merge mandate, the merge the mandate
# performs with the head_commit_id it sent, and the refusals of held, red and
# checkless PRs with the hard stop named and no merge sent.
#
# Usage: bash green-return-e2e.sh [<firstmate-repo-root>]
set -u

ROOT=${1:-/home/martin_seibert/.no-mistakes/worktrees/4771d2997321/01M2FEC6B11623C46JB4RT9SGG}
JQ=$(command -v jq) || { printf 'jq is required\n' >&2; exit 1; }
GREEN="$ROOT/bin/fm-pr-green-return.sh"
MERGE="$ROOT/bin/fm-pr-merge.sh"
EVIDENCE_DIR=$(cd "$(dirname "$0")" && pwd)

HEAD=1111111111111111111111111111111111111111
HEAD2=3333333333333333333333333333333333333333
BASE=2222222222222222222222222222222222222222
HEAD_TIME=2026-01-01T00:00:00Z
VERDICT_TIME=2026-01-01T00:10:00Z
# 800 seconds after the fresh verdict, past the 600s default wait.
NOW_LATE=1767227000
FJ_HOST=forgejo.example
FJ_PATH=seibert.group/programmieren-community
FJ_URL="https://$FJ_HOST/$FJ_PATH/pulls/365"

GATE_CLEAN='## Five-lens gate

Result: clean
'
GATE_HELD='## Five-lens gate

| Lens | Ran | Findings | Fixed |
|---|---|---|---|
| code-review | yes | 0 | 0 |
| maintainability-review | yes | 0 | 0 |
| architecture-system-design-reviewer | yes | 0 | 0 |
| design-decision-questioner | yes | 0 | 0 |
| self-containment-review | yes | 0 | 0 |
| security-review (zusaetzlich) | yes | 1 offen | 0 |

Result: 1 finding open - see security-review
'

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-green-return-e2e.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

say() { printf '\n===== %s =====\n' "$*"; }

show_file() {
  printf '\n$ cat %s\n' "$1"
  cat "$1"
}

write_policy() { # <allowlisted repo name>
  local repo=$1
  {
    printf '# PR-Merge-Policy\n\n## The rule\n\nDefault is ask.\n\n'
    printf '| Repo | [Autonomous | Ask] | Why |\n|---|---|---|\n'
    printf '| %s | Autonomous | fixture |\n' "$repo"
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
  } > "$CASE/fix/policy.md"
}

write_tea_mock() {
  cat > "$CASE/fakebin/tea" <<'SH'
#!/usr/bin/env bash
case_dir=$FM_E2E_CASE
printf '%s\n' "$*" >> "$case_dir/tea.log"
[ "${1:-}" = api ] || exit 2
shift
method=GET
endpoint=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift 2 ;;
    -X*) method=${1#-X}; shift ;;
    -d) printf '%s\n' "$2" >> "$case_dir/tea-body.log"; shift 2 ;;
    -d*) printf '%s\n' "${1#-d}" >> "$case_dir/tea-body.log"; shift ;;
    *) endpoint=$1; shift ;;
  esac
done
case "$method $endpoint" in
  "GET /user") cat "$case_dir/tea-user.json" ;;
  "GET /repos/"*"/commits/"*"/status") cat "$case_dir/tea-status.json" ;;
  "GET /repos/"*"/pulls/"*"/files"*) cat "$case_dir/tea-files.json" ;;
  "GET /repos/"*"/issues/"*"/comments") cat "$case_dir/tea-comments.json" ;;
  "GET /repos/"*"/git/commits/"*) cat "$case_dir/tea-commit.json" ;;
  "GET /repos/"*"/pulls/"*)
    if [ -e "$case_dir/tea-merge-called" ]; then
      cat "$case_dir/tea-pr-post.json"
    else
      cat "$case_dir/tea-pr.json"
    fi ;;
  "GET /repos/"*) cat "$case_dir/tea-repo.json" ;;
  "POST /repos/"*"/merge")
    : > "$case_dir/tea-merge-called"
    printf 'HTTP/2.0 200 OK\n' >&2
    ;;
  *) exit 1 ;;
esac
exit 0
SH
  chmod 0755 "$CASE/fakebin/tea"
}

new_case() { # <name>
  local name=$1
  CASE="$WORK/$name"
  mkdir -p "$CASE/state" "$CASE/fix" "$CASE/fakebin"
  ln -sf "$JQ" "$CASE/fakebin/jq"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$CASE/fakebin/gh"
  cp "$CASE/fakebin/gh" "$CASE/fakebin/gh-axi"
  cp "$CASE/fakebin/gh" "$CASE/fakebin/glab"
  write_tea_mock
  write_policy programmieren-community
  : > "$CASE/tea.log"
  : > "$CASE/tea-body.log"
  printf 'window=firstmate:fm-t1\nkind=ship\nmode=direct-PR\nproject=%s/projects/programmieren-community\npr=%s\npr_head=%s\n' \
    "$CASE" "$FJ_URL" "$HEAD" > "$CASE/state/t1.meta"
  export FM_E2E_CASE="$CASE"
}

write_pull() { # <body> [<head>]
  jq -n --arg head "${2:-$HEAD}" --arg base "$BASE" --arg body "$1" \
    '{state:"open",merged:false,mergeable:true,head:{sha:$head},base:{sha:$base},user:{login:"op"},body:$body}' \
    > "$CASE/tea-pr.json"
}

write_status() { # <combined-state> <sha>
  local state=$1 sha=$2 statuses
  case "$state" in
    success) statuses='[{"context":"CI / ci","status":"success"}]' ;;
    failure) statuses='[{"context":"CI / ci","status":"failure"}]' ;;
    *) statuses='[]' ;;
  esac
  jq -n --arg sha "$sha" --arg state "$state" --argjson statuses "$statuses" \
    '{sha:$sha,state:$state,total_count:($statuses|length),statuses:$statuses}' \
    > "$CASE/tea-status.json"
}

write_green_fixtures() { # <gate-body> [<head>]
  local body=$1 head=${2:-$HEAD}
  write_pull "$body" "$head"
  write_status success "$head"
  jq -n --arg time "$HEAD_TIME" '{created:$time}' > "$CASE/tea-commit.json"
  jq -n --arg time "$VERDICT_TIME" \
    '[{user:{login:"seibert-pr-agent"},updated_at:$time,body:"Reviewed this pull request — **Good to merge (LGTM).**\n<!-- crabd:tracking -->"}]' \
    > "$CASE/tea-comments.json"
  printf '[{"filename":"src/app.ts"}]\n' > "$CASE/tea-files.json"
  printf '{"login":"op"}\n' > "$CASE/tea-user.json"
  printf '{"default_branch":"main","default_merge_style":"merge"}\n' > "$CASE/tea-repo.json"
  jq -n --arg head "$head" --arg base "$BASE" \
    '{state:"closed",merged:true,mergeable:true,head:{sha:$head},base:{sha:$base}}' \
    > "$CASE/tea-pr-post.json"
}

scan() { # <now>
  local now=$1 rc
  printf '\n$ FM_PR_GREEN_RETURN_NOW=%s FM_PR_GREEN_RETURN_SECS=600 %s scan\n' "$now" "$GREEN"
  env FM_HOME="$ROOT" FM_STATE_OVERRIDE="$CASE/state" \
    FM_PR_GREEN_RETURN_POLICY="$CASE/fix/policy.md" \
    FM_PR_GREEN_RETURN_SECS=600 FM_PR_GREEN_RETURN_FORCE=1 \
    FM_PR_GREEN_RETURN_NOW="$now" PATH="$CASE/fakebin:$PATH" \
    "$GREEN" scan
  rc=$?
  printf '[exit %s]\n' "$rc"
  return 0
}

merge_run() { # <id> <url> [args...]
  local rc
  printf '\n$ bin/fm-pr-merge.sh %s\n' "$*"
  env FM_HOME="$ROOT" FM_STATE_OVERRIDE="$CASE/state" \
    FM_PR_GREEN_RETURN_POLICY="$CASE/fix/policy.md" \
    PATH="$CASE/fakebin:$PATH" \
    "$MERGE" "$@"
  rc=$?
  printf '[exit %s]\n' "$rc"
  return 0
}

run_mandate() { # <mandate string>
  local mandate=$1 rc
  printf '\n$ (cd %s && %s)\n' "$ROOT" "$mandate"
  ( cd "$ROOT" && env FM_HOME="$ROOT" FM_STATE_OVERRIDE="$CASE/state" \
      FM_PR_GREEN_RETURN_POLICY="$CASE/fix/policy.md" \
      PATH="$CASE/fakebin:$PATH" bash -c "$mandate" )
  rc=$?
  printf '[exit %s]\n' "$rc"
  return 0
}

mandate_of_case() {
  awk -F'\t' 'NF >= 5 { print $5 }' "$CASE/state/.wake-queue" \
    | sed -n 's/.*merge it bound now: //p'
}

# --------------------------------------------------------------- POSITIVE ---
say "POSITIVE: green, mergeable, gate-clean own-task Forgejo PR, no human action"
new_case positive
write_green_fixtures "$GATE_CLEAN"
printf 'task t1 records its own pr=%s\n' "$FJ_URL"
printf 'policy allowlists programmieren-community; head is %s\n' "$HEAD"
scan "$NOW_LATE"
show_file "$CASE/state/.wake-queue"
show_file "$CASE/state/pr-green-return/t1"
mandate=$(mandate_of_case)
printf '\nThe wake handed main this mandate:\n  %s\n' "$mandate"
run_mandate "$mandate"
printf '\nThe merge body the protected path sent to the forge (head binding):\n'
cat "$CASE/tea-body.log"
cp "$CASE/state/.wake-queue" "$EVIDENCE_DIR/green-return-positive-wake-queue.tsv"
cp "$CASE/tea-body.log" "$EVIDENCE_DIR/green-return-positive-merge-body.json"

# --------------------------------------------------------- NEGATIVE: RED ---
say "NEGATIVE 1: red head holds as hard stop 3 and never merges"
new_case negative-red
write_green_fixtures "$GATE_CLEAN"
write_status failure "$HEAD"
scan "$NOW_LATE"
scan "$((NOW_LATE + 601))"
show_file "$CASE/state/.wake-queue"
merge_run t1 "$FJ_URL" --expected-head "$HEAD"
printf '\nmerge bodies recorded (must be 0 bytes): %s bytes\n' "$(wc -c < "$CASE/tea-body.log")"

# -------------------------------------------------- NEGATIVE: GATE HOLD ---
say "NEGATIVE 2: same head, fresh five-lens hold (hard stop 1) refuses a queued mandate"
new_case negative-gate
write_green_fixtures "$GATE_HELD"
scan "$NOW_LATE"
scan "$((NOW_LATE + 601))"
show_file "$CASE/state/.wake-queue"
merge_run t1 "$FJ_URL" --expected-head "$HEAD"
printf '\nmerge bodies recorded (must be 0 bytes): %s bytes\n' "$(wc -c < "$CASE/tea-body.log")"

# ---------------------------------------------------- NEGATIVE: NO CHECKS ---
say "NEGATIVE 3: a repository without checks holds as hard stop 4"
new_case negative-nochecks
write_green_fixtures "$GATE_CLEAN"
write_status '' "$HEAD"
scan "$NOW_LATE"
scan "$((NOW_LATE + 601))"
show_file "$CASE/state/.wake-queue"
merge_run t1 "$FJ_URL" --expected-head "$HEAD"
printf '\nmerge bodies recorded (must be 0 bytes): %s bytes\n' "$(wc -c < "$CASE/tea-body.log")"

# ---------------------------------------------------- NEGATIVE: MOVED HEAD ---
say "NEGATIVE 4: the head moved after the mandate; the binding refuses"
new_case negative-moved
write_green_fixtures "$GATE_CLEAN"
scan "$NOW_LATE"
mandate=$(mandate_of_case)
printf '\nqueued mandate names the verified head:\n  %s\n' "$mandate"
printf '\nthe branch is then pushed to a new head %s\n' "$HEAD2"
write_pull "$GATE_CLEAN" "$HEAD2"
write_status success "$HEAD2"
merge_run t1 "$FJ_URL" --expected-head "$HEAD"
printf '\nmerge bodies recorded (must be 0 bytes): %s bytes\n' "$(wc -c < "$CASE/tea-body.log")"

say "END OF TRANSCRIPT"
