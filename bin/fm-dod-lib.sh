#!/usr/bin/env bash
# Single owner of a ship task's mode-specific "Definition of done" block.
# Sourced by bin/fm-brief.sh, which renders it into a generated ship brief, and by
# bin/fm-promote.sh, which renders it into the ship instructions a promoted scout
# receives. Both paths must hand the worker the same contract: a promoted
# no-mistakes worker that never received the ask-user escalation rule or the
# `--yes` ban is the exact delivery hole this single owner exists to close.
# The direct-PR and no-mistakes blocks both anchor the verdict-head ordering
# through one shared block: the rebase onto the current main is the last code
# step before the verdict is requested, the branch stays frozen until the
# verdict covers the head, and every verdict request is preceded by a target-base
# check and a mergeable check. local-only never requests a verdict and carries
# no such block.
# Both PR-opening blocks carry the five-lens gate requirement: the captain's
# merge policy treats a missing or unreported gate exactly like an open finding.
# direct-PR carries it as a mandatory `## Five-lens gate` section in the PR body
# the worker opens; no-mistakes carries the same lenses as one designated PR
# comment, because the pipeline writes the PR body. local-only opens no PR and
# carries neither.
# fm_dod_block <no-mistakes|direct-PR|local-only> <task-id> prints the block on
# stdout with no trailing blank line. The caller validates the mode; an unknown
# mode is refused rather than silently rendered as the pipeline contract.
# The block opens with the fixed machine-readable "Delivery contract: mode=<mode>"
# line that bin/fm-spawn.sh checks a ship brief against.
# This file is the one owner of the no-mistakes `--intent` contract: only the
# brief's `## Captain's intent` subsection plus later captain words, never
# `## Firstmate spec` and never the worker's own tradeoffs.
# Author the subsection body and later relays as the actual words, without
# adding speaker labels or direct address: the heading supplies provenance and
# is not part of --intent. A legacy mixed Task instead marks each captain line
# with `[captain] `; the selector returns its words, not that metadata prefix.
# Previously stored speaker labels remain readable for compatibility only.
# Never scrub literal examples or other content the captain actually supplied.
# The string passed must be self-sufficient - it plus the codebase reconstructs
# roughly the same specification - so a report, decision, or PR the intent
# refers to is written into it as substance, never left as a pointer.
# bin/fm-brief.sh scaffolds those two `# Task` subsections; bin/fm-spawn.sh and
# bin/fm-promote.sh refuse leftover `{TASK}` / `{FIRSTMATE_SPEC}` placeholders
# and a `## Captain's intent` line opening with a Captain label or address
# through the helpers below. Other mentions of `--intent` point here rather than
# restating the rule.
# Every heredoc here stays outside a command substitution: `VAR=$(cat <<EOF ...)`
# breaks parsing of the whole file on Bash 3.2 (tests/fm-brief.test.sh).
# fm_brief_worker_role owns the ship/scout role scope. bin/fm-spawn.sh is its one
# emitter, supplying it first in every ship/scout launch brief and never to a
# secondmate charter. It names the one task-owned steering inbox without
# relaxing isolation from every other home's endpoint namespace. Like
# fm_brief_intent_overlay it is a distinctly titled launch section that states
# its own precedence, so a brief or project instruction that authors a
# conflicting role is superseded rather than duplicated.
# fm_ship_rule_one owns the mode-specific first ship safety rule shared by an
# ordinary ship brief and the durable contract written during scout promotion.

fm_brief_worker_role() {  # <state-dir> <task-id>
  local state=$1 task_id=$2
  cat <<'EOF'
# Current worker role contract
You are a crewmate: an autonomous worker agent managed by firstmate.
This section establishes your current identity before every project or task instruction below and supersedes any conflicting role identity in those instructions.
Do the assigned work yourself and report only to firstmate; do not adopt a firstmate or secondmate supervisor identity, delegate the task, run fleet supervision, or address the captain.
EOF
  printf "Your steering inbox is \`%s/%s.inbox\`; this exact path belongs to your current task even when it is outside the worktree or under the supervising firstmate home, so read and acknowledge its messages and do not reject it as another home's state.\n" "$state" "$task_id"
  cat <<'EOF'
Never inspect or change any other home's endpoint namespace; this authorization is limited to the exact task paths named by this brief.
When this task works on Firstmate itself, the repository root `AGENTS.md` (also imported by `CLAUDE.md`) is project content and the supervisor contract for the firstmate managing you: follow this brief instead of that supervisor contract.
Project instructions still govern the work wherever they do not conflict with this worker identity, including `CONTRIBUTING.md` and `firstmate-coding-guidelines` for Firstmate changes.
EOF
}

fm_ship_rule_one() {  # <no-mistakes|direct-PR|local-only> <task-id>
  local mode=$1 id=$2
  case "$mode" in
    direct-PR)
      printf '%s\n' "1. Never push to the default branch (push only your \`fm/$id\` branch). Never merge a PR."
      ;;
    local-only)
      printf '%s\n' "1. Never push to any remote and never open a PR. Work only on your \`fm/$id\` branch; firstmate handles the merge into local \`main\`."
      ;;
    no-mistakes)
      printf '%s\n' '1. Never push to the default branch. Never merge a PR.'
      ;;
    *)
      echo "error: fm_ship_rule_one: unknown delivery mode '$mode'" >&2
      return 1
      ;;
  esac
}

# Return 0 when a Task subsection still consists only of its scaffold
# placeholder. A missing file and legacy briefs carry no such placeholders.
fm_brief_task_placeholders_present() {  # <file>
  local file=$1 intent spec
  [ -f "$file" ] || return 1
  intent=$(fm_brief_task_heading_body "$file" "## Captain's intent")
  spec=$(fm_brief_task_heading_body "$file" "## Firstmate spec")
  [ "$(printf '%s' "$intent" | tr -d '[:space:]')" = '{TASK}' ] && return 0
  [ "$(printf '%s' "$spec" | tr -d '[:space:]')" = '{FIRSTMATE_SPEC}' ] && return 0
  return 1
}

# Parse an exact ATX heading outside fenced blocks. Body mode prints through
# the next unfenced heading at the same or a higher level; present mode reports
# whether the heading exists.
fm_brief_heading_parse() {  # <file|-> <heading> <body|present>
  local file=$1 heading=$2 mode=$3 input=$1
  if [ "$file" = - ]; then
    input=/dev/stdin
  else
    [ -f "$file" ] || { [ "$mode" = body ]; return; }
  fi
  awk -v heading="$heading" -v mode="$mode" '
    BEGIN {
      target_level = 0
      while (substr(heading, target_level + 1, 1) == "#") target_level++
    }
    {
      line = $0
      scan = line
      spaces = 0
      while (spaces < 3 && substr(scan, 1, 1) == " ") {
        scan = substr(scan, 2)
        spaces++
      }
      marker = substr(scan, 1, 1)
      marker_len = 0
      if (marker == "`" || marker == "~") {
        while (substr(scan, marker_len + 1, 1) == marker) marker_len++
      }
      is_fence = marker_len >= 3
      was_fenced = fenced

      if (is_fence) {
        rest = substr(scan, marker_len + 1)
        if (!fenced) {
          fenced = 1
          fence_marker = marker
          fence_len = marker_len
        } else if (marker == fence_marker && marker_len >= fence_len && rest ~ /^[[:space:]]*$/) {
          fenced = 0
        }
      }

      if (!found && !was_fenced && line == heading) {
        found = 1
        if (mode == "present") next
        grab = 1
        next
      }
      if (mode == "present" || !grab) next
      if (is_fence || was_fenced) {
        print line
        next
      }

      level = 0
      while (substr(scan, level + 1, 1) == "#") level++
      if (level > 0 && level <= target_level && substr(scan, level + 1, 1) ~ /^[[:space:]]?$/) exit
      print line
    }
    END {
      if (mode == "present" && !found) exit 1
    }
  ' "$input"
}

fm_brief_heading_body() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" body
}

fm_brief_heading_present() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" present >/dev/null
}

fm_brief_task_heading_body() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  printf '%s\n' "$task" | fm_brief_heading_parse - "$2" body
}

fm_brief_task_heading_present() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  printf '%s\n' "$task" | fm_brief_heading_parse - "$2" present >/dev/null
}

fm_brief_marked_captain_words() {  # <task-body>
  printf '%s\n' "$1" | awk '
    match($0, /^[[:space:]]*(\[captain\]|Captain('\''s (words|ask|intent))?:)[[:space:]]*/) {
      words = substr($0, RLENGTH + 1)
      if (words ~ /[^[:space:]]/) print words
    }
  '
}

fm_brief_intent_overlay() {  # <captain-intent>
  cat <<'EOF'

# Current no-mistakes intent contract
This section supersedes every earlier brief instruction about constructing `--intent`, but not later clarifications actually supplied by the captain.
Use everything under `## Captain intent authorized for --intent` through the end of this brief, including any nested subheadings but excluding that heading, plus any later words the captain actually supplied as `--intent`; never include Firstmate specification or other mixed Task content.
Preserve those words without adding speaker labels or direct address.
Firstmate-authored constraints, acceptance criteria, implementation details, decisions, and tradeoffs are specification, not captain intent.
The Definition of done's rule that `--intent` must be self-sufficient still governs the string you pass: resolve any report, decision, or PR the intent below refers to into its substance rather than passing the pointer.

## Captain intent authorized for --intent
EOF
  printf '%s\n' "$1"
}

# Accept the current two-subsection contract only when both bodies have content;
# briefs predating that contract remain valid when their # Task body has content.
fm_brief_task_content_valid() {  # <file>
  local file=$1 intent spec task has_intent=0 has_spec=0
  [ -f "$file" ] && [ -r "$file" ] || return 1
  fm_brief_task_heading_present "$file" "## Captain's intent" && has_intent=1
  fm_brief_task_heading_present "$file" "## Firstmate spec" && has_spec=1
  if [ "$has_intent" -eq 1 ] || [ "$has_spec" -eq 1 ]; then
    [ "$has_intent" -eq 1 ] && [ "$has_spec" -eq 1 ] || return 1
    intent=$(fm_brief_task_heading_body "$file" "## Captain's intent")
    spec=$(fm_brief_task_heading_body "$file" "## Firstmate spec")
    [ -n "$(printf '%s' "$intent" | tr -d '[:space:]')" ] || return 1
    [ -n "$(printf '%s' "$spec" | tr -d '[:space:]')" ] || return 1
    return 0
  fi
  task=$(fm_brief_heading_body "$file" "# Task")
  [ -n "$(printf '%s' "$task" | tr -d '[:space:]')" ]
}

# Print the first `## Captain's intent` body line that opens with an operator
# address spelling; fail when there is none. The body is never rewritten.
fm_brief_intent_address_line() {  # <file>
  fm_brief_task_heading_body "$1" "## Captain's intent" | awk '
    /^[[:space:]]*(Captain('\''s (words|ask|intent))?:|Captain,)/ { print; found = 1; exit }
    END { exit !found }
  '
}

fm_ask_user_escalation_block() {  # <data-dir> <task-id>
  local data=$1 id=$2
  cat <<EOF
   For a no-mistakes ask-user gate specifically, escalate all ask-user findings as one event plus one snapshot file, using that same shape even when the gate holds only a single ask-user finding: write only the ask-user findings, verbatim and unparaphrased (id, severity, file, line, description, authority), to \`$data/$id/nm-<run>-findings.txt\`, then report the gate with
   \`needs-decision [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file=$data/$id/nm-<run>-findings.txt\`
   naming every ask-user finding id from that gate. The status line only points at the file; it never restates or summarizes a finding's content.
EOF
}

# Shared verdict-head ordering for every ship mode that requests a review
# verdict (direct-PR and no-mistakes; local-only never requests one). A verdict
# only covers the head it was computed on, so the rebase onto the current main
# is the last code step before the verdict is requested, the branch stays frozen
# until the verdict covers the head, and every verdict request is preceded by a
# target-base check (the intended integration branch, never the default) and a
# mergeable check. The description parameter names how the mode requests the
# verdict; the ordering itself stays a single definition so the two modes cannot
# drift apart. Emitted with a trailing blank line so callers can chain it into
# their definition-of-done heredocs.
fm_verdict_ordering_block() {  # <verdict-request-description>
  local verdict_request=$1
  cat <<EOF
A review verdict only covers the branch head it was computed on, so order the loop so every verdict lands on the final mergeable head.
Three of the last five fleet PRs shipped a verdict older than their head, because a commit or rebase landed after the verdict and invalidated it.
Enforce that ordering structurally instead of by discipline:

1. Implement the change and apply every fix. Make no further code changes after this step.
2. Rebase onto the current main as the LAST code step, so the branch is up to date and mergeable.
3. Request the verdict only after that rebase: $verdict_request.
4. Freeze the branch until the verdict has landed and is verified to cover your head: after step 3, make no commits and run no rebase until the verdict's timestamp is newer than the branch head it must cover.
5. Read the verdict timestamp correctly per forge. Ein frisches Verdict auf Forgejo erkennst du am updated_at des crabd-Tracking-Kommentars, NICHT an created_at und NICHT daran, dass ein neuer Kommentar erscheint. crabd editiert denselben Kommentar. Vergleiche updated_at gegen die Commit-Zeit deines Kopfes. Auf GitHub ist es umgekehrt.

Before every verdict request, check the PR's target base first: it must be the project's intended integration branch, never the default branch.
On the firstmate fork that base is seibert/main, and a PR pointed at main trips the red "PR must be raised via no-mistakes" check - the early warning for a wrong base, not a broken check.
Correct a wrong base before requesting anything, then check that the branch is mergeable onto the current main; if it is not (main has moved), rebase first, then request the verdict.

EOF
}

# Shared five-lens rule text for both PR-opening definitions of done: the lens
# list with its one-line focus, the per-lens result table, the two-sided Result
# rule, and the bounded re-run rule that keeps every later fix gated.
# <lens-intro> opens the lens list, <table-intro> introduces the table, the
# optional <between> sits between them, and the optional <heading> is emitted
# directly above the table. Emitted with no trailing blank line so callers can
# append their own mode-specific sentences.
fm_five_lens_rules_block() {  # <lens-intro> <table-intro> [<between>] [<heading>]
  local lens_intro=$1 table_intro=$2 between=${3:-} heading=${4:-}
  cat <<EOF
$lens_intro \`code-review\` (correctness), \`maintainability-review\` (rot, bandaids, speculative scaffolding), \`structural-fit-review\` (structural fit and defended choices), \`design-decision-questioner\` (challenge the decisions), \`self-containment-review\` (context a repo reader cannot resolve).
The \`structural-fit-review\` lens is also called \`architecture-system-design-reviewer\`.
EOF
  if [ -n "$between" ]; then
    printf '%s\n' "$between"
  fi
  printf '%s\n' "$table_intro"
  printf '\n'
  if [ -n "$heading" ]; then
    printf '%s\n' "$heading"
  fi
  cat <<'EOF'
| Lens | Ran | Findings | Fixed |
|---|---|---|---|
| code-review | <yes or no> | <n> | <n> |
| maintainability-review | <yes or no> | <n> | <n> |
| structural-fit-review | <yes or no> | <n> | <n> |
| design-decision-questioner | <yes or no> | <n> | <n> |
| self-containment-review | <yes or no> | <n> | <n> |
EOF
  printf '\n'
  cat <<'EOF'
End it with `Result: clean` only when every `Ran` cell says `yes` and no finding remains open; otherwise name what is not clean there, as `Result: 1 finding open - see <lens>` or `Result: 1 lens did not report - see <lens>`.
Fix findings and re-run the lenses each fix affects, up to three rounds (a round is one lens pass plus its fixes; a later round re-runs only the lenses a fix affects); a lens that could not run is retried once before it is recorded as not-run.
EOF
}

# Direct-PR five-lens gate requirement. The shared rules helper carries the lens
# list, table, and Result rule; this block adds the mandatory `## Five-lens gate`
# body section, its degradation sentences, and the unclean done line. The one-line
# focus per lens keeps the requirement self-contained for a worker whose harness
# has no lens skill of its own, and the block tells the worker to surface an
# unclean gate in its done line so the ready signal carries the open gate instead
# of hiding it behind a bare PR URL. Emitted with a trailing blank line so callers
# can chain it into their definition-of-done heredocs.
fm_five_lens_gate_block() {
  cat <<'EOF'
The PR body must carry its own `## Five-lens gate` section with the result of every lens, because a missing, incomplete, or unreported gate counts exactly like an open finding.
EOF
  fm_five_lens_rules_block \
    "Run the five lenses over the branch diff, each in its own fresh context (a subagent or a fresh session), and fix what they find:" \
    "Record one row per lens in the PR body - whether it ran, how many findings it reported, how many you fixed - in this shape, replacing every placeholder with the real result:" \
    "" "## Five-lens gate"
  cat <<'EOF'
Run the gate on the branch content you are about to push, after the rebase and before the verdict request and freeze in the ordering above; re-run the lenses affected by any later change - a fix, or a rebase that changed the diff - so every pushed line has been gated.
If the final result is not clean, append `done: PR {url} - five-lens gate: <what is not clean>` instead of the plain done line, so the open gate reaches firstmate with the ready signal.

EOF
}

# No-mistakes five-lens gate requirement. no-mistakes opens the PR through the
# pipeline, so the worker cannot write the PR body; the gate evidence goes into
# one designated PR comment instead. The block calls the shared
# fm_five_lens_rules_block for the lens list, per-lens result rows, and Result
# rule, adds the final-head and CI-state rule, and states that the captain's
# merge policy accepts the exact-titled comment as the five-lens evidence.
# Emitted with a trailing blank line so callers can chain it into their
# definition-of-done heredocs.
fm_five_lens_comment_block() {
  cat <<'EOF'
no-mistakes opens the PR through the pipeline, so the five-lens gate for this mode is a separate PR comment instead of a PR-body section.
EOF
  fm_five_lens_rules_block \
    "After the pipeline opens the PR, run the five lenses over the branch diff, each in its own fresh context (a subagent or a fresh session):" \
    "Then post exactly ONE comment on the PR with the title \`Findings and fixes from 5-lenses-review\`, recording one row per lens in this shape, replacing every placeholder with the real result:" \
    "Fix what they find and push the fixes as an ADDITIONAL commit on the same branch; when nothing was found, push nothing and say so in the comment."
  cat <<'EOF'
The comment must name the FINAL head SHA and the CI state on that head; after a fix commit the gate covers the head after that commit, not the pipeline head.
The pipeline verdict covers the pipeline head, and the five-lens comment plus CI cover the final head after any lens fix - that split is this mode's accepted tradeoff.
Keep the order strict: lenses, then fixes, then push, then the comment.
Never merge the PR; the configured merge authority decides.
The captain's merge policy accepts this exact-titled comment as the five-lens evidence on a no-mistakes PR, so it satisfies the merge gate; a comment with any other title does not count.

EOF
}

fm_dod_block() {  # <mode> <task-id>
  local mode=$1 id=$2
  case "$mode" in
    direct-PR)
      cat <<EOF
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
EOF
      fm_verdict_ordering_block "when your task's instructions call for a review verdict, request it once the branch is pushed and the PR is open"
      fm_five_lens_gate_block
      cat <<EOF
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
      ;;
    local-only)
      cat <<EOF
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$id\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch fm/$id\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
      ;;
    no-mistakes)
      cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.
EOF
      fm_verdict_ordering_block "start or continue the no-mistakes run that computes the review verdict against the branch head"
      cat <<'EOF'
The freeze in step 4 covers the pipeline head the run validates; keep it until the verdict has landed and covers that head.
The five-lens pass below is then the designated post-verdict step, and any fix commit it pushes becomes the final head the comment must cover.
EOF
      cat <<EOF
You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, pass \`--intent\` as only this brief's \`## Captain's intent\` subsection body, not its heading, plus any later words the captain actually said.
Preserve the actual words without adding speaker labels or direct address; the subsection heading supplies provenance outside the pipeline input.
For a legacy brief with no such subsection, include only words on lines marked \`[captain] \`, excluding that metadata prefix; never copy its mixed \`# Task\` wholesale.
If it has no provenance-marked captain words, stop and ask firstmate instead of starting no-mistakes.
Do not include \`## Firstmate spec\`, later Firstmate build constraints, or your own decisions and tradeoffs.
The \`--intent\` string you pass must be self-sufficient: that string plus the codebase must let a reader reconstruct roughly the same specification, without depending on a separate report, a PR, or context that lives only in this conversation.
When the captain's intent refers to a report, decision, or PR ("do items 1, 2, 3, and 7 of the report"), write the substance of the referenced items into \`--intent\` in the captain's terms, not only the pointer; that substance is the captain's ask by reference, while Firstmate's build instructions and your own decisions still stay out.
This replaces the no-mistakes skill's advice to enrich \`--intent\` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix; the post-pipeline five-lens pass below is the designated worker-owned commit step.

One drive call blocks until the next gate or outcome, which routinely outlives what your harness lets a single command run: Claude Code kills a command at ten minutes maximum, while one fix round is capped around thirty minutes and up to three rounds chain.
So background the drive call and poll \`no-mistakes axi status\` from a separate call instead of sitting in one blocking hold your harness will kill.
Where a harness's own command limit is not established, assume it bounds commands and use that same background-and-poll shape.
A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
Reattach and keep going rather than reporting the pipeline blocked; rule 7 owns the checks that decide when a pipeline block is real.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
  Firstmate applies \`ask-user-authority\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.
EOF
      fm_five_lens_comment_block
      cat <<EOF
After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), run the five-lens pass and post its comment.
The pipeline's CI monitor re-arms on base movement, not on a new head, so when a lens fix commit moved the head, wait for CI to report on that final head and record its state in the comment.
Append \`done: PR {url} checks green\` only once CI is green on the final head the comment names, or \`done: PR {url} checks green - five-lens comment: <what is not clean>\` when CI is green there but the comment's Result is not clean.
When CI is red on that final head, append \`done: PR {url} checks red - <what failed>\` instead of any checks-green line, then stop - the pipeline run is complete, so the red head is firstmate's repair call.
You are finished.
EOF
      ;;
    *)
      echo "error: fm_dod_block: unknown delivery mode '$mode'" >&2
      return 1 ;;
  esac
}
