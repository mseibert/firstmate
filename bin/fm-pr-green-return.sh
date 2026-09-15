#!/usr/bin/env bash
# fm-pr-green-return.sh - the green-PR return path: surface the bound merge a
# task's PR already earned, so a green pull request does not rot unnoticed.
#
# WHY. A task's PR can end up green, mergeable, and policy-clean while the merge
# itself is never requested, and nothing notices. This scan is the bounded,
# poll-loop-owned return path: for every own task that records a pr= line, it
# reads the live pull request, applies the merge policy in ~/.claude/pr-policy.md
# (hard stops and the autonomous allowlist), and, once the PR has held the same
# verdict for the configured wait, queues a check wake for MAIN:
#   - due  (green + mergeable + no policy hold + repo allowlisted + a forge
#     whose merge path can bind a head): the wake carries the mandate to merge
#     through bin/fm-pr-merge.sh with --expected-head naming the head this scan
#     verified, and the merge path refuses a live head that differs. The merge
#     itself is bound to the verified head by Forgejo's head_commit_id and
#     GitLab's --sha. The scan itself never merges, and only main-owned check
#     wakes can carry that mandate.
#   - held (a policy hard stop, the allowlist default ask, or a GitHub PR whose
#     merge path cannot bind the head): the wake names the reason and asks for
#     the captain's decision instead of a merge.
# Whether the merge actually lands is still decided live at merge time by
# bin/fm-pr-merge.sh; this path is a detector and a wake, never a merge.
#
# OWNERSHIP. Membership is exactly the first valid pr= line in state/<id>.meta,
# resolved through bin/fm-pr-lib.sh, and the live PR state is read through the
# same provider paths firstmate already uses: gh for GitHub, tea for Forgejo,
# glab for GitLab. A merged or closed PR is not this path's business - the
# task's existing merge poll owns that outcome - and a foreign PR (an author
# that is not the authenticated operator) is held by hard stop 6, never merged.
#
# WAIT. The wait threshold is config/pr-green-return (one positive decimal
# integer, seconds; default 600) and FM_PR_GREEN_RETURN_SECS overrides it for a
# test or an explicit one-off run. The wait start is evidence-backed for a due
# PR - the later of the head commit time and the fresh verdict time - so a PR
# that has been green and mergeable for hours wakes on the first scan instead of
# restarting the clock. A held PR must hold the same reason for the whole wait
# before it is reported, so a transient state under active work does not wake
# anyone. state/pr-green-return/<id> records the observed identity, class,
# reason, wait start, and notification, so a restart never resets the wait and
# one (head, class, reason) is reported once. Both classes share one task wake
# key, so a newly queued row for the task supersedes its previous one under the
# drain's newest-row-per-key view. A queued mandate is not revoked when the
# verdict changes: bin/fm-pr-merge.sh re-verifies the live verdict at merge time
# and refuses a mandate this scan no longer finds due. A notification is
# suppressed only by the record's own (head, class, reason) value, never by a
# key merely being present.
#
# EDGE SEMANTICS. A repo with no checks at all trips hard stop 4 (an empty
# combined status is never green), and a check set that is pending or unreadable
# is never green. A `skipped` check status is a pass, matching Forgejo's own
# combined-state semantics and the GitHub mapping; a GitLab `skipped` head
# pipeline and a Forgejo combined `skipped` head are no checks and trip hard
# stop 4, and a Forgejo combined `warning` is classified through its statuses.
# The policy's Coolify `deploy / deploy` preview exception is machine-waived: a
# failing check whose normalized name is exactly that poller does not turn the
# check set red by itself, and every other failing check still trips hard stop 3.
# A Forgejo head kept green only by that waiver stays policy-clean but is held
# with the no-bound-merge reason, because the protected merge path requires the
# live combined status to be exactly `success`.
# The five-lens gate (hard stop 1) is accepted as
# `Result: clean`, as a table whose every row ran and closed its findings, or as
# at least five per-lens result entries, each positively naming a clean result
# (`clean`, `passed`/`pass`, or a `kein`/`no blocker` entry); any other wording,
# or a line naming an open finding, trips the stop. An `open`/`offen` word (or
# its German inflections) is a finding unless a negation reaches it inside its
# own clause or result cell; a positive count before `finding(s)` is a finding
# unless the count is immediately qualified as fixed, closed, resolved, or
# behoben, and a positive count before `remain(s)`, `remaining`, `left`,
# `unresolved`, or `outstanding` is always a finding. The evidence is read from
# the PR body and, when the task's mode is no-mistakes or the body carries no
# gate block, from the newest exact-titled
# comment of the authenticated operator; a clean read from either source
# passes, and an unreadable, untitled, or foreign-authored comment is never
# green. The review verdict (item 2)
# follows the policy's forge-specific channels - GitHub's newest seibert-pr-agent
# `**Verdict:**` comment, Forgejo's crabd tracking comment - and the policy's
# current wording makes that item advisory, not a gate: a verdict that never
# arrives does not hold the merge, while one that asks for changes, or a verdict
# channel that cannot be read, holds for the captain's own read. Nothing is held
# for a forge the policy defines no verdict channel for; there is simply no
# second opinion to read. A lockfile glob from hard stop 5 is skipped because
# mergeable=true already proves the "only on conflict" condition false, and a
# package.json match holds only when its base and head scripts blocks differ or
# cannot be read. `.forgejo/workflows/**` is matched as built-in hard stop 5
# ground in addition to the policy's parsed globs, because the policy's own
# allowlist rows name it while its Section 5 glob block omits it. The
# changed-file list is trusted only once the read proves it complete: Forgejo
# pages until a short page, a GitLab `overflow: true` response fails closed, and
# a rename contributes its old path as well as its new one to the sensitive set.
#
# CHECK WAKE ROUTING. The queued rows are check kind, which the Pi supervision
# branch never offers to the branch actor (docs/pi-supervision-branch.md), so the
# merge mandate can only reach main. bin/fm-watch.sh owns the poll loop that
# invokes `scan`; merge ownership itself is bin/fm-lease-lib.sh's partition.
#
# Usage:
#   fm-pr-green-return.sh scan            # evaluate own-task PRs, keep the wait,
#                                         # queue one check wake per due or held PR
#   fm-pr-green-return.sh report [<id>...]# read-only evaluation table; no writes
#   fm-pr-green-return.sh -h|--help
#
# Environment:
#   FM_PR_GREEN_RETURN_SECS       wait threshold override in seconds
#   FM_PR_GREEN_RETURN_POLICY     policy file override (default ~/.claude/pr-policy.md)
#   FM_PR_GREEN_RETURN_INTERVAL   seconds between scans in one poll loop (default 60)
#   FM_PR_GREEN_RETURN_BUDGET_SECS  aggregate scan budget (default 45)
#   FM_PR_GREEN_RETURN_CMD_TIMEOUT  bound for one provider command (default 20)
#   FM_PR_GREEN_RETURN_FORCE=1    bypass the scan cadence (tests/one-off)
#   FM_PR_GREEN_RETURN_NOW        whole-second clock override (tests)
#
# report prints one tab-separated line per candidate:
#   <id> <class> <reason> <url> <head> since=<epoch> age=<seconds>
#
# Dependencies: the provider CLI for each task's forge, jq, and the repository
# scripts sourced below.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

RECORD_DIR="$STATE/pr-green-return"
SCAN_MARKER="$STATE/.last-pr-green-return"
SCAN_LOCK="$STATE/.pr-green-return.lock"

DEFAULT_WAIT_SECS=600
DEFAULT_INTERVAL_SECS=60
DEFAULT_BUDGET_SECS=45
DEFAULT_CMD_TIMEOUT_SECS=20
WAIT_CONFIG_NAME=pr-green-return
WAIVED_CHECK_NAME='deploy / deploy'
# Built-in hard stop 5 ground that the policy's Section 5 glob block may omit.
BUILTIN_SENSITIVE_GLOBS='.forgejo/workflows/**'
API_PAGE_LIMIT=50
API_PAGE_MAX=40

# The runtime knobs keep a bounded scan bounded even on a slow forge. Only the
# wait threshold is captain-configurable; the cadence, budget, and per-command
# bound are operational defaults an operator can still override by env.
FM_PR_GREEN_RETURN_SECS=${FM_PR_GREEN_RETURN_SECS:-}
FM_PR_GREEN_RETURN_INTERVAL=${FM_PR_GREEN_RETURN_INTERVAL:-$DEFAULT_INTERVAL_SECS}
FM_PR_GREEN_RETURN_BUDGET_SECS=${FM_PR_GREEN_RETURN_BUDGET_SECS:-$DEFAULT_BUDGET_SECS}
FM_PR_GREEN_RETURN_CMD_TIMEOUT=${FM_PR_GREEN_RETURN_CMD_TIMEOUT:-$DEFAULT_CMD_TIMEOUT_SECS}
FM_PR_GREEN_RETURN_POLICY=${FM_PR_GREEN_RETURN_POLICY:-${HOME:-}/.claude/pr-policy.md}
FM_PR_GREEN_RETURN_FORCE=${FM_PR_GREEN_RETURN_FORCE:-0}

for _name in FM_PR_GREEN_RETURN_INTERVAL FM_PR_GREEN_RETURN_BUDGET_SECS FM_PR_GREEN_RETURN_CMD_TIMEOUT; do
  _value=${!_name}
  case "$_value" in
    ''|*[!0-9]*|0)
      printf 'fm-pr-green-return: %s must be a positive whole number of seconds (got %s)\n' "$_name" "$_value" >&2
      exit 2
      ;;
  esac
done

now_epoch() {
  case "${FM_PR_GREEN_RETURN_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_PR_GREEN_RETURN_NOW" ;;
  esac
}

if [ "$(uname)" = Darwin ]; then
  file_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

# iso_to_epoch <rfc3339-timestamp>: GNU date first, BSD date second, so a home
# on either platform reads the forge's timestamps.
iso_to_epoch() {
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

field_of() { # <file> <name>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# wait_secs: env override, then the local config file, then the default. The
# config value is one positive decimal integer and one newline; anything else is
# an actionable configuration error (return 2) rather than a silently different
# wait. Sets WAIT_SECS_RESOLVED so no caller runs it in a subshell where its
# error return would be lost.
WAIT_SECS_RESOLVED=
wait_secs() {
  local value=$FM_PR_GREEN_RETURN_SECS file
  WAIT_SECS_RESOLVED=
  if [ -n "$value" ]; then
    case "$value" in
      ''|*[!0-9]*|0)
        printf 'fm-pr-green-return: FM_PR_GREEN_RETURN_SECS must be a positive whole number of seconds (got %s)\n' "$value" >&2
        return 2
        ;;
    esac
    WAIT_SECS_RESOLVED=$value
    return 0
  fi
  file="$CONFIG/$WAIT_CONFIG_NAME"
  if [ -e "$file" ] || [ -L "$file" ]; then
    if [ -L "$file" ] || [ ! -f "$file" ]; then
      printf 'fm-pr-green-return: %s must be a regular file holding one positive whole number of seconds\n' "$file" >&2
      return 2
    fi
    value=$(cat "$file" 2>/dev/null || true)
    case "$value" in
      ''|*[!0-9]*|0)
        printf 'fm-pr-green-return: %s must hold one positive whole number of seconds (got %s)\n' "$file" "$value" >&2
        return 2
        ;;
    esac
    WAIT_SECS_RESOLVED=$value
    return 0
  fi
  WAIT_SECS_RESOLVED=$DEFAULT_WAIT_SECS
  return 0
}

# ---------------------------------------------------------------- policy ----

# The policy file is the single owner of the hard-stop wording; this section
# only parses what it needs: the autonomous allowlist names and the sensitive
# path globs. Anything unparseable leaves POLICY_OK=0 and every candidate is
# held by hard stop 7.
POLICY_OK=0
POLICY_ALLOWLIST=
POLICY_GLOBS=

policy_load() {
  local file=$FM_PR_GREEN_RETURN_POLICY allow globs rule_seen=0
  POLICY_OK=0
  POLICY_ALLOWLIST=
  POLICY_GLOBS=
  if [ -z "$file" ] || [ ! -f "$file" ] || [ -L "$file" ] || [ ! -r "$file" ]; then
    return 0
  fi
  allow=$(awk '
    /^## / {
      if ($0 ~ /^## The rule/) { inrule = 1; next }
      if (inrule) { exit }
      next
    }
    inrule { print }
  ' "$file" 2>/dev/null) || return 0
  case "$allow" in
    *'| Repo |'*) rule_seen=1 ;;
  esac
  [ "$rule_seen" = 1 ] || return 0
  POLICY_ALLOWLIST=$(printf '%s\n' "$allow" | awk -F'|' '
    NF >= 4 {
      name = $2
      verdict = $3
      gsub(/^[ \t]+|[ \t]+$/, "", name)
      gsub(/^[ \t]+|[ \t]+$/, "", verdict)
      if (tolower(verdict) == "autonomous" && name != "") print name
    }
  ')
  globs=$(awk '
    /^### 5\./ { in5 = 1 }
    in5 && /against:/ { seen = 1; next }
    in5 && seen && /^```/ { fence++; next }
    in5 && fence == 1 { print }
    in5 && fence >= 2 { exit }
  ' "$file" 2>/dev/null) || return 0
  POLICY_GLOBS=$(printf '%s\n' "$globs" | sed 's/(.*$//' | tr -s ' \t' '\n' \
    | grep -E '^[A-Za-z0-9._*/-]+$' || true)
  [ -n "$POLICY_GLOBS" ] || return 0
  POLICY_OK=1
}

policy_repo_allowlisted() { # <name>...
  local name
  for name in "$@"; do
    [ -n "$name" ] || continue
    if printf '%s\n' "$POLICY_ALLOWLIST" | grep -Fx -- "$name" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

# glob_matches <path> <glob>. Bash case is the shell's own glob semantics, so a
# `*` spans a path separator exactly as the policy's bare globs were written.
# A leading `**/` also matches a root-level occurrence, and a glob with no
# separator also matches a basename at any depth, which is the safe direction:
# an unmatched sensitive path would be the dangerous one.
glob_matches() {
  local path=$1 glob=$2 stripped base
  # Reject real traversal segments only: a legal filename such as `a..b.ts`
  # still reaches the globs, while `../x`, `x/../y` and `x/..` never do.
  case "$path" in
    ''|..|../*|*/../*|*/..) return 1 ;;
  esac
  # The policy's globs are data, so every case pattern below is deliberately an
  # unquoted expansion: quoting it would match the literal glob text instead.
  # shellcheck disable=SC2254
  case "$glob" in
    *'**/'*)
      case "$path" in $glob) return 0 ;; esac
      stripped=${glob//\*\*\//}
      case "$path" in $stripped) return 0 ;; esac
      case "$path" in */$stripped) return 0 ;; esac
      ;;
    */*)
      case "$path" in $glob) return 0 ;; esac
      ;;
    *)
      case "$path" in $glob) return 0 ;; esac
      base=${path##*/}
      case "$base" in $glob) return 0 ;; esac
      ;;
  esac
  return 1
}

# diff_sensitive_matches <newline-separated paths>: print every path the policy's
# sensitive globs or the built-in ground match. A leading `**/` also matches a
# root-level occurrence, and a glob with no separator also matches a basename at
# any depth, which is the safe direction: an unmatched sensitive path would be
# the dangerous one.
diff_sensitive_matches() { # <newline-separated paths>
  local path glob
  [ -n "${1:-}" ] || return 0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    while IFS= read -r glob; do
      [ -n "$glob" ] || continue
      if glob_matches "$path" "$glob"; then
        printf '%s\n' "$path"
        break
      fi
    done <<GLOBS
$POLICY_GLOBS
$BUILTIN_SENSITIVE_GLOBS
GLOBS
  done <<PATHS
$1
PATHS
  return 0
}

# package_json_raw <path> <ref>: the raw file content through the provider's
# own API, or empty when the provider cannot read it.
package_json_raw() { # <path> <ref>
  local path=$1 ref=$2
  case "$PR_PROVIDER" in
    github)
      fm_run_timed "$FM_PR_GREEN_RETURN_CMD_TIMEOUT" gh api \
        -H 'Accept: application/vnd.github.raw' \
        "repos/$PR_OWNER/$PR_REPO/contents/$path?ref=$ref" 2>/dev/null
      ;;
    forgejo)
      tea_read "/repos/$PR_PATH/raw/$path?ref=$ref"
      ;;
    gitlab)
      fm_run_timed "$FM_PR_GREEN_RETURN_CMD_TIMEOUT" glab api \
        "projects/$(gitlab_project_ref)/repository/files/$(printf '%s' "$path" | jq -sRr @uri)/raw?ref=$ref" 2>/dev/null
      ;;
  esac
}

# package_json_scripts_hold <matched paths>: the policy's package.json glob
# applies only to its scripts block, so a matched package.json is sensitive
# only when the scripts object differs between the base and the head. Prints the
# hold reason, or nothing when every matched package.json left its scripts
# untouched. Anything unreadable or beyond the bounded check holds.
package_json_scripts_hold() { # <matched paths>
  local path count=0 base head base_scripts head_scripts
  local package_jsons=()
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case ${path##*/} in
      package.json)
        package_jsons+=("$path")
        count=$((count + 1))
        if [ "$count" -gt 6 ]; then
          printf 'package.json matches exceed the bounded scripts check\n'
          return 0
        fi
        ;;
      pnpm-lock.yaml|package-lock.json|yarn.lock)
        # The policy's lockfile globs apply only on conflict, and this scan only
        # reaches a mergeable PR, so that condition is provably false here.
        continue
        ;;
      *)
        printf '%s\n' "$path"
        return 0
        ;;
    esac
  done <<PATHS
$1
PATHS
  [ "$count" -gt 0 ] || return 0
  for path in "${package_jsons[@]}"; do
    base=$(package_json_raw "$path" "$PR_BASE_SHA") || base=
    head=$(package_json_raw "$path" "$PR_HEAD") || head=
    if [ -n "$base" ] && [ -n "$head" ] \
      && base_scripts=$(printf '%s' "$base" | jq -S -c '.scripts // {}' 2>/dev/null) \
      && head_scripts=$(printf '%s' "$head" | jq -S -c '.scripts // {}' 2>/dev/null) \
      && [ "$base_scripts" = "$head_scripts" ]; then
      continue
    fi
    printf 'package.json scripts changed or unreadable (%s)\n' "$path"
    return 0
  done
  printf '\n'
}

# ---------------------------------------------------------------- gate -------

# FIVE_LENS_COMMENT_TITLE: the exact comment title the captain's merge policy
# designates as the five-lens evidence on a no-mistakes PR. A comment with any
# other title does not count.
FIVE_LENS_COMMENT_TITLE='Findings and fixes from 5-lenses-review'

# names_open_finding <text>: the open-finding wording the gate check treats as
# a stop, shared by the table rows and the per-lens result lines. The header's
# EDGE SEMANTICS owns the accepted clean forms and the negation and count rules.
names_open_finding() {
  printf '%s\n' "$1" \
    | grep -Eiq 'nicht[ -]?clean|not[[:space:]]+clean|findings?[[:space:]]*:[[:space:]]*[1-9][0-9]*' \
    || printf '%s\n' "$1" | grep -Eiwq 'majors?|must-?fix|should-?fix|hold|rework|leaks?' \
    || printf '%s\n' "$1" | awk '
      {
        line = tolower($0)
        gsub(/[,;.!?:]/, " __clause__ ", line)
        count = split(line, words, /[^a-z0-9_]+/)
        for (i = 1; i <= count; i++) {
          qualifier = words[i + 2]
          if (qualifier == "__clause__") qualifier = words[i + 3]
          if (words[i] ~ /^[1-9][0-9]*$/ \
            && (words[i + 1] == "remain" || words[i + 1] == "remains" \
              || words[i + 1] == "remaining" || words[i + 1] == "left" \
              || words[i + 1] == "unresolved" || words[i + 1] == "outstanding" \
              || ((words[i + 1] == "finding" || words[i + 1] == "findings") \
                && qualifier != "fixed" && qualifier != "closed" \
                && qualifier != "resolved" && qualifier != "behoben"))) {
            found = 1
            exit
          }
          if (words[i] != "open" && words[i] != "offen" && words[i] != "offene" \
            && words[i] != "offenen" && words[i] != "offener" \
            && words[i] != "offenes") continue
          negated = 0
          for (j = i - 1; j >= 1 && j >= i - 4; j--) {
            word = words[j]
            if (word == "__clause__") break
            if (word == "no" || word == "not" || word == "without" || word == "zero" \
              || word == "0" || word ~ /^kein/) { negated = 1; break }
            if (word ~ /^[0-9]+$/) break
            if (word != "finding" && word != "findings" && word != "remain" \
              && word != "remains" && word != "bleibt" && word != "bleiben" \
              && word != "is" && word != "are" && word != "ist" && word != "sind" \
              && word != "left" && word != "any" && word != "blocker" \
              && word != "blockers") break
          }
          if (!negated) { found = 1; exit }
        }
      }
      END { exit !found }'
}

# gate_section <body>: the five-lens block of the body - the lines under a
# heading naming the gate - or empty when the body carries no such block.
gate_section() {
  printf '%s\n' "$1" | awk '
    /^#+[ \t]/ {
      line = tolower($0)
      if (inblock) {
        if (length($1) <= level) { exit }
        next
      }
      if (line ~ /five[-_ ]?lens/ || line ~ /(fuenf|fünf)[-_ ]?linsen/) {
        inblock = 1
        level = length($1)
      }
      next
    }
    inblock { print }
  '
}

# gate_block_present <body>: whether the body carries a five-lens gate block at
# all, regardless of what the block reports. A direct-PR body that owns its
# gate is never second-guessed by the designated comment.
gate_block_present() {
  [ -n "$(gate_section "$1")" ]
}

# gate_section_clean <section>: hard stop 1's classification of one five-lens
# block. The gate accepts `Result: clean`, a table in
# which every data row ran and its result cells prove no finding is open, or a
# per-lens result for every lens that positively names a clean result; fewer
# than five lens results, a row naming an open finding, a non-numeric result
# cell whose leading counts do not cover the findings, an unclassifiable row, or
# a lens result in any other wording trips the stop. A no-mistakes task's gate
# comment is classified as one such block, without a heading.
gate_section_clean() {
  local section=$1 clean table_rows result_lines prose_ok
  local ran findings fixed total open findings_num fixed_num
  [ -n "$section" ] || return 1
  clean=$(printf '%s\n' "$section" | sed 's/[*_`]//g' \
    | grep -Eic '^[[:space:]>-]*result:[[:space:]]*clean[[:space:]]*$' || true)
  [ "${clean:-0}" -gt 0 ] && return 0

  # Every result line is checked for open-finding wording before any table or
  # prose verdict, so a clean-looking table cannot hide one.
  result_lines=$(printf '%s\n' "$section" | sed 's/[*_`]//g' \
    | grep -Ei '(result|verdikt|ergebnis)[[:space:]]*:.*[^[:space:]]' || true)
  if [ -n "$result_lines" ] && names_open_finding "$result_lines"; then
    return 1
  fi

  # Table variant: every data row is classified, never dropped. A row passes
  # only when it ran and its result cells show no open finding; a non-numeric
  # result cell is accepted only when both cells lead with counts that cover the
  # findings. An unclassifiable row holds.
  table_rows=$(printf '%s\n' "$section" | awk -F'|' '
    NF >= 5 {
      lens = $2; ran = $3; findings = $4; fixed = $5
      gsub(/^[ \t]+|[ \t]+$/, "", lens); gsub(/^[ \t]+|[ \t]+$/, "", ran)
      gsub(/^[ \t]+|[ \t]+$/, "", findings); gsub(/^[ \t]+|[ \t]+$/, "", fixed)
      if (lens == "" || tolower(lens) == "lens" || lens ~ /^-+$/) next
      gsub(/\t/, " ", ran); gsub(/\t/, " ", findings); gsub(/\t/, " ", fixed)
      print ran "\t" findings "\t" fixed
    }
  ')
  if [ -n "$table_rows" ]; then
    total=0
    open=0
    while IFS=$'\t' read -r ran findings fixed; do
      total=$((total + 1))
      case "$ran" in
        [yY][eE][sS]|[jJ][aA]|[tT][rR][uU][eE]) ;;
        *) open=1; continue ;;
      esac
      if names_open_finding "$findings $fixed"; then
        open=1
        continue
      fi
      case "$findings" in
        [0-9]*) findings_num=${findings%%[!0-9]*} ;;
        *) findings_num= ;;
      esac
      case "$fixed" in
        [0-9]*) fixed_num=${fixed%%[!0-9]*} ;;
        *) fixed_num= ;;
      esac
      if [ -z "$findings_num" ] || [ -z "$fixed_num" ] \
        || [ "$fixed_num" -lt "$findings_num" ]; then
        open=1
      fi
    done < <(printf '%s\n' "$table_rows")
    if [ "$total" -ge 5 ] && [ "$open" -eq 0 ]; then return 0; fi
    return 1
  fi

  # Per-lens prose variant: at least five lens result entries, each positively
  # naming a clean result (`clean`, `passed`/`pass`, or a `kein`/`no blocker`
  # entry). The open-finding wording was already refused above.
  [ -n "$result_lines" ] || return 1
  prose_ok=$(printf '%s\n' "$result_lines" | tr '[:upper:]' '[:lower:]' | awk '
    {
      if (match($0, /(result|verdikt|ergebnis)[ \t]*:/)) {
        value = substr($0, RSTART + RLENGTH)
      } else {
        value = $0
      }
      gsub(/[ \t"_-]/, "", value)
      sub(/[.!?,;:]+$/, "", value)
      if (value == "clean" || value == "passed" || value == "pass" \
        || value == "keinblocker" || value == "keinblockers" \
        || value == "keineblocker" || value == "keineblockers" \
        || value == "noblocker" || value == "noblockers") {
        accepted++
      } else {
        unlisted++
      }
    }
    END { if (accepted >= 5 && unlisted == 0) print "1" }
  ')
  [ -n "$prose_ok" ]
}

# gate_clean <body>: hard stop 1 for a PR body. A body without a five-lens
# block is never clean, however clean its lines would look on their own.
gate_clean() {
  local section
  section=$(gate_section "$1")
  [ -n "$section" ] || return 1
  gate_section_clean "$section"
}

# ---------------------------------------------------------------- checks ----

# check_name_waived <name>: the policy waives exactly the Coolify `deploy /
# deploy` preview poller as known-non-blocking. Spacing and case are normalized
# and the forge's trailing event suffix is dropped, so Forgejo's context form
# `deploy / deploy (pull_request)` is the same check.
check_name_waived() { # <name>
  local name
  name=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' \
    | sed 's/([^()]*)[[:space:]]*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]\{1,\}/ /g')
  [ "$name" = "$WAIVED_CHECK_NAME" ]
}

# classify_check_lines: read `<name>\t<class>` lines (class pass|fail|pending)
# and print the aggregate green|none|red|pending|unreadable. A failing waived
# preview does not fail the aggregate by itself; every other failing check does.
classify_check_lines() {
  local name class total=0 fail=0 pending=0 unknown=0
  while IFS=$'\t' read -r name class; do
    [ -n "$class" ] || continue
    total=$((total + 1))
    case "$class" in
      pass) ;;
      pending) pending=1 ;;
      fail)
        if ! check_name_waived "$name"; then fail=1; fi
        ;;
      *) unknown=1 ;;
    esac
  done
  if [ "$total" -eq 0 ]; then
    printf 'none\n'
    return 0
  fi
  if [ "$unknown" -eq 1 ]; then
    printf 'unreadable\n'
    return 0
  fi
  if [ "$fail" -eq 1 ]; then
    printf 'red\n'
    return 0
  fi
  if [ "$pending" -eq 1 ]; then
    printf 'pending\n'
    return 0
  fi
  printf 'green\n'
}

# ------------------------------------------------------------- providers ----

PR_URL=
PR_HOST=
PR_PATH=
PR_NUMBER=
PR_OWNER=
PR_REPO=

# Read globals, set by the provider readers.
PR_STATE=
PR_DRAFT=0
PR_MERGEABLE=unknown
PR_HEAD=
PR_BASE_SHA=
PR_AUTHOR=
PR_BODY=
PR_FIVE_LENS_COMMENT=
PR_HEAD_TIME=
PR_CHECKS=
PR_MERGE_PATH_READY=1
PR_VERDICT=absent
PR_VERDICT_TIME=
PR_FILES=
PR_FILES_READ=0
OP_LOGIN=
OP_LOGIN_READ=0

provider_unreadable() {
  PR_STATE=unreadable
  PR_CHECKS=
  PR_VERDICT=absent
  PR_FILES=
  PR_FILES_READ=0
  PR_HEAD_TIME=
}

gh_read() {
  local json fields line checks
  json=$(fm_run_timed "$FM_PR_GREEN_RETURN_CMD_TIMEOUT" gh pr view "$PR_URL" \
    --json state,isDraft,mergeable,headRefOid,baseRefOid,author,body,commits,statusCheckRollup 2>/dev/null) || {
    provider_unreadable
    return 0
  }
  if ! fields=$(printf '%s' "$json" | jq -r '
      . as $pr
      | if ($pr | type) == "object" then
          "state=" + (($pr.state // "") | tostring),
          "draft=" + (($pr.isDraft // false) | tostring),
          "mergeable=" + (($pr.mergeable // "") | tostring),
          "head=" + (($pr.headRefOid // "") | tostring),
          "base=" + (($pr.baseRefOid // "") | tostring),
          "author=" + (($pr.author.login // "") | tostring),
          "head_time=" + (([$pr.commits[]? | select(.oid == ($pr.headRefOid // ""))] | last | .committedDate) // "")
        else error("pull request payload is not an object") end' 2>/dev/null); then
    provider_unreadable
    return 0
  fi
  PR_STATE=; PR_DRAFT=0; PR_MERGEABLE=unknown; PR_HEAD=; PR_AUTHOR=; PR_HEAD_TIME=; PR_BASE_SHA=
  while IFS= read -r line; do
    case "$line" in
      state=*)
        case "${line#state=}" in
          OPEN) PR_STATE=open ;;
          MERGED) PR_STATE=merged ;;
          CLOSED) PR_STATE=closed ;;
          *) PR_STATE=unreadable ;;
        esac
        ;;
      draft=*) PR_DRAFT=${line#draft=} ;;
      mergeable=*)
        case "${line#mergeable=}" in
          MERGEABLE) PR_MERGEABLE=true ;;
          CONFLICTING) PR_MERGEABLE=false ;;
          *) PR_MERGEABLE=unknown ;;
        esac
        ;;
      head=*) PR_HEAD=${line#head=} ;;
      base=*) PR_BASE_SHA=${line#base=} ;;
      author=*) PR_AUTHOR=${line#author=} ;;
      head_time=*) PR_HEAD_TIME=${line#head_time=} ;;
    esac
  done <<FIELDS
$fields
FIELDS
  if [ "$PR_STATE" = open ] && ! fm_pr_head_valid "$PR_HEAD"; then
    provider_unreadable
    return 0
  fi
  PR_BODY=$(printf '%s' "$json" | jq -r '.body // ""' 2>/dev/null) || PR_BODY=
  if checks=$(printf '%s' "$json" | jq -r '
      def cls:
        if .__typename == "CheckRun" then
          if .status != "COMPLETED" then "pending"
          elif (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED") then "pass"
          elif (.conclusion == "FAILURE" or .conclusion == "CANCELLED" or .conclusion == "TIMED_OUT" or .conclusion == "ACTION_REQUIRED" or .conclusion == "STARTUP_FAILURE") then "fail"
          else "pending" end
        elif .state == "SUCCESS" then "pass"
        elif (.state == "PENDING" or .state == "EXPECTED") then "pending"
        elif (.state == "FAILURE" or .state == "ERROR") then "fail"
        else "pending" end;
      .statusCheckRollup[]?
      | [((.name // .context // "") | tostring), cls] | @tsv' 2>/dev/null); then
    PR_CHECKS=$(printf '%s\n' "$checks" | classify_check_lines)
  else
    PR_CHECKS=unreadable
  fi
}

gh_verdict_read() {
  local comments parsed
  comments=$(fm_run_timed "$FM_PR_GREEN_RETURN_CMD_TIMEOUT" gh api \
    "repos/$PR_OWNER/$PR_REPO/issues/$PR_NUMBER/comments" --paginate --slurp 2>/dev/null) || {
    PR_VERDICT=unreadable
    return 0
  }
  parsed=$(printf '%s' "$comments" | jq -r '
    [ .[] | .[]
      | select(((.user.login // "") | test("^seibert-pr-agent(\\[bot\\])?$"; "i")))
      | select(((.body // "") | test("(?m)^\\*\\*Verdict:\\*\\*")))
      | { created: (.created_at // ""), updated: ((.updated_at // .created_at) // ""), body: (.body // "") } ]
    | sort_by(.created) | last
    | if . == null then "absent"
      else
        (.updated) as $u
        | (.body | [scan("(?m)^\\*\\*Verdict:\\*\\*[ \t]*([^\n\r]*)")][0][0] | sub("[ \t]+$"; "")) as $v
        | if $v == "Good to merge" then "positive\t" + $u else "negative\t" + $u end
      end' 2>/dev/null) || parsed=unreadable
  case "$parsed" in
    positive*) PR_VERDICT=positive; PR_VERDICT_TIME=${parsed#positive*$'\t'} ;;
    negative*) PR_VERDICT=negative; PR_VERDICT_TIME=${parsed#negative*$'\t'} ;;
    unreadable) PR_VERDICT=unreadable ;;
    *) PR_VERDICT=absent ;;
  esac
}

# five_lens_comment_pick <comments-json> <author>: the newest comment whose
# first non-empty line is exactly the designated five-lens title and whose
# author is the authenticated operator, printed as its body; empty when no
# comment matches or the payload cannot be parsed. The GitHub `--paginate
# --slurp` payload is an array of comment pages, so one array level is
# flattened first.
five_lens_comment_pick() { # <comments-json> <author>
  printf '%s' "$1" | jq -r --arg title "$FIVE_LENS_COMMENT_TITLE" --arg author "$2" '
    [ .[] | if type == "array" then .[] else . end
      | select((.user.login // "") == $author)
      | select((.body // "") as $body
          | ($body | split("\n")
             | map(gsub("^[ \t\r]+|[ \t\r]+$"; ""))
             | map(select(length > 0))
             | .[0] // "") == $title)
      | { created: (.created_at // ""), body: (.body // "") } ]
    | sort_by(.created) | last
    | if . == null then "" else .body end' 2>/dev/null
}

gh_five_lens_comment_read() {
  local comments
  comments=$(fm_run_timed "$FM_PR_GREEN_RETURN_CMD_TIMEOUT" gh api \
    "repos/$PR_OWNER/$PR_REPO/issues/$PR_NUMBER/comments" --paginate --slurp 2>/dev/null) || {
    PR_FIVE_LENS_COMMENT=
    return 0
  }
  PR_FIVE_LENS_COMMENT=$(five_lens_comment_pick "$comments" "$OP_LOGIN")
}

gh_operator_login() {
  [ "$OP_LOGIN_READ" = 0 ] || return 0
  OP_LOGIN_READ=1
  OP_LOGIN=$(fm_run_timed "$FM_PR_GREEN_RETURN_CMD_TIMEOUT" gh api user --jq .login 2>/dev/null) || OP_LOGIN=
}

gh_files_read() {
  PR_FILES_READ=0
  PR_FILES=$(fm_run_timed "$FM_PR_GREEN_RETURN_CMD_TIMEOUT" gh pr diff "$PR_URL" --name-only 2>/dev/null) || { PR_FILES=; return 0; }
  PR_FILES_READ=1
}

tea_read() { # <api-path>
  fm_run_timed "$FM_PR_GREEN_RETURN_CMD_TIMEOUT" tea api "$1" 2>/dev/null
}

forgejo_read() {
  local json fields merged=false line commit
  json=$(tea_read "/repos/$PR_PATH/pulls/$PR_NUMBER") || {
    provider_unreadable
    return 0
  }
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" then
        "state=" + ((.state // "") | tostring),
        "merged=" + ((.merged // false) | tostring),
        "mergeable=" + ((.mergeable // false) | tostring),
        "head=" + ((.head.sha // "") | tostring),
        "base=" + ((.base.sha // "") | tostring),
        "author=" + ((.user.login // "") | tostring)
      else error("pull request payload is not an object") end' 2>/dev/null); then
    provider_unreadable
    return 0
  fi
  PR_STATE=; PR_MERGEABLE=unknown; PR_HEAD=; PR_AUTHOR=; PR_BASE_SHA=
  while IFS= read -r line; do
    case "$line" in
      state=*) PR_STATE=${line#state=} ;;
      merged=*) merged=${line#merged=} ;;
      mergeable=*)
        case "${line#mergeable=}" in
          true) PR_MERGEABLE=true ;;
          false) PR_MERGEABLE=false ;;
          *) PR_MERGEABLE=unknown ;;
        esac
        ;;
      head=*) PR_HEAD=${line#head=} ;;
      base=*) PR_BASE_SHA=${line#base=} ;;
      author=*) PR_AUTHOR=${line#author=} ;;
    esac
  done <<FIELDS
$fields
FIELDS
  case "$PR_STATE" in
    open) ;;
    closed)
      if [ "$merged" = true ]; then PR_STATE=merged; else PR_STATE=closed; fi
      ;;
    *) PR_STATE=unreadable ;;
  esac
  if [ "$PR_STATE" = open ] && ! fm_pr_head_valid "$PR_HEAD"; then
    provider_unreadable
    return 0
  fi
  PR_BODY=$(printf '%s' "$json" | jq -r '.body // ""' 2>/dev/null) || PR_BODY=
  if [ "$PR_STATE" = open ]; then
    commit=$(tea_read "/repos/$PR_PATH/git/commits/$PR_HEAD") || commit=
    PR_HEAD_TIME=$(printf '%s' "$commit" | jq -r '.created // ""' 2>/dev/null) || PR_HEAD_TIME=
  fi
}

forgejo_checks_read() {
  local json state total statuses
  json=$(tea_read "/repos/$PR_PATH/commits/$PR_HEAD/status") || { PR_CHECKS=unreadable; return 0; }
  state=$(printf '%s' "$json" | jq -r '.state // ""' 2>/dev/null) || { PR_CHECKS=unreadable; return 0; }
  total=$(printf '%s' "$json" | jq -r '.total_count // 0' 2>/dev/null) || { PR_CHECKS=unreadable; return 0; }
  case "$total" in
    ''|*[!0-9]*) PR_CHECKS=unreadable; return 0 ;;
  esac
  case "$state" in
    success)
      if [ "$total" -gt 0 ]; then PR_CHECKS=green; else PR_CHECKS=none; fi
      ;;
    failure|error|warning)
      if statuses=$(printf '%s' "$json" | jq -r '
          if (.statuses | type) == "array" then
            .statuses[]?
            | [((.context // "") | tostring),
               ((.status // "") as $s
                | if $s == "success" or $s == "skipped" then "pass"
                  elif $s == "pending" then "pending"
                  elif $s == "failure" or $s == "error" or $s == "warning" then "fail"
                  else "unknown" end)]
            | @tsv
          else error("combined status carries no statuses list") end' 2>/dev/null); then
        PR_CHECKS=$(printf '%s\n' "$statuses" | classify_check_lines)
        [ "$PR_CHECKS" != none ] || PR_CHECKS=red
        [ "$PR_CHECKS" != green ] || PR_MERGE_PATH_READY=0
      else
        PR_CHECKS=unreadable
      fi
      ;;
    pending) PR_CHECKS=pending ;;
    skipped) PR_CHECKS=none ;;
    '') PR_CHECKS=none ;;
    *) PR_CHECKS=unreadable ;;
  esac
}

forgejo_verdict_read() {
  local comments parsed
  comments=$(tea_read "/repos/$PR_PATH/issues/$PR_NUMBER/comments") || {
    PR_VERDICT=unreadable
    return 0
  }
  parsed=$(printf '%s' "$comments" | jq -r '
    [ .[] | select((.body // "") | contains("<!-- crabd:tracking -->"))
      | { updated: (.updated_at // ""), body: (.body // "") } ]
    | sort_by(.updated) | last
    | if . == null then "absent"
      else
        (.body | split("\n")[0] | gsub("<!--[^>]*-->"; "") | sub("[ \\t]+$"; "")) as $line
        | if ($line | test("^Reviewed this pull request")) then
            ($line | [scan("\\*\\*([^*]+)\\*\\*")]) as $spans
            | if ($spans | length) == 0 then "absent"
              else
                ($spans[0][0]) as $span
                | if ($span == "Good to merge (LGTM)." or $span == "Nits found.")
                  then "positive\t" + .updated
                  else "negative\t" + .updated end
              end
          else "absent" end
      end' 2>/dev/null) || parsed=unreadable
  case "$parsed" in
    positive*) PR_VERDICT=positive; PR_VERDICT_TIME=${parsed#positive*$'\t'} ;;
    negative*) PR_VERDICT=negative; PR_VERDICT_TIME=${parsed#negative*$'\t'} ;;
    unreadable) PR_VERDICT=unreadable ;;
    *) PR_VERDICT=absent ;;
  esac
}

# forgejo_five_lens_comment_read: accumulate the comment pages, deduplicated by
# id, and read the designated five-lens comment from them. A page that adds no
# new comment id also ends the list: a Forgejo endpoint that ignores
# `limit`/`page` returns the same full list on every request, so the short-page
# test alone would exhaust the page cap and read no comment at all (hard stop 1).
forgejo_five_lens_comment_read() {
  local page=1 page_json page_count comments='[]' merged merged_count comment_count=0
  while [ "$page" -le "$API_PAGE_MAX" ]; do
    page_json=$(tea_read "/repos/$PR_PATH/issues/$PR_NUMBER/comments?limit=$API_PAGE_LIMIT&page=$page") || {
      PR_FIVE_LENS_COMMENT=
      return 0
    }
    page_count=$(printf '%s' "$page_json" | jq -r 'if type == "array" then length else error("not a comment array") end' 2>/dev/null) || {
      PR_FIVE_LENS_COMMENT=
      return 0
    }
    merged=$(printf '%s\n%s\n' "$comments" "$page_json" | jq -cs '.[0] + .[1] | unique_by(.id)' 2>/dev/null) || {
      PR_FIVE_LENS_COMMENT=
      return 0
    }
    merged_count=$(printf '%s' "$merged" | jq -r 'length' 2>/dev/null) || {
      PR_FIVE_LENS_COMMENT=
      return 0
    }
    if [ "$page_count" -lt "$API_PAGE_LIMIT" ] || [ "$merged_count" -eq "$comment_count" ]; then
      PR_FIVE_LENS_COMMENT=$(five_lens_comment_pick "$merged" "$OP_LOGIN")
      return 0
    fi
    comments=$merged
    comment_count=$merged_count
    page=$((page + 1))
  done
  PR_FIVE_LENS_COMMENT=
}

forgejo_operator_login() {
  [ "$OP_LOGIN_READ" = 0 ] || return 0
  OP_LOGIN_READ=1
  local user
  user=$(tea_read /user) || user=
  OP_LOGIN=$(printf '%s' "$user" | jq -r '.login // ""' 2>/dev/null) || OP_LOGIN=
}

forgejo_files_read() {
  local page=1 page_json page_files count
  PR_FILES_READ=0
  PR_FILES=
  while [ "$page" -le "$API_PAGE_MAX" ]; do
    page_json=$(tea_read "/repos/$PR_PATH/pulls/$PR_NUMBER/files?limit=$API_PAGE_LIMIT&page=$page") || { PR_FILES=; return 0; }
    count=$(printf '%s' "$page_json" | jq -r 'if type == "array" then length else error("not a file array") end' 2>/dev/null) || { PR_FILES=; return 0; }
    page_files=$(printf '%s' "$page_json" | jq -r '
      if type == "array" then
        .[]? | (.filename // empty), (select((.previous_filename // "") != "") | .previous_filename)
      else error("not a file array") end' 2>/dev/null) || { PR_FILES=; return 0; }
    [ -z "$page_files" ] || PR_FILES="${PR_FILES}${PR_FILES:+$'\n'}$page_files"
    if [ "$count" -lt "$API_PAGE_LIMIT" ]; then
      PR_FILES_READ=1
      return 0
    fi
    page=$((page + 1))
  done
  # Every page was full, so completeness cannot be proven: hold on hard stop 5.
  PR_FILES=
  return 0
}

gitlab_project_ref() {
  printf '%s' "$PR_PATH" | jq -sRr @uri 2>/dev/null
}

glab_read() {
  local json fields line detail='' conflicts=false discussions=false pipeline='' pipeline_sha='' commit project
  project="https://$PR_HOST/$PR_PATH"
  json=$(fm_run_timed "$FM_PR_GREEN_RETURN_CMD_TIMEOUT" env GITLAB_HOST="$PR_HOST" \
    glab mr view "$PR_NUMBER" -R "$project" -F json 2>/dev/null) || {
    provider_unreadable
    return 0
  }
  if ! fields=$(printf '%s' "$json" | jq -r '
      if type == "object" then
        "state=" + ((.state // "") | tostring),
        "draft=" + ((.draft // false) | tostring),
        "detail=" + ((.detailed_merge_status // "") | tostring),
        "conflicts=" + ((.has_conflicts // false) | tostring),
        "discussions=" + ((.blocking_discussions_resolved // false) | tostring),
        "head=" + ((.sha // "") | tostring),
        "base=" + ((.diff_refs.base_sha // "") | tostring),
        "author=" + ((.author.username // "") | tostring),
        "pipeline=" + ((.head_pipeline.status // "") | tostring),
        "pipeline_sha=" + ((.head_pipeline.sha // "") | tostring)
      else error("merge request payload is not an object") end' 2>/dev/null); then
    provider_unreadable
    return 0
  fi
  PR_STATE=; PR_DRAFT=0; PR_MERGEABLE=unknown; PR_HEAD=; PR_AUTHOR=; PR_CHECKS=; PR_BASE_SHA=
  while IFS= read -r line; do
    case "$line" in
      state=*)
        case "${line#state=}" in
          opened|locked) PR_STATE=open ;;
          merged) PR_STATE=merged ;;
          closed) PR_STATE=closed ;;
          *) PR_STATE=unreadable ;;
        esac
        ;;
      draft=*) PR_DRAFT=${line#draft=} ;;
      detail=*) detail=${line#detail=} ;;
      conflicts=*) conflicts=${line#conflicts=} ;;
      discussions=*) discussions=${line#discussions=} ;;
      head=*) PR_HEAD=${line#head=} ;;
      base=*) PR_BASE_SHA=${line#base=} ;;
      author=*) PR_AUTHOR=${line#author=} ;;
      pipeline=*) pipeline=${line#pipeline=} ;;
      pipeline_sha=*) pipeline_sha=${line#pipeline_sha=} ;;
    esac
  done <<FIELDS
$fields
FIELDS
  if [ "$PR_STATE" = open ] && ! fm_pr_head_valid "$PR_HEAD"; then
    provider_unreadable
    return 0
  fi
  PR_BODY=$(printf '%s' "$json" | jq -r '.description // ""' 2>/dev/null) || PR_BODY=
  if [ "$detail" = mergeable ] && [ "$conflicts" = false ] && [ "$discussions" = true ]; then
    PR_MERGEABLE=true
  elif [ -n "$detail" ]; then
    PR_MERGEABLE=false
  else
    PR_MERGEABLE=unknown
  fi
  case "$pipeline" in
    success)
      if [ "$pipeline_sha" = "$PR_HEAD" ]; then PR_CHECKS=green; else PR_CHECKS=unreadable; fi
      ;;
    failed|canceled|cancelled) PR_CHECKS=red ;;
    ''|skipped) PR_CHECKS=none ;;
    pending|running|created|waiting_for_resource|preparing|scheduled|manual) PR_CHECKS=pending ;;
    *) PR_CHECKS=unreadable ;;
  esac
  if [ "$PR_STATE" = open ]; then
    commit=$(fm_run_timed "$FM_PR_GREEN_RETURN_CMD_TIMEOUT" glab api \
      "projects/$(gitlab_project_ref)/repository/commits/$PR_HEAD" 2>/dev/null) || commit=
    PR_HEAD_TIME=$(printf '%s' "$commit" | jq -r '.committed_date // ""' 2>/dev/null) || PR_HEAD_TIME=
  fi
}

glab_operator_login() {
  [ "$OP_LOGIN_READ" = 0 ] || return 0
  OP_LOGIN_READ=1
  local user
  user=$(fm_run_timed "$FM_PR_GREEN_RETURN_CMD_TIMEOUT" glab api user 2>/dev/null) || user=
  OP_LOGIN=$(printf '%s' "$user" | jq -r '.username // ""' 2>/dev/null) || OP_LOGIN=
}

glab_files_read() {
  local changes overflow
  PR_FILES_READ=0
  changes=$(fm_run_timed "$FM_PR_GREEN_RETURN_CMD_TIMEOUT" glab api \
    "projects/$(gitlab_project_ref)/merge_requests/$PR_NUMBER/changes" 2>/dev/null) || { PR_FILES=; return 0; }
  overflow=$(printf '%s' "$changes" | jq -r 'if type == "object" then (.overflow // false) else "unreadable" end' 2>/dev/null) || { PR_FILES=; return 0; }
  case "$overflow" in
    false) ;;
    *) PR_FILES=; return 0 ;;
  esac
  PR_FILES=$(printf '%s' "$changes" | jq -r '
    if type == "object" and (.changes | type) == "array" then
      .changes[]? | (.new_path // empty), (select((.old_path // "") != "" and .old_path != .new_path) | .old_path)
    else error("missing changes") end' 2>/dev/null) || { PR_FILES=; return 0; }
  PR_FILES_READ=1
}

# ------------------------------------------------------------- evaluation ---

EV_CLASS=
EV_REASON=
EV_SINCE_HINT=

# evaluate_task <id> <meta>: read the live PR and classify it. Sets EV_CLASS
# to merged, closed, waiting, held, or due, and EV_REASON to the concrete
# reason; EV_SINCE_HINT carries the evidence-backed wait start for a due PR.
evaluate_task() {
  local id=$1 meta=$2 candidate owner_name gate_ok=0 gate_mode
  EV_CLASS=waiting
  EV_REASON=unreadable
  EV_SINCE_HINT=

  PR_PROVIDER=$FM_PR_META_PROVIDER
  PR_URL=$FM_PR_META_URL
  PR_HOST=$FM_PR_META_HOST
  PR_PATH=$FM_PR_META_PATH
  PR_NUMBER=$FM_PR_META_NUMBER
  PR_OWNER=${PR_PATH%%/*}
  PR_REPO=${PR_PATH#*/}
  PR_BODY=
  PR_FIVE_LENS_COMMENT=
  PR_FILES=
  PR_FILES_READ=0
  PR_HEAD_TIME=
  PR_BASE_SHA=
  PR_VERDICT=absent
  PR_VERDICT_TIME=
  PR_CHECKS=
  PR_MERGE_PATH_READY=1
  PR_STATE=
  PR_HEAD=
  PR_MERGEABLE=unknown
  PR_DRAFT=0
  OP_LOGIN=; OP_LOGIN_READ=0

  if [ "$POLICY_OK" != 1 ]; then
    EV_CLASS=held
    EV_REASON="hard-stop-7: the merge policy is missing or unparseable"
    return 0
  fi

  case "$PR_PROVIDER" in
    github) gh_read ;;
    forgejo) forgejo_read ;;
    gitlab) glab_read ;;
    *) provider_unreadable ;;
  esac

  case "$PR_STATE" in
    merged) EV_CLASS=merged; EV_REASON=merged; return 0 ;;
    closed) EV_CLASS=closed; EV_REASON=closed; return 0 ;;
    unreadable) EV_CLASS=waiting; EV_REASON='state-unreadable'; return 0 ;;
  esac
  if [ "$PR_DRAFT" = true ]; then
    EV_CLASS=waiting
    EV_REASON=draft
    return 0
  fi

  case "$PR_PROVIDER" in
    github) gh_operator_login ;;
    forgejo) forgejo_operator_login ;;
    gitlab) glab_operator_login ;;
  esac
  if [ -z "$OP_LOGIN" ]; then
    EV_CLASS=held
    EV_REASON="hard-stop-6: the authenticated operator could not be read"
    return 0
  fi
  if [ "$OP_LOGIN" != "$PR_AUTHOR" ]; then
    EV_CLASS=held
    EV_REASON="hard-stop-6: the pull request author is not the authenticated operator"
    return 0
  fi

  if [ "$PR_MERGEABLE" != true ]; then
    EV_CLASS=waiting
    EV_REASON="mergeable=${PR_MERGEABLE}"
    return 0
  fi

  if [ "$PR_PROVIDER" = forgejo ]; then
    forgejo_checks_read
  fi
  case "$PR_CHECKS" in
    green) ;;
    red) EV_CLASS=held; EV_REASON="hard-stop-3: CI is red"; return 0 ;;
    none) EV_CLASS=held; EV_REASON="hard-stop-4: the repository reports no CI checks"; return 0 ;;
    pending) EV_CLASS=waiting; EV_REASON='checks-pending'; return 0 ;;
    *) EV_CLASS=waiting; EV_REASON='checks-unreadable'; return 0 ;;
  esac

  # Hard stop 1 reads the gate from the PR body and, when the body carries no
  # gate block or the task is a no-mistakes one, from the designated comment
  # too: the pipeline opens a no-mistakes PR, so the operator's exact-titled
  # comment is its normal evidence. A clean read from either source passes; an
  # unreadable, untitled, or foreign-authored comment is never green. The
  # comment's head-SHA and CI-state naming duty stays with its author per the
  # merge policy: the scan reads the live head and live checks from the forge,
  # and a base-movement rebase moves the head content-equivalently, so parsing
  # the named head here would hold every rebased PR. This scan enforces the
  # title, the author, and the classified result.
  gate_mode=$(field_of "$meta" mode)
  if gate_clean "$PR_BODY"; then
    gate_ok=1
  elif [ "$gate_mode" = no-mistakes ] || ! gate_block_present "$PR_BODY"; then
    case "$PR_PROVIDER" in
      github) gh_five_lens_comment_read ;;
      forgejo) forgejo_five_lens_comment_read ;;
    esac
    gate_section_clean "$PR_FIVE_LENS_COMMENT" && gate_ok=1
  fi
  if [ "$gate_ok" != 1 ]; then
    EV_CLASS=held
    EV_REASON="hard-stop-1: the five-lens gate block is missing or reports an open finding"
    return 0
  fi

  # Item 2 is advisory in the policy's current wording: the merge is held only
  # when the verdict channel answers with something the captain must read
  # first. A verdict that never arrives is not a stop, and a forge the policy
  # defines no channel for has no second opinion that could arrive.
  case "$PR_PROVIDER" in
    github) gh_verdict_read ;;
    forgejo) forgejo_verdict_read ;;
  esac
  case "$PR_VERDICT" in
    negative)
      EV_CLASS=held
      EV_REASON="hard-stop-2: the review verdict asks for changes before merging"
      return 0
      ;;
    unreadable)
      EV_CLASS=held
      EV_REASON="hard-stop-2: the review verdict could not be read"
      return 0
      ;;
  esac

  case "$PR_PROVIDER" in
    github) gh_files_read ;;
    forgejo) forgejo_files_read ;;
    gitlab) glab_files_read ;;
  esac
  # Hard stop 5 fails closed: an unreadable changed-file list is no proof that
  # the diff stays off the policy's sensitive ground.
  if [ "$PR_FILES_READ" != 1 ]; then
    EV_CLASS=held
    EV_REASON="hard-stop-5: the changed-file list could not be read completely"
    return 0
  fi
  local sensitive_matches sensitive_reason
  sensitive_matches=$(diff_sensitive_matches "$PR_FILES")
  if [ -n "$sensitive_matches" ]; then
    sensitive_reason=$(package_json_scripts_hold "$sensitive_matches")
    if [ -n "$sensitive_reason" ]; then
      EV_CLASS=held
      EV_REASON="hard-stop-5: sensitive path $sensitive_reason"
      return 0
    fi
  fi

  candidate=$PR_REPO
  [ -n "$candidate" ] || candidate=${PR_PATH##*/}
  owner_name=$(field_of "$meta" project)
  [ -z "$owner_name" ] || owner_name=${owner_name##*/}
  if ! policy_repo_allowlisted "$candidate" "$owner_name"; then
    EV_CLASS=held
    EV_REASON="policy-ask: repo ${candidate:-unknown} is not in the autonomous allowlist"
    return 0
  fi

  # Only Forgejo (head_commit_id) and GitLab (--sha) can bind the merge to the
  # head this scan verified; the GitHub merge path has no head-binding option,
  # so an otherwise due GitHub PR is held rather than handed a mandate the
  # merge path cannot honor.
  if [ "$PR_PROVIDER" = github ]; then
    EV_CLASS=held
    EV_REASON="no-bound-merge: the GitHub merge path cannot bind the reviewed head"
    return 0
  fi
  if [ "$PR_PROVIDER" = forgejo ] && [ "$PR_MERGE_PATH_READY" != 1 ]; then
    EV_CLASS=held
    EV_REASON="no-bound-merge: the head is policy-clean, but the protected merge path refuses it because the preview check is red"
    return 0
  fi

  EV_CLASS=due
  EV_REASON=ready
  EV_SINCE_HINT=$(due_since_hint)
}

# due_since_hint: the earliest evidence-backed moment the PR can have held its
# current due state: the later of the head commit time and the fresh verdict.
due_since_hint() {
  local now head_epoch verdict_epoch best=0 value
  now=$(now_epoch)
  head_epoch=$(iso_to_epoch "$PR_HEAD_TIME" 2>/dev/null || true)
  verdict_epoch=$(iso_to_epoch "$PR_VERDICT_TIME" 2>/dev/null || true)
  for value in "$head_epoch" "$verdict_epoch"; do
    case "$value" in ''|*[!0-9]*) continue ;; esac
    [ "$value" -gt "$best" ] && best=$value
  done
  case "$best" in
    ''|*[!0-9]*|0) printf '%s\n' "$now"; return ;;
  esac
  if [ "$best" -gt "$now" ]; then best=$now; fi
  printf '%s\n' "$best"
}

# ---------------------------------------------------------------- records ---

REC_CLASS=
REC_REASON=
REC_SINCE=
REC_NOTIFIED=
REC_HEAD=

record_read() { # <id>
  local file="$RECORD_DIR/$1"
  REC_CLASS=; REC_REASON=; REC_SINCE=; REC_NOTIFIED=; REC_HEAD=
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  REC_CLASS=$(field_of "$file" class)
  REC_REASON=$(field_of "$file" reason)
  REC_SINCE=$(field_of "$file" since)
  REC_NOTIFIED=$(field_of "$file" notified)
  REC_HEAD=$(field_of "$file" head)
}

record_write() { # <id> <class> <reason> <since> <observed> <notified>
  local id=$1 tmp
  mkdir -p "$RECORD_DIR" 2>/dev/null || return 1
  [ -d "$RECORD_DIR" ] && [ ! -L "$RECORD_DIR" ] || return 1
  tmp=$(mktemp "$RECORD_DIR/.record.XXXXXX") || return 1
  {
    printf 'schema=fm-pr-green-return.v1\n'
    printf 'task=%s\n' "$id"
    printf 'provider=%s\n' "$PR_PROVIDER"
    printf 'url=%s\n' "$PR_URL"
    printf 'head=%s\n' "$PR_HEAD"
    printf 'class=%s\n' "$2"
    printf 'reason=%s\n' "$3"
    printf 'since=%s\n' "$4"
    printf 'observed=%s\n' "$5"
    printf 'notified=%s\n' "$6"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$RECORD_DIR/$id" || { rm -f -- "$tmp"; return 1; }
}

record_remove() { # <id>
  rm -f -- "$RECORD_DIR/$1" 2>/dev/null || true
}

queue_wake() { # <key> <payload>
  local key=$1 payload=$2
  fm_wake_append check "$key" "$payload" || return 2
  printf 'actionable: %s\n' "$payload"
}

wake_payload_due() {
  printf 'check: green-return %s due: PR %s head %s has been green and mergeable for %ss with no policy hold - merge it bound now: bin/fm-pr-merge.sh %s %s --expected-head %s\n' \
    "$1" "$PR_URL" "$PR_HEAD" "$2" "$1" "$PR_URL" "$PR_HEAD"
}

wake_payload_held() {
  printf 'check: green-return %s held: PR %s head %s %ss - %s; present to the captain, do not merge\n' \
    "$1" "$PR_URL" "$PR_HEAD" "$2" "$3"
}

label_for_reason() { # <reason>
  case "$1" in
    hard-stop-1:*) printf 'hard stop 1 (five-lens gate)\n' ;;
    hard-stop-2:*) printf 'hard stop 2 (review verdict)\n' ;;
    hard-stop-3:*) printf 'hard stop 3 (CI red)\n' ;;
    hard-stop-4:*) printf 'hard stop 4 (no CI checks)\n' ;;
    hard-stop-5:*) printf 'hard stop 5 (%s)\n' "${1#hard-stop-5: }" ;;
    hard-stop-6:*) printf 'hard stop 6 (not the operator PR)\n' ;;
    hard-stop-7:*) printf 'hard stop 7 (policy unreadable)\n' ;;
    policy-ask:*) printf 'the policy default ask (%s)\n' "${1#policy-ask: }" ;;
    no-bound-merge:*) printf 'no bound merge (%s)\n' "${1#no-bound-merge: }" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# ------------------------------------------------------------ scan / report --

# process_task <id> <meta> <now> <wait>: classify one task, keep its durable
# wait record, and queue exactly one check wake per (head, class, reason) once
# the wait has elapsed. Prints only the actionable lines for queued wakes.
process_task() {
  local id=$1 meta=$2 now=$3 wait=$4 since notified key payload age
  evaluate_task "$id" "$meta"
  case "$EV_CLASS" in
    merged|closed|waiting)
      record_remove "$id"
      return 0
      ;;
  esac

  record_read "$id"
  if [ "$EV_CLASS" = due ]; then
    since=$EV_SINCE_HINT
    case "$since" in ''|*[!0-9]*) since=$now ;; esac
    if [ "$REC_CLASS" = due ] && [ "$REC_HEAD" = "$PR_HEAD" ]; then
      case "$REC_SINCE" in
        ''|*[!0-9]*) ;;
        *) [ "$REC_SINCE" -lt "$since" ] && since=$REC_SINCE ;;
      esac
    fi
  else
    if [ "$REC_CLASS" = held ] && [ "$REC_HEAD" = "$PR_HEAD" ] && [ "$REC_REASON" = "$EV_REASON" ]; then
      since=$REC_SINCE
      case "$since" in ''|*[!0-9]*) since=$now ;; esac
    else
      since=$now
    fi
  fi
  [ "$since" -le "$now" ] || since=$now

  notified=
  if [ "$REC_HEAD" = "$PR_HEAD" ] && [ "$REC_CLASS" = "$EV_CLASS" ] && [ "$REC_REASON" = "$EV_REASON" ]; then
    notified=$REC_NOTIFIED
  fi

  age=$((now - since))
  if [ "$age" -ge "$wait" ] && [ -z "$notified" ]; then
    key="pr-green-return:$id"
    if [ "$EV_CLASS" = due ]; then
      payload=$(wake_payload_due "$id" "$age")
      if queue_wake "$key" "$payload"; then
        notified="due:$PR_HEAD"
      fi
    else
      payload=$(wake_payload_held "$id" "$age" "$(label_for_reason "$EV_REASON")")
      if queue_wake "$key" "$payload"; then
        notified="held:$PR_HEAD:$EV_REASON"
      fi
    fi
  fi

  record_write "$id" "$EV_CLASS" "$EV_REASON" "$since" "$now" "$notified"
}

# list_candidates: every task meta that records a parseable pr= line, sorted for
# a stable order. Secondmate metas are routes, not work, and are skipped.
list_candidates() {
  local meta id
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fm_pr_task_id_valid "$id" || continue
    [ "$(field_of "$meta" kind)" != secondmate ] || continue
    fm_pr_metadata_identity_parse "$meta" || continue
    printf '%s\n' "$id"
  done | LC_ALL=C sort
}

# record_gc: a record whose task no longer exists (or no longer records a PR)
# is spent; teardown owns the task record, this scan owns its own.
record_gc() {
  local rec id meta
  [ -d "$RECORD_DIR" ] && [ ! -L "$RECORD_DIR" ] || return 0
  for rec in "$RECORD_DIR"/*; do
    [ -f "$rec" ] && [ ! -L "$rec" ] || continue
    id=$(basename "$rec")
    meta="$STATE/$id.meta"
    if [ ! -f "$meta" ] || [ -L "$meta" ] || ! fm_pr_metadata_identity_parse "$meta"; then
      rm -f -- "$rec" 2>/dev/null || true
    fi
  done
}

scan_marker_write() { # <cursor>
  local cursor=$1 tmp
  tmp=$(mktemp "$STATE/.last-pr-green-return.XXXXXX") || return 1
  {
    printf 'epoch=%s\n' "$(now_epoch)"
    printf 'cursor=%s\n' "$cursor"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$SCAN_MARKER" || { rm -f -- "$tmp"; return 1; }
}

scan_locked() {
  local now wait cursor id meta last='' deadline ordered candidates
  now=$(now_epoch)
  wait_secs || return $?
  wait=$WAIT_SECS_RESOLVED
  policy_load
  record_gc

  cursor=$(field_of "$SCAN_MARKER" cursor 2>/dev/null || true)
  deadline=$((now + FM_PR_GREEN_RETURN_BUDGET_SECS))
  candidates=$(list_candidates)
  ordered=$(printf '%s\n' "$candidates" | awk -v cursor="$cursor" '
    { rows[NR] = $0 }
    END {
      found = 0
      for (i = 1; i <= NR; i++) {
        if (cursor != "" && rows[i] == cursor) { found = i; break }
      }
      for (i = found + 1; i <= NR; i++) print rows[i]
      for (i = 1; i <= found; i++) print rows[i]
    }
  ' 2>/dev/null || printf '%s\n' "$candidates")

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    now=$(now_epoch)
    if [ "$now" -ge "$deadline" ]; then
      break
    fi
    meta="$STATE/$id.meta"
    fm_pr_metadata_identity_parse "$meta" || continue
    # Persist this candidate as the rotation start before it is attempted, so a
    # scan killed inside a slow candidate resumes after it instead of starving
    # every later candidate behind the same slow one.
    scan_marker_write "$id" || return 1
    process_task "$id" "$meta" "$now" "$wait" || true
    last=$id
  done <<IDS
$ordered
IDS

  scan_marker_write "${last:-$cursor}" || return 1
  return 0
}

scan_cadence_due() {
  local now m age
  [ "$FM_PR_GREEN_RETURN_FORCE" = 1 ] && return 0
  [ -e "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ] || return 0
  now=$(now_epoch)
  m=$(file_mtime "$SCAN_MARKER" 2>/dev/null || true)
  case "$m" in ''|*[!0-9]*) return 0 ;; esac
  # A clock that moved backwards is not a reason to scan: treat it as age 0,
  # mirroring the other bounded-cadence markers in this repo.
  [ "$now" -lt "$m" ] && return 1
  age=$((now - m))
  [ "$age" -ge "$FM_PR_GREEN_RETURN_INTERVAL" ]
}

report_task() {
  local id=$1 meta=$2 now=$3 since age
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  fm_pr_metadata_identity_parse "$meta" || return 1
  evaluate_task "$id" "$meta"
  now=$(now_epoch)
  since=
  case "$EV_CLASS" in
    due) since=$EV_SINCE_HINT ;;
    held)
      record_read "$id"
      if [ "$REC_HEAD" = "$PR_HEAD" ] && [ "$REC_CLASS" = held ] && [ "$REC_REASON" = "$EV_REASON" ]; then
        since=$REC_SINCE
      fi
      ;;
  esac
  case "$since" in ''|*[!0-9]*) since=$now ;; esac
  age=$((now - since))
  [ "$age" -ge 0 ] || age=0
  printf '%s\t%s\t%s\t%s\t%s\tsince=%s\tage=%s\n' \
    "$id" "$EV_CLASS" "$EV_REASON" "$PR_URL" "$PR_HEAD" "$since" "$age"
}

usage() {
  sed -n '/^# Usage:/,/^# Dependencies:/p' "$0" | sed 's/^# \{0,1\}//'
}

mode=${1:-scan}
case "$mode" in
  scan)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    if ! scan_cadence_due; then
      exit 0
    fi
    if fm_run_timed $((FM_PR_GREEN_RETURN_BUDGET_SECS + 1)) "$0" _scan-locked; then
      :
    else
      status=$?
      # 124 is the outer backstop for a scan wedged outside every bounded
      # section; the scan's own deadline normally exits cleanly first, so a
      # backstop timeout is not a failure. Every other child status is.
      [ "$status" -eq 124 ] || exit "$status"
    fi
    ;;
  _scan-locked)
    [ "$#" -eq 1 ] || exit 2
    fm_lock_acquire_wait "$SCAN_LOCK" || exit 1
    trap 'fm_lock_release "$SCAN_LOCK"' EXIT
    scan_locked
    ;;
  report)
    shift
    policy_load
    now=$(now_epoch)
    if [ "$#" -eq 0 ]; then
      while IFS= read -r id; do
        [ -n "$id" ] || continue
        report_task "$id" "$STATE/$id.meta" "$now" || true
      done <<IDS
$(list_candidates)
IDS
    else
      for id in "$@"; do
        fm_pr_task_id_valid "$id" || { printf 'fm-pr-green-return: invalid task id: %s\n' "$id" >&2; exit 2; }
        report_task "$id" "$STATE/$id.meta" "$now" || true
      done
    fi
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
