#!/usr/bin/env bash
# fm-verdict-wait.sh - the one reader for a PR review verdict on either forge.
#
# Why this exists: reading the review verdict was re-invented as an ad-hoc poll
# in every worker, and both forges were read wrongly. On Forgejo crabd posts
# ONE tracking comment and edits it in place, so its created_at stays at the
# review-cycle start and only updated_at carries the verdict; a worker that
# waits for a new comment, or compares created_at against the head, waits until
# its timeout even though the verdict is already there. On GitHub the PR Agent
# posts a fresh describe comment per run, and the `**Verdict:**` line in the
# newest such comment is the signal. This script is the single reader and
# bounded waiter for both, so no worker needs its own poll loop.
#
# Verdict semantics are NOT redefined here. They are the existing ones from the
# org work-on-pr-review workflow:
#   Forgejo, the comment whose body contains <!-- crabd:tracking -->:
#     "Good to merge (LGTM)."                        mergeable
#     "Nits found."                                  mergeable (non-blocking)
#     any other bold span after "Reviewed this..."   blocking (reported verbatim,
#                                                    since only the two exact
#                                                    positive spans authorize ready)
#     a body without that reviewed-and-span shape    no verdict yet
#     no tracking comment at all                     no verdict yet
#   GitHub, the newest seibert-pr-agent comment carrying a `**Verdict:**` line:
#     "Good to merge"                                mergeable
#     any other value                                blocking
# A verdict is fresh only when its timestamp is STRICTLY NEWER than the PR
# head's commit time; a stale verdict is never reported as ready. CI is green
# only when the head's own checks say so; an absent or unreadable CI state is
# unknown, never green.
#
# Usage:
#   fm-verdict-wait.sh <pr-url> [--timeout <secs>] [--interval <secs>]
#                       [--no-ci] [--quiet]
#
#   <pr-url>            https://github.com/<owner>/<repo>/pull/<n> or
#                       https://<forgejo-host>/<owner>/<repo>/pulls/<n>
#   --timeout <secs>    Maximum wait in seconds; 0 reads once and reports the
#                       current state (default 1800). A harness with a shorter
#                       command limit can background the wait or pass a shorter
#                       timeout; re-running is always safe because this script
#                       only reads.
#   --interval <secs>   Seconds between reads (default 30)
#   --no-ci             Do not require green CI; wait for a fresh verdict only
#   --quiet             Suppress the per-read progress lines on stderr
#
# Exit codes:
#   0  ready: a fresh non-blocking verdict, and green CI unless --no-ci
#   1  the bounded wait elapsed without readiness; the line names exactly what
#      was missing (no verdict, verdict older than the head, or CI not green)
#   2  error: bad usage, unsupported URL or host, missing tool, or a PR that is
#      no longer open
#   3  action required: a fresh verdict blocks the merge (findings to address)
#   4  action required: the head's CI is red
#
# Dependencies: gh for GitHub, tea for Forgejo (with a login whose host matches
# the URL), jq, and date. The verdict comment is resolved by its forge-specific
# identity, never by "the newest comment" on Forgejo and never by created_at.
set -eu

SCRIPT_NAME=${0##*/}
LC_ALL=C
export LC_ALL

PROVIDER=
OWNER=
REPO=
NUMBER=
HOST=
TEA_LOGIN=
URL=
TIMEOUT=1800
INTERVAL=30
REQUIRE_CI=1
QUIET=0

usage() {
  cat <<'EOF'
usage: fm-verdict-wait.sh <pr-url> [--timeout <secs>] [--interval <secs>]
                          [--no-ci] [--quiet]

Read the review verdict for a pull request and wait, bounded, until it is fresh
and (by default) the head's CI is green.

  <pr-url>            https://github.com/<owner>/<repo>/pull/<n> or
                      https://<forgejo-host>/<owner>/<repo>/pulls/<n>
  --timeout <secs>    Maximum wait; 0 reads once and reports (default 1800)
  --interval <secs>   Seconds between reads (default 30)
  --no-ci             Do not require green CI; wait for a fresh verdict only
  --quiet             Suppress per-read progress lines on stderr
  -h, --help          Print this help

Exit codes: 0 ready, 1 timeout, 2 error, 3 blocking verdict, 4 CI red.
EOF
}

die() {
  printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 2
}

progress() {  # <elapsed-secs> <message>
  [ "$QUIET" = 1 ] && return 0
  printf '%s: %ss: waiting: %s\n' "$SCRIPT_NAME" "$1" "$2" >&2
}

valid_segment() {  # <path-segment>
  local s=${1-}
  [ -n "$s" ] && [ "${#s}" -le 100 ] || return 1
  case "$s" in
    .|..|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

parse_url() {
  local rest
  case "$URL" in
    https://github.com/*/pull/*)
      PROVIDER=github
      rest=${URL#https://github.com/}
      OWNER=${rest%%/*}
      rest=${rest#*/}
      REPO=${rest%%/*}
      rest=${rest#*/}
      case "$rest" in
        pull/*) NUMBER=${rest#pull/} ;;
        *) die "unsupported GitHub PR URL: $URL" ;;
      esac
      ;;
    https://*/pulls/*)
      PROVIDER=forgejo
      rest=${URL#https://}
      HOST=${rest%%/*}
      rest=${rest#*/}
      OWNER=${rest%%/*}
      rest=${rest#*/}
      REPO=${rest%%/*}
      rest=${rest#*/}
      case "$rest" in
        pulls/*) NUMBER=${rest#pulls/} ;;
        *) die "unsupported Forgejo PR URL: $URL" ;;
      esac
      ;;
    *) die "unsupported PR URL (expected https://github.com/<owner>/<repo>/pull/<n> or https://<forgejo-host>/<owner>/<repo>/pulls/<n>): $URL" ;;
  esac
  valid_segment "$OWNER" || die "invalid owner in PR URL: $URL"
  valid_segment "$REPO" || die "invalid repository in PR URL: $URL"
  case "$NUMBER" in
    ''|*[!0-9]*|0|0*) die "invalid PR number in URL: $URL" ;;
  esac
  case "$PROVIDER" in
    forgejo)
      case "$HOST" in
        ''|*[!A-Za-z0-9.:-]*) die "invalid host in PR URL: $URL" ;;
      esac
      ;;
  esac
}

iso_to_epoch() {  # <rfc3339-timestamp>
  local ts=${1-}
  [ -n "$ts" ] || return 1
  case "$ts" in
    *Z)
      ts=${ts%Z}
      date -u -d "${ts}Z" +%s 2>/dev/null && return 0
      TZ=UTC0 date -j -f '%Y-%m-%dT%H:%M:%S' "$ts" +%s 2>/dev/null && return 0
      return 1
      ;;
    *[+-][0-9][0-9]:[0-9][0-9])
      date -u -d "$ts" +%s 2>/dev/null && return 0
      ts=$(printf '%s' "$ts" | sed 's/\([+-][0-9][0-9]\):\([0-9][0-9]\)$/\1\2/')
      date -j -f '%Y-%m-%dT%H:%M:%S%z' "$ts" +%s 2>/dev/null && return 0
      return 1
      ;;
  esac
  return 1
}

resolve_forgejo_login() {
  command -v tea >/dev/null 2>&1 || die "tea CLI not found on PATH (required for a Forgejo PR)"
  local logins host_lc
  logins=$(tea logins list -o json 2>/dev/null) || die "could not read tea logins"
  host_lc=$(printf '%s' "$HOST" | tr '[:upper:]' '[:lower:]')
  TEA_LOGIN=$(printf '%s' "$logins" | jq -r --arg host "$host_lc" '
    [ .[] | select((.url // "") != "")
      | { name: (.name // ""),
          default: (((.default // "") | tostring) == "true"),
          host: ((.url // "") | sub("^[A-Za-z][A-Za-z0-9+.-]*://"; "") | sub("/.*$"; "") | ascii_downcase) } ]
    | map(select(.host == $host))
    | (map(select(.default)) + .)
    | first | .name // empty' 2>/dev/null) || die "could not parse tea logins"
  [ -n "$TEA_LOGIN" ] || die "no tea login for host $HOST; add one with 'tea login add'"
}

gh_read() {  # <api-path> [gh-api-flags...]
  local path=$1
  shift
  gh api "$path" "$@" 2>/dev/null
}

tea_read() {  # <api-path>
  tea api --login "$TEA_LOGIN" "$1" 2>/dev/null
}

read_pr() {
  local json
  if [ "$PROVIDER" = github ]; then
    json=$(gh_read "repos/$OWNER/$REPO/pulls/$NUMBER") || return 1
  else
    json=$(tea_read "/repos/$OWNER/$REPO/pulls/$NUMBER") || return 1
  fi
  printf '%s' "$json" | jq -r '[ (.head.sha // ""), (.state // ""), (((.merged // false) | tostring)) ] | @tsv' 2>/dev/null
}

read_head_time() {  # <sha>
  local json
  if [ "$PROVIDER" = github ]; then
    json=$(gh_read "repos/$OWNER/$REPO/commits/$1") || return 1
  else
    json=$(tea_read "/repos/$OWNER/$REPO/git/commits/$1") || return 1
  fi
  printf '%s' "$json" | jq -r '.commit.committer.date // empty' 2>/dev/null
}

read_forgejo_comments() {
  local page=1 batch count all
  all='[]'
  while [ "$page" -le 10 ]; do
    batch=$(tea_read "/repos/$OWNER/$REPO/issues/$NUMBER/comments?limit=50&page=$page") || return 1
    count=$(printf '%s' "$batch" | jq 'length' 2>/dev/null) || return 1
    case "$count" in
      ''|*[!0-9]*) return 1 ;;
    esac
    all=$(printf '%s\n%s\n' "$all" "$batch" | jq -cs '.[0] + .[1]' 2>/dev/null) || return 1
    if [ "$count" -lt 50 ]; then
      break
    fi
    page=$((page + 1))
  done
  printf '%s' "$all"
}

read_forgejo_verdict() {
  local comments
  comments=$(read_forgejo_comments) || return 1
  printf '%s' "$comments" | jq -r '
    [ .[] | select((.body // "") | contains("<!-- crabd:tracking -->"))
      | { updated: (.updated_at // ""), body: (.body // "") } ]
    | sort_by(.updated) | last
    | if . == null then "absent\u001f\u001f\u001f"
      elif ((.updated // "") | length) == 0 then "unrecognized\u001f\u001f\u001fcrabd tracking comment has no updated_at"
      else
        (.body | split("\n")[0] | gsub("<!--[^>]*-->"; "") | sub("[ \\t]+$"; "")) as $line
        | if ($line | test("^Reviewed this pull request")) then
            ($line | [scan("\\*\\*([^*]+)\\*\\*")]) as $spans
            | if ($spans | length) == 0 then "unrecognized\u001f\(.updated)\u001f\u001funrecognized verdict text: \($line)"
              else "verdict\u001f\(.updated)\u001f\($spans[0][0])\u001f" end
          else
            "in-flight\u001f\(.updated)\u001f\u001f\($line)"
          end
      end' 2>/dev/null
}

read_github_verdict() {
  local comments
  comments=$(gh_read "repos/$OWNER/$REPO/issues/$NUMBER/comments?per_page=100" --paginate --slurp) || return 1
  printf '%s' "$comments" | jq -r '
    [ .[] | .[]
      | select(((.user.login // "") | test("^seibert-pr-agent(\\[bot\\])?$"; "i")))
      | select(((.body // "") | test("(?m)^\\*\\*Verdict:\\*\\*")))
      | { created: (.created_at // ""), updated: ((.updated_at // .created_at) // ""), body: (.body // "") } ]
    | sort_by(.created) | last
    | if . == null then "absent\u001f\u001f\u001f"
      else
        (.body | [scan("(?m)^\\*\\*Verdict:\\*\\*[ \t]*([^\n\r]*)")]) as $vs
        | if ($vs | length) == 0 then "absent\u001f\u001f\u001f"
          else "verdict\u001f\(.updated)\u001f\($vs[0][0] | sub("[ \t]+$"; ""))\u001f" end
      end' 2>/dev/null
}

read_github_ci() {
  local out
  out=$(gh pr checks "$URL" --json bucket 2>/dev/null) || true
  case "$out" in
    \[*\]) ;;
    *) printf 'unknown'; return 0 ;;
  esac
  printf '%s' "$out" | jq -r '
    if length == 0 then "unknown"
    elif any(.[]; (.bucket // "") == "fail" or (.bucket // "") == "cancel") then "red"
    elif any(.[]; (.bucket // "") == "pending") then "pending"
    else "green" end' 2>/dev/null
}

read_forgejo_ci() {  # <sha>
  local json state total
  json=$(tea_read "/repos/$OWNER/$REPO/commits/$1/status") || return 1
  total=$(printf '%s' "$json" | jq -r '.total_count // 0' 2>/dev/null) || return 1
  state=$(printf '%s' "$json" | jq -r '.state // ""' 2>/dev/null) || return 1
  case "$total" in
    ''|*[!0-9]*) total=0 ;;
  esac
  if [ "$total" -gt 0 ]; then
    case "$state" in
      success) printf 'green' ;;
      pending) printf 'pending' ;;
      failure|error) printf 'red' ;;
      *) printf 'unknown' ;;
    esac
    return 0
  fi
  json=$(tea_read "/repos/$OWNER/$REPO/actions/tasks?limit=100") || return 1
  printf '%s' "$json" | jq -r --arg sha "$1" '
    [ .workflow_runs[]? | select((.head_sha // "") == $sha) ]
    | if length == 0 then "unknown"
      elif any(.[]; (.status // "") == "failure" or (.status // "") == "error" or (.status // "") == "cancelled") then "red"
      elif all(.[]; (.status // "") == "success" or (.status // "") == "skipped") then "green"
      else "pending" end' 2>/dev/null
}

POLL_HEAD=
POLL_HEAD_TIME=
POLL_HEAD_EPOCH=
POLL_VERDICT_STATE=
POLL_VERDICT_TIME=
POLL_VERDICT_EPOCH=
POLL_VERDICT_TEXT=
POLL_VERDICT_DETAIL=
POLL_CI=
POLL_READY=
POLL_ERROR=

poll_once() {
  local meta sha state merged verdict
  POLL_ERROR=
  meta=$(read_pr) || { POLL_ERROR="could not read PR metadata"; return 1; }
  IFS=$'\t' read -r sha state merged <<< "$meta" || { POLL_ERROR="unreadable PR metadata"; return 1; }
  case "$sha" in
    ''|*[!0-9A-Fa-f]*) POLL_ERROR="PR head is not a commit sha"; return 1 ;;
  esac
  if [ "${#sha}" -lt 7 ] || [ "${#sha}" -gt 64 ]; then
    POLL_ERROR="PR head is not a commit sha"; return 1
  fi
  if [ "$merged" = true ] || [ "$state" != open ]; then
    POLL_ERROR="PR is not open (state=${state:-unknown}, merged=$merged)"
    return 2
  fi
  POLL_HEAD=$sha

  POLL_HEAD_TIME=$(read_head_time "$sha") || { POLL_ERROR="could not read the head commit time"; return 1; }
  POLL_HEAD_EPOCH=$(iso_to_epoch "$POLL_HEAD_TIME") || { POLL_ERROR="unreadable head commit time: $POLL_HEAD_TIME"; return 1; }

  if [ "$PROVIDER" = github ]; then
    verdict=$(read_github_verdict) || { POLL_ERROR="could not read PR comments"; return 1; }
  else
    verdict=$(read_forgejo_verdict) || { POLL_ERROR="could not read PR comments"; return 1; }
  fi
  [ -n "$verdict" ] || { POLL_ERROR="empty verdict data"; return 1; }
  # The verdict protocol uses the ASCII unit separator, not tabs: tab is IFS
  # whitespace, so consecutive tabs would collapse and shift the fields.
  IFS=$'\x1f' read -r POLL_VERDICT_STATE POLL_VERDICT_TIME POLL_VERDICT_TEXT POLL_VERDICT_DETAIL <<< "$verdict" \
    || { POLL_ERROR="unreadable verdict data"; return 1; }
  POLL_VERDICT_EPOCH=
  if [ "$POLL_VERDICT_STATE" = verdict ]; then
    POLL_VERDICT_EPOCH=$(iso_to_epoch "$POLL_VERDICT_TIME") || { POLL_ERROR="unreadable verdict time: $POLL_VERDICT_TIME"; return 1; }
  fi

  if [ "$PROVIDER" = github ]; then
    POLL_CI=$(read_github_ci) || POLL_CI=unknown
  else
    POLL_CI=$(read_forgejo_ci "$sha") || POLL_CI=unknown
  fi
  case "$POLL_CI" in
    green|pending|red|unknown) ;;
    *) POLL_CI=unknown ;;
  esac

  local fresh=0
  if [ "$POLL_VERDICT_STATE" = verdict ] && [ "$POLL_VERDICT_EPOCH" -gt "$POLL_HEAD_EPOCH" ]; then
    fresh=1
  fi
  if [ "$POLL_CI" = red ]; then
    POLL_READY=ci-red
  elif [ "$fresh" = 1 ]; then
    if verdict_is_blocking; then
      POLL_READY=blocking
    elif [ "$REQUIRE_CI" = 1 ] && [ "$POLL_CI" != green ]; then
      POLL_READY=waiting-ci
    else
      POLL_READY=ready
    fi
  else
    POLL_READY=waiting-verdict
  fi
  return 0
}

verdict_is_blocking() {
  if [ "$PROVIDER" = github ]; then
    [ "$POLL_VERDICT_TEXT" != "Good to merge" ]
  else
    [ "$POLL_VERDICT_TEXT" != "Good to merge (LGTM)." ] && [ "$POLL_VERDICT_TEXT" != "Nits found." ]
  fi
}

verdict_phrase() {
  if [ "$POLL_VERDICT_STATE" = verdict ]; then
    if [ -n "$POLL_VERDICT_EPOCH" ] && [ "$POLL_VERDICT_EPOCH" -gt "$POLL_HEAD_EPOCH" ]; then
      printf 'verdict "%s" at %s is fresh' "$POLL_VERDICT_TEXT" "$POLL_VERDICT_TIME"
    else
      printf 'verdict "%s" at %s is older than the head' "$POLL_VERDICT_TEXT" "$POLL_VERDICT_TIME"
    fi
  else
    printf 'no fresh verdict'
  fi
}

poll_summary() {
  case "$POLL_READY" in
    waiting-ci) printf 'verdict fresh ("%s"); ci %s' "$POLL_VERDICT_TEXT" "$POLL_CI" ;;
    waiting-verdict)
      case "$POLL_VERDICT_STATE" in
        absent) printf 'no verdict yet; ci %s' "$POLL_CI" ;;
        in-flight) printf 'crabd review in progress; ci %s' "$POLL_CI" ;;
        unrecognized) printf 'verdict not recognized (%s); ci %s' "$POLL_VERDICT_DETAIL" "$POLL_CI" ;;
        verdict) printf 'verdict older than head; ci %s' "$POLL_CI" ;;
        *) printf 'not ready; ci %s' "$POLL_CI" ;;
      esac
      ;;
    *) printf 'not ready' ;;
  esac
}

report_ready() {
  printf 'ready: verdict "%s" at %s covers head %s (%s); ci %s\n' \
    "$POLL_VERDICT_TEXT" "$POLL_VERDICT_TIME" "$POLL_HEAD" "$POLL_HEAD_TIME" "$POLL_CI"
}

report_blocking() {
  printf 'action-required: verdict "%s" at %s covers head %s (%s); ci %s\n' \
    "$POLL_VERDICT_TEXT" "$POLL_VERDICT_TIME" "$POLL_HEAD" "$POLL_HEAD_TIME" "$POLL_CI"
}

report_ci_red() {
  printf 'action-required: ci red on head %s (%s); %s\n' \
    "$POLL_HEAD" "$POLL_HEAD_TIME" "$(verdict_phrase)"
}

report_timeout() {  # <elapsed-secs>
  local elapsed=$1 horizon reason
  horizon="after ${elapsed}s"
  if [ "$TIMEOUT" = 0 ]; then
    horizon='(single read)'
  fi
  if [ -n "$POLL_ERROR" ]; then
    printf 'timeout: no fresh verdict %s: last read failed (%s)\n' "$horizon" "$POLL_ERROR"
    return 0
  fi
  case "$POLL_READY" in
    waiting-ci)
      reason=$(printf 'ci not green (state=%s) with a fresh verdict "%s" at %s' "$POLL_CI" "$POLL_VERDICT_TEXT" "$POLL_VERDICT_TIME")
      ;;
    waiting-verdict)
      case "$POLL_VERDICT_STATE" in
        absent)
          if [ "$PROVIDER" = forgejo ]; then
            reason="no verdict found (no crabd tracking comment on the PR)"
          else
            reason='no verdict found (no seibert-pr-agent comment with a **Verdict:** line)'
          fi
          ;;
        in-flight) reason='no verdict found (crabd review still in progress)' ;;
        unrecognized) reason=$(printf 'no verdict found (%s)' "$POLL_VERDICT_DETAIL") ;;
        verdict) reason=$(printf 'the verdict is older than the head (verdict %s, head %s committed %s)' "$POLL_VERDICT_TIME" "$POLL_HEAD" "$POLL_HEAD_TIME") ;;
        *) reason='no verdict found' ;;
      esac
      ;;
    *) reason='not ready' ;;
  esac
  printf 'timeout: no fresh verdict %s: %s; ci %s\n' "$horizon" "$reason" "$POLL_CI"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --timeout)
      [ "$#" -ge 2 ] || die "--timeout needs a value"
      TIMEOUT=$2
      shift 2
      ;;
    --timeout=*) TIMEOUT=${1#*=}; shift ;;
    --interval)
      [ "$#" -ge 2 ] || die "--interval needs a value"
      INTERVAL=$2
      shift 2
      ;;
    --interval=*) INTERVAL=${1#*=}; shift ;;
    --no-ci) REQUIRE_CI=0; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *)
      [ -z "$URL" ] || die "unexpected extra argument: $1"
      URL=$1
      shift
      ;;
  esac
done
[ -n "$URL" ] || { usage >&2; exit 2; }
case "$TIMEOUT" in
  ''|*[!0-9]*) die "--timeout must be a non-negative integer" ;;
esac
case "$INTERVAL" in
  ''|*[!0-9]*) die "--interval must be a positive integer" ;;
esac
[ "$INTERVAL" -ge 1 ] || die "--interval must be a positive integer"

parse_url
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
case "$PROVIDER" in
  github) command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH (required for a GitHub PR)" ;;
  forgejo) resolve_forgejo_login ;;
esac

start_epoch=$(date +%s)
consecutive_errors=0

while :; do
  elapsed=$(( $(date +%s) - start_epoch ))
  rc=0
  poll_once || rc=$?
  case "$rc" in
    0) consecutive_errors=0 ;;
    2) die "$POLL_ERROR" ;;
    *) consecutive_errors=$((consecutive_errors + 1)) ;;
  esac

  if [ "$rc" = 0 ]; then
    case "$POLL_READY" in
      ready) report_ready; exit 0 ;;
      blocking) report_blocking; exit 3 ;;
      ci-red) report_ci_red; exit 4 ;;
    esac
    progress "$elapsed" "$(poll_summary)"
  else
    if [ "$consecutive_errors" -ge 3 ]; then
      die "could not read PR state after $consecutive_errors attempts: $POLL_ERROR"
    fi
    progress "$elapsed" "read failed ($POLL_ERROR)"
  fi

  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    report_timeout "$elapsed"
    exit 1
  fi
  # Never sleep past the deadline: the bounded wait must end at the timeout,
  # not one full interval after it.
  remaining=$((TIMEOUT - elapsed))
  if [ "$remaining" -gt "$INTERVAL" ]; then
    remaining=$INTERVAL
  fi
  [ "$remaining" -ge 1 ] || remaining=1
  sleep "$remaining"
done
