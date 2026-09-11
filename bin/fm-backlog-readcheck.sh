#!/usr/bin/env bash
# fm-backlog-readcheck.sh - read-only read-time reconciliation of the backlog
# against the sources that own the truth: each In-flight row's last status
# line, its recorded endpoint, and the worktree slots its task records claim.
#
# Why this exists: a backlog row is written once and then trusted forever, so a
# worker that finished, failed, or was replaced leaves its row In flight until a
# human notices. The same freeze happens to a `done-pending-verify` note that
# records a PR state once: the forge moves on, the note does not. This script
# reconciles at READ time and reports only. It never mutates the backlog, a task
# record, or an endpoint, and it never decides a transition - firstmate owns
# that decision, this audit only makes the contradiction visible.
#
# Findings (one line each, always on stdout):
#   STALE_INFLIGHT: <id> (<state>)
#     The row is In flight, the last status line carries a terminal verb
#     (done/failed/cancelled), and the recorded endpoint is authoritatively
#     gone. `gone` is tmux/herdr's recovery-grade `dead` or `missing` verdict
#     (bin/fm-backend.sh fm_backend_agent_state); a backend with no classifier
#     only counts a positively absent target. A terminal row whose endpoint
#     still answers is deliberately NOT reported: it may be waiting on a merge
#     decision, not abandoned.
#   SHARED_SLOT: <id>,<id> share worktree <path>
#     Two or more task records claim the same worktree and every one of them is
#     terminal, so teardown's live-work guard has no way through and a human
#     must resolve which record owns the slot.
#   DONE_NOTE_STALE: <id> <url> (note=<claim> api=<actual>)
#     (--api only) A `done-pending-verify` note claims a PR state the forge no
#     longer reports, for example note=open api=merged.
#   API_SKIP: <url> (<reason>)
#     (--api only) That URL could not be checked, with the reason.
#
# Endpoint liveness is never PID-based. After a kernel PID wrap a stored PID can
# name an unrelated process, so a bare kill -0 is not evidence of anything; this
# script consults no stored PID at all and asks the backend's recovery-grade
# process classifier about the recorded pane/target. Any future liveness read
# here that must use a PID has to compare the full PID+starttime identity
# (bin/fm-wake-lib.sh fm_pid_identity, field 22 of /proc/<pid>/stat or ps
# lstart), never kill -0 alone.
#
# Read-only and side-effect free: every run exits 0, including a run that found
# contradictions or could not reach a forge, so a digest or pre-dispatch caller
# never turns an audit finding into a failed command.
#
# Usage:
#   fm-backlog-readcheck.sh [--digest] [--limit N] [--api]
#   --digest   Bounded output for the session-start digest: at most N finding
#              lines (default 5, FM_READCHECK_DIGEST_LIMIT), then one disclosed
#              remainder line; prints `(none)` when clean.
#   --limit N  Override the finding bound (0 = unlimited).
#   --api      Additionally check `done-pending-verify` notes against the real
#              forge state (network; standalone only). GitHub uses `gh`;
#              Forgejo/Gitea uses curl against
#              https://<host>/api/v1/repos/<owner>/<repo>/pulls/<n> and needs
#              FM_FORGEJO_TOKEN (or FORGEJO_TOKEN). FM_FORGEJO_HOST restricts
#              that token to one host when several forges appear in the backlog.
#
# Integration: bin/fm-session-start.sh runs `--digest` in its FLEET STATE
# section, and firstmate can run it standalone before dispatching new work.
# Removing that one digest call plus this file reverses the whole change.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, and FM_DATA_OVERRIDE resolve as in
# every script; FM_READCHECK_DIGEST_LIMIT; FM_FORGEJO_TOKEN or FORGEJO_TOKEN;
# FM_FORGEJO_HOST; FM_READCHECK_API_TIMEOUT (seconds, default 10);
# FM_READCHECK_API_MAX (default 10, bounds network calls per run).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BACKLOG="$DATA/backlog.md"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

DIGEST=0
API=0
LIMIT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --digest)
      DIGEST=1
      shift
      ;;
    --api)
      API=1
      shift
      ;;
    --limit)
      LIMIT=${2:-}
      if [ "$#" -ge 2 ]; then shift 2; else shift; fi
      ;;
    --limit=*)
      LIMIT=${1#--limit=}
      shift
      ;;
    -h|--help)
      sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'
      exit 0
      ;;
    *)
      printf 'fm-backlog-readcheck: unknown argument: %s\n' "$1" >&2
      printf 'usage: fm-backlog-readcheck.sh [--digest] [--limit N] [--api]\n' >&2
      exit 2
      ;;
  esac
done

if [ -z "$LIMIT" ]; then
  if [ "$DIGEST" -eq 1 ]; then
    LIMIT=${FM_READCHECK_DIGEST_LIMIT:-5}
  else
    LIMIT=0
  fi
fi
case "$LIMIT" in ''|*[!0-9]*) LIMIT=5 ;; esac

API_TIMEOUT=${FM_READCHECK_API_TIMEOUT:-10}
case "$API_TIMEOUT" in ''|*[!0-9]*|0) API_TIMEOUT=10 ;; esac
API_MAX=${FM_READCHECK_API_MAX:-10}
case "$API_MAX" in ''|*[!0-9]*|0) API_MAX=10 ;; esac

# --- finding emission -------------------------------------------------------
# Streamed rather than accumulated: bash 3.2 (the stock macOS shell) treats
# "${arr[@]}" on an empty array as an unbound variable under set -u, and the
# digest's bound only needs a printed count and a remainder.
FINDING_COUNT=0
PRINTED_COUNT=0
SKIP_COUNT=0
emit_finding() {  # <line>
  FINDING_COUNT=$((FINDING_COUNT + 1))
  if [ "$LIMIT" -gt 0 ] && [ "$PRINTED_COUNT" -ge "$LIMIT" ]; then
    return 0
  fi
  if [ "$DIGEST" -eq 1 ]; then
    fm_cap_line "$1"
  else
    printf '%s\n' "$1"
  fi
  PRINTED_COUNT=$((PRINTED_COUNT + 1))
}

# --- (a) stale in-flight rows ----------------------------------------------

# The ids of every title line in the backlog's In flight section. The heading
# and title shape are the tasks-axi markdown backend's own layout, the same
# shape bin/fm-session-start.sh's manual listing recognizes, so this works with
# tasks-axi and with a manual-backend home alike.
list_in_flight_ids() {  # <backlog>
  [ -f "$1" ] || return 0
  awk '
    /^##[[:space:]]+/ {
      heading = $0
      sub(/^##[[:space:]]+/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      in_flight = (heading == "In flight")
      next
    }
    in_flight && /^- \[[ x]\] / {
      line = $0
      sub(/^- \[[ x]\] /, "", line)
      sub(/[[:space:]].*/, "", line)
      if (line != "") print line
    }
  ' "$1"
}

# The terminal verb of one task's last status line, or nothing. Only the
# worker-is-finished verbs count: `needs-decision` and `blocked` mean firstmate
# action is still owed and are not stale-in-flight findings, and a missing or
# nonterminal log proves nothing.
readcheck_terminal_state() {  # <id> -> done|failed|cancelled|empty
  local status="$STATE/$1.status" line verb
  [ -f "$status" ] || return 0
  line=$(last_status_line "$status")
  [ -n "$line" ] || return 0
  verb=$(status_line_verb "$line")
  case "$verb" in
    done|failed|cancelled) printf '%s' "$verb" ;;
  esac
}

# alive, dead, or unknown for one task's recorded endpoint. `dead` is positive
# death evidence only: tmux/herdr's recovery classifier `dead`/`missing`, or a
# classifier-less backend whose recorded target is positively absent. Every
# ambiguous, unreadable, or unverified read stays unknown so a transient probe
# failure never reads as an abandoned worker.
readcheck_endpoint_verdict() {  # <id> -> alive|dead|unknown
  local meta="$STATE/$1.meta" backend target state
  [ -f "$meta" ] || { printf 'unknown'; return 0; }
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || { printf 'unknown'; return 0; }
  backend=$(fm_backend_of_meta "$meta")
  if ! fm_backend_source "$backend" >/dev/null 2>&1; then
    printf 'unknown'
    return 0
  fi
  case "$backend" in
    tmux|herdr)
      state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || state=unreadable
      case "$state" in
        dead|missing) printf 'dead' ;;
        *) printf 'unknown' ;;
      esac
      ;;
    *)
      if fm_backend_target_exists "$backend" "$target" "fm-$1" >/dev/null 2>&1; then
        printf 'alive'
      else
        printf 'dead'
      fi
      ;;
  esac
}

check_stale_inflight() {
  local id state verdict
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$id" in ''|.*|*[!A-Za-z0-9._-]*) continue ;; esac
    state=$(readcheck_terminal_state "$id")
    [ -n "$state" ] || continue
    verdict=$(readcheck_endpoint_verdict "$id")
    [ "$verdict" = dead ] || continue
    emit_finding "STALE_INFLIGHT: $id ($state)"
  done < <(list_in_flight_ids "$BACKLOG")
}

# --- (b) shared worktree slots ----------------------------------------------

# A symlinked or trailing-slash spelling of the same worktree must group with
# its plain form, so compare canonical real paths; a path whose directory is
# already gone keeps its literal spelling, which is all a torn-down record can
# still be matched on.
readcheck_canon_path() {  # <path>
  local p=$1
  if [ -d "$p" ]; then
    (cd "$p" 2>/dev/null && pwd -P) || printf '%s' "${p%/}"
  else
    printf '%s' "${p%/}"
  fi
}

check_shared_slots() {
  while IFS= read -r line; do emit_finding "$line"; done < <(readcheck_shared_slot_rows)
}

# One grouped SHARED_SLOT line per worktree that two or more terminal task
# records still claim.
readcheck_shared_slot_rows() {
  local meta id wt state
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    case "$id" in ''|.*|*[!A-Za-z0-9._-]*) continue ;; esac
    wt=$(fm_meta_get "$meta" worktree)
    [ -n "$wt" ] || continue
    state=$(readcheck_terminal_state "$id")
    [ -n "$state" ] || continue
    printf '%s\t%s\n' "$(readcheck_canon_path "$wt")" "$id"
  done | LC_ALL=C sort | awk -F '\t' '
    function flush() {
      if (count >= 2) print "SHARED_SLOT: " ids " share worktree " key
    }
    BEGIN { count = 0; ids = ""; key = "" }
    {
      if ($1 != key) { flush(); key = $1; ids = $2; count = 1; next }
      ids = ids "," $2
      count++
    }
    END { flush() }
  '
}

# --- (c) done-pending-verify notes against the forge ------------------------

# One candidate per PR URL on a `done-pending-verify` line, with the item id it
# belongs to and the first claim word on the line. Leftmost claim wins so
# "GEMERGT ... OFFENER REST" reads merged while "offen ... nach Merge" reads
# open, which is what those two note shapes mean.
readcheck_api_candidates() {  # <backlog>
  [ -f "$1" ] || return 0
  awk '
    /^- \[[ x]\] / {
      id = $0
      sub(/^- \[[ x]\] /, "", id)
      sub(/[[:space:]].*/, "", id)
      next
    }
    /done-pending-verify/ {
      lower = tolower($0)
      claim = ""
      if (match(lower, /merged|gemergt|offen|open|closed|geschlossen/)) {
        token = substr(lower, RSTART, RLENGTH)
        if (token == "merged" || token == "gemergt") claim = "merged"
        else if (token == "offen" || token == "open") claim = "open"
        else claim = "closed"
      }
      rest = $0
      while (match(rest, /https:\/\/[^ )]+/)) {
        url = substr(rest, RSTART, RLENGTH)
        if (url ~ /\/pull\/[0-9]+$/ || url ~ /\/pulls\/[0-9]+$/ || url ~ /\/-\/merge_requests\/[0-9]+$/) {
          printf "%s\t%s\t%s\n", id, url, claim
        }
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
  ' "$1"
}

readcheck_github_state() {  # <url>
  local state
  command -v gh >/dev/null 2>&1 || { printf 'gh not installed'; return 0; }
  state=$(gh pr view "$1" --json state -q .state 2>/dev/null) || { printf 'gh query failed'; return 0; }
  case "$state" in
    OPEN) printf 'open' ;;
    CLOSED) printf 'closed' ;;
    MERGED) printf 'merged' ;;
    *) printf 'gh reported %s' "${state:-nothing}" ;;
  esac
}

readcheck_forgejo_state() {  # <url>
  local rest host owner repo number token body merged state api
  rest=${1#https://}
  host=${rest%%/*}
  rest=${rest#*/}
  case "$rest" in
    */pulls/*) ;;
    *) printf 'unsupported URL shape'; return 0 ;;
  esac
  repo=${rest%%/pulls/*}
  number=${rest##*/pulls/}
  case "$number" in ''|*[!0-9]*) printf 'unsupported URL shape'; return 0 ;; esac
  case "$repo" in
    */*) owner=${repo%/*}; repo=${repo##*/} ;;
    *) printf 'unsupported URL shape'; return 0 ;;
  esac
  if [ -n "${FM_FORGEJO_HOST:-}" ] && [ "$FM_FORGEJO_HOST" != "$host" ]; then
    printf 'FM_FORGEJO_HOST does not cover %s' "$host"
    return 0
  fi
  token=${FM_FORGEJO_TOKEN:-${FORGEJO_TOKEN:-}}
  [ -n "$token" ] || { printf 'set FM_FORGEJO_TOKEN or FORGEJO_TOKEN to check Forgejo'; return 0; }
  command -v curl >/dev/null 2>&1 || { printf 'curl not installed'; return 0; }
  api="https://$host/api/v1/repos/$owner/$repo/pulls/$number"
  body=$(curl -fsS -m "$API_TIMEOUT" -H "Authorization: token $token" "$api" 2>/dev/null) \
    || { printf 'forgejo API query failed'; return 0; }
  merged=$(printf '%s' "$body" | sed -n 's/.*"merged"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' | head -1)
  state=$(printf '%s' "$body" | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([A-Za-z]*\)".*/\1/p' | head -1)
  case "$merged:$state" in
    true:*) printf 'merged' ;;
    false:closed) printf 'closed' ;;
    false:open) printf 'open' ;;
    *) printf 'unreadable forgejo API response' ;;
  esac
}

check_api_notes() {
  local id url claim actual calls=0
  while IFS=$'\t' read -r id url claim; do
    [ -n "$url" ] || continue
    calls=$((calls + 1))
    if [ "$calls" -gt "$API_MAX" ]; then
      printf 'API_SKIP: %s (API check bound of %s reached)\n' "$url" "$API_MAX"
      SKIP_COUNT=$((SKIP_COUNT + 1))
      continue
    fi
    case "$url" in
      https://github.com/*) actual=$(readcheck_github_state "$url") ;;
      https://*/*/pulls/[0-9]*) actual=$(readcheck_forgejo_state "$url") ;;
      *) actual='unsupported forge' ;;
    esac
    case "$actual" in
      open|closed|merged) ;;
      *)
        printf 'API_SKIP: %s (%s)\n' "$url" "$actual"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
        ;;
    esac
    [ -n "$claim" ] || continue
    [ "$claim" != "$actual" ] || continue
    emit_finding "DONE_NOTE_STALE: $id $url (note=$claim api=$actual)"
  done < <(readcheck_api_candidates "$BACKLOG")
}

# --- run --------------------------------------------------------------------

check_stale_inflight
check_shared_slots
[ "$API" -eq 0 ] || check_api_notes

if [ "$FINDING_COUNT" -eq 0 ] && [ "$SKIP_COUNT" -eq 0 ]; then
  printf '(none)\n'
fi
if [ "$FINDING_COUNT" -gt "$PRINTED_COUNT" ]; then
  printf '(%s more finding(s) - run bin/fm-backlog-readcheck.sh for the full list)\n' \
    "$((FINDING_COUNT - PRINTED_COUNT))"
fi
exit 0
