#!/usr/bin/env bash
# Detect the agent harness this process tree runs on.
# Usage: fm-harness.sh                  print own harness: claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|gemini|muse|rovo|omp|unknown
#        fm-harness.sh crew             print the effective CREWMATE harness
#                                        (config/crew-harness; "default" resolves to own)
#        fm-harness.sh secondmate       print the harness the PRIMARY uses to launch
#                                        SECONDMATE agents: config/secondmate-harness ->
#                                        config/crew-harness -> own. "default" or absent
#                                        defers to the crew resolution, so an unset
#                                        secondmate-harness behaves exactly as the crew
#                                        harness did before this knob existed.
#        fm-harness.sh secondmate-model    print the optional MODEL token from
#                                        config/secondmate-harness, or empty when absent.
#        fm-harness.sh secondmate-effort   print the optional EFFORT token from
#                                        config/secondmate-harness, or empty when absent.
# config/secondmate-harness format: a single line "<harness> [<model>] [<effort>]",
# whitespace-separated. A bare "<harness>" (today's format) behaves exactly as before:
# harness only, no model/effort. Only the first non-empty, non-comment line is parsed.
# Model/effort come ONLY from this file - config/crew-harness stays a bare adapter
# name and is never parsed for a model.
# Detection layers: verified environment markers first, then process ancestry.
# Record each newly verified env marker here.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-cursor-lib.sh
. "$SCRIPT_DIR/fm-cursor-lib.sh"
# shellcheck source=bin/fm-gemini-lib.sh
. "$SCRIPT_DIR/fm-gemini-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

detect_own() {
  # Layer 1: environment markers for verified harnesses.
  # Keep marker detection before ancestry detection as an explicit precedence rule.
  # Claude, Pi, Grok, and Cursor set verified markers of their own; codex,
  # opencode, Kimi, and Muse are markerless, so a foreign marker retained in a terminal
  # multiplexer's stored environment can silently misidentify one of them before
  # ancestry is consulted. This is a precedence hazard, not evidence that
  # CLAUDECODE inheritance into a kimi child was observed; it was not observed.
  # Cursor is checked BEFORE claude, deliberately. cursor-agent does NOT clear
  # an inherited CLAUDECODE, so a cursor worker launched from a claude primary
  # carries BOTH markers and whichever is tested first wins. Cursor's own
  # markers are unambiguous when present, so ordering them first is what makes
  # the verdict correct; bin/fm-spawn.sh additionally clears the foreign markers
  # at the launch boundary. Both are kept: the launch sanitization only covers
  # sessions fm-spawn started, while this ordering also covers a cursor session
  # a human started by hand. Verified live on cursor-agent 2026.08.11-e8db854:
  # CURSOR_INVOKED_AS=cursor-agent is set on the agent process itself, and
  # CURSOR_AGENT=1 is set for the child/tool processes this script runs as.
  [ "${CURSOR_AGENT:-}" = "1" ] && { echo cursor; return; }
  [ "${CURSOR_INVOKED_AS:-}" = "cursor-agent" ] && { echo cursor; return; }
  # Gemini is checked BEFORE claude for exactly cursor's reason above: the
  # Gemini CLI does NOT clear an inherited CLAUDECODE, so a gemini worker
  # launched from a claude primary carries BOTH markers and whichever is
  # tested first wins. Verified live on gemini-cli 0.58.0: a tool process
  # spawned by a gemini worker under a claude primary reported GEMINI_CLI=1
  # AND CLAUDECODE=1 together. GEMINI_CLI is gemini's own and is unset in the
  # launching environment, so ordering it first is what makes the verdict
  # correct; bin/fm-spawn.sh additionally clears the foreign markers at the
  # launch boundary. Both are kept for the same reason cursor keeps both.
  # AI_AGENT is deliberately NOT used: it was present in that same process
  # carrying the claude primary's value (claude-code_2-1-260_agent), so it is
  # an inherited launcher marker, not a Gemini identity.
  [ "${GEMINI_CLI:-}" = "1" ] && { echo gemini; return; }
  # rovo (Atlassian Rovo CLI) sets ATLASSIAN_AGENT_TYPE=rovo, ROVODEV_CLI=1, and
  # AGENT=rovodev_cli on its tool subprocesses (verified, rovo 202609.1.2). It does
  # NOT scrub an inherited CLAUDECODE, so a rovo worker launched from a claude
  # session carries both markers - this must be tested BEFORE the CLAUDECODE line,
  # the same ordering hazard cursor documents above (see issue #3517). bin/fm-spawn.sh
  # additionally clears foreign markers at rovo's launch boundary as defense in depth.
  [ "${ATLASSIAN_AGENT_TYPE:-}" = "rovo" ] && { echo rovo; return; }
  [ "${ROVODEV_CLI:-}" = "1" ] && { echo rovo; return; }
  # omp (Oh My Pi) publishes NO harness-identity marker of its own: verified on
  # omp 18.1.11 that PI_CODING_AGENT is absent from the binary and that the
  # default profile sets neither PI_CODING_AGENT_DIR nor OMP_PROFILE in the
  # process environment. FM_OMP_HARNESS=omp is therefore a Firstmate-OWNED
  # launch marker, established by bin/fm-spawn.sh at the omp launch boundary
  # (which also clears every foreign marker) and by the README's primary launch
  # command. It is a PRECEDENCE override, never evidence on its own: it wins
  # over an inherited CLAUDECODE only when an omp process is genuinely in the
  # ancestry, so `FM_OMP_HARNESS=omp omp` started from a Claude pane identifies
  # as omp, while the same variable leaking from an omp secondmate into that
  # home's claude worker (whose ancestry holds no omp) changes nothing. The
  # anchored ancestry arm below covers a plain hand-started `omp` by itself.
  if [ "${FM_OMP_HARNESS:-}" = omp ] && ancestry_names_omp; then
    echo omp
    return
  fi
  # CLAUDECODE and PI_CODING_AGENT can BOTH be present without either naming
  # this process's own harness, because each survives a launch that does not
  # clear it: a shell profile may export CLAUDECODE=1 into a hand-started Pi
  # primary (Pi inherits it and its launcher adds PI_CODING_AGENT=true), and a
  # claude session started by hand inside a Pi primary inherits
  # PI_CODING_AGENT=true. bin/fm-spawn.sh clears each foreign marker at the
  # matching launch boundary (CLAUDECODE for pi, PI_CODING_AGENT for claude),
  # so this branch covers what those boundaries cannot: a session a human
  # started by hand. Whichever marker is tested first then mislabels one of
  # the two, so when both are set the process chain decides: the nearest
  # harness ancestor is this process's real harness. A pi ancestor resolves
  # pi; anything else - a claude ancestor, another harness, or a chain the
  # walk cannot read - stays claude, the verdict the marker order produced
  # before this branch, so a real claude process is never silently relabelled
  # pi.
  if [ "${CLAUDECODE:-}" = "1" ] && [ "${PI_CODING_AGENT:-}" = "true" ]; then
    case "$(detect_ancestry)" in
      pi)
        if [ "${FM_PI_HARNESS:-}" = pi-signed ]; then echo pi-signed; else echo pi; fi
        ;;
      *) echo claude ;;
    esac
    return
  fi
  [ "${CLAUDECODE:-}" = "1" ] && { echo claude; return; }
  if [ "${PI_CODING_AGENT:-}" = "true" ]; then
    if [ "${FM_PI_HARNESS:-}" = pi-signed ]; then echo pi-signed; else echo pi; fi
    return
  fi
  # grok set GROK_AGENT=1 for its child/tool processes (verified, grok 0.2.73).
  # It does NOT set CLAUDECODE despite being Claude-Code-compatible, so the marker
  # is unambiguous WHEN PRESENT - but it is not guaranteed present. A grok 1.0.0
  # hook process carries GROK_HOOK_EVENT, GROK_HOOK_NAME, GROK_SESSION_ID, and
  # GROK_WORKSPACE_ROOT with no GROK_AGENT at all (verified from the live process
  # environment of a wedged grok 1.0.0 Stop hook, 2026-08-07). Treat this marker as
  # a fast path only; the ancestry walk below is what actually guarantees grok is
  # identified, and any rule that must be RELIABLE under grok has to test the hook
  # markers too (see .claude/settings.json Stop entries, docs/turnend-guard.md).
  [ "${GROK_AGENT:-}" = "1" ] && { echo grok; return; }
  # muse (Muse Code) publishes no harness-identity marker of its own. The only
  # MUSE_* variable it is documented to hand a child is MUSE_CURRENT_SESSION_LOG,
  # a per-session log PATH rather than an identity, and its export to tool
  # subprocesses is unverified (verified: muse 0.1.0-R708.1), so muse is detected
  # by ancestry alone below. Do NOT promote MUSE_CURRENT_SESSION_LOG to a marker
  # without verifying it reaches children AND that it cannot survive in a
  # multiplexer's stored environment, which is the precedence hazard above.
  # Layer 2: walk the parent chain and match the command name. The walk lives
  # in detect_ancestry because the both-marker collision above consults the
  # same nearest-ancestor evidence.
  detect_ancestry
}

# Walk up to eight parents and report the nearest harness this process tree
# runs on, or `unknown` when no ancestor is a recognized harness. The FIRST
# match wins, so a claude worker whose backend chain was originally started
# from a Pi session reports claude rather than the Pi process further up; the
# both-marker branch in detect_own depends on exactly that nearest-ancestor
# semantics.
detect_ancestry() {
  local pid=$$ comm args argv0 base
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    argv0=$(fm_cursor_argv0_for_pid "$pid" "$comm" 2>/dev/null || true)
    if fm_cursor_process_matches "$comm" '' "$argv0"; then
      echo cursor
      return
    fi
    # Gemini is checked before claude for the same precedence reason as the
    # marker layer above, so a gemini worker under a claude primary is never
    # read as claude. This path check covers a natively-named gemini binary
    # only. It does NOT reach the currently installed CLI, which is a node
    # bundle (~/.local/bin/gemini -> @google/gemini-cli/bundle/gemini.js):
    # modern Node on Linux reports `comm` as MainThread rather than node
    # (measured on Node v24.20.0), so neither this check nor the node
    # interpreter arm below matches a live gemini process. GEMINI_CLI above is
    # therefore load-bearing for gemini rather than a fast path, which is why
    # gemini is not offered as a primary or secondmate harness. Do NOT add
    # MainThread to the interpreter arm to close this: that would make the args
    # of EVERY node process searchable and let an unrelated node command
    # carrying a harness name in its arguments claim an identity.
    if fm_gemini_path_is_gemini "$comm"; then
      echo gemini
      return
    fi
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    base=$(basename -- "$comm")
    # The interpreter-shaped gemini arm comes before claude, the same
    # precedence the marker layer applies, so a gemini worker whose own args
    # also mention claude is never read as claude. It stays gated on the
    # interpreter command name exactly as the node arm below is, so an
    # unrelated process that merely mentions a gemini path in its arguments
    # cannot claim the identity.
    case "$base" in
      node*|python*)
        if fm_gemini_args_are_gemini "$args"; then
          echo gemini
          return
        fi ;;
    esac
    # Claude Code's native installer names the per-session executable by its
    # version (~/.local/share/claude/versions/2.1.220), so the basename
    # identifies nothing while the install path still says claude. The
    # session-lock identity owner already matches a whole `claude` path
    # component on both platforms; reuse it here instead of re-deriving a
    # basename rule that would climb past the real claude process to a Pi
    # ancestor further up.
    if fm_harness_process_matches "$comm" "$args" && [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ]; then
      echo claude
      return
    fi
    case "$base" in
      *codex*) echo codex; return ;;
      *opencode*) echo opencode; return ;;
      *grok*) echo grok; return ;;
      kimi) echo kimi; return ;;
      rovo) echo rovo; return ;;
      # muse's installed launcher ~/.local/bin/muse execs ~/.local/bin/muse-bin-<version>
      # (verified in the published launcher, muse 0.1.0-R708.1), so the live process
      # name carries the version and CHANGES on every auto-update. Match the stable
      # prefix rather than any exact name. Deliberately anchored, never *muse*, so
      # unrelated commands (musescore, amuse) cannot be misread as this harness.
      muse|muse-bin-*) echo muse; return ;;
      pi-signed) echo pi; return ;;
      pi) echo pi; return ;;
      # omp is a Bun-compiled single binary whose process name is exactly `omp`
      # (verified, omp 18.1.11: `ps -o comm=` reports omp from both its `!`
      # bash path and the model's bash tool). Anchored, never *omp*, so ompd,
      # comp, and similar unrelated commands are not misread as this harness.
      # It sits above the node*|python* interpreter fallback deliberately: the
      # optional claude-bridge extension runs a nested executable literally
      # named `claude` with its own node child, and the claude identity check
      # above would otherwise claim it if that subtree were ever walked.
      omp) echo omp; return ;;
      node*|python*)
        # Bare interpreter: match the harness name in its script path.
        case "$args" in
          *codex*) echo codex; return ;;
          *opencode*) echo opencode; return ;;
          *grok*) echo grok; return ;;
          *" pi "*|*/pi) echo pi; return ;;
        esac ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -z "$pid" ] || [ "$pid" -le 1 ]; then
      break
    fi
  done
  echo unknown
}

# True when an exact `omp` process sits within eight parents of this one. The
# same anchored match as the ancestry walk in detect_own, kept separate so the
# marker precedence above can demand real process evidence.
ancestry_names_omp() {
  local pid=$$ comm
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    [ "$(basename -- "$comm")" = omp ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

# Resolve the effective crewmate harness: config/crew-harness (a bare adapter
# name) wins; absent or "default" mirrors firstmate's own harness.
resolve_crew() {
  local crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ -z "$crew" ] || [ "$crew" = "default" ]; then detect_own; else echo "$crew"; fi
}

# Print the first non-empty, non-comment line of config/secondmate-harness
# (leading/trailing whitespace trimmed), or nothing when the file is absent or
# holds only blank/comment lines.
secondmate_line() {
  local line
  [ -f "$CONFIG/secondmate-harness" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    printf '%s\n' "$line"
    return 0
  done < "$CONFIG/secondmate-harness"
}

# Print the 1-based whitespace-separated token (1=harness, 2=model, 3=effort) of
# the resolved secondmate_line, or nothing if the line or that field is absent.
secondmate_field() {
  local idx=$1 line
  line=$(secondmate_line)
  [ -n "$line" ] || return 0
  # shellcheck disable=SC2086  # deliberate word-splitting: tokenizing the line into fields
  set -- $line
  case "$idx" in
    1) printf '%s\n' "${1:-}" ;;
    2) printf '%s\n' "${2:-}" ;;
    3) printf '%s\n' "${3:-}" ;;
  esac
}

# Resolve the harness the PRIMARY uses to launch SECONDMATE agents: a fallback
# chain config/secondmate-harness -> config/crew-harness -> own. An absent or
# "default" secondmate-harness token defers to the crew resolution, so an unset
# secondmate-harness behaves exactly as before this knob existed (a secondmate
# launched on the crew harness). config/secondmate-harness is the PRIMARY's own
# setting and is never inherited downstream - secondmates do not spawn secondmates.
resolve_secondmate() {
  local sm
  sm=$(secondmate_field 1)
  if [ -z "$sm" ] || [ "$sm" = "default" ]; then resolve_crew; else echo "$sm"; fi
}

# Print the optional model token (2nd field) from config/secondmate-harness, or
# empty when the harness token is absent/"default" (harness-only file, same as
# today) or when no model token is present.
resolve_secondmate_model() {
  local sm
  sm=$(secondmate_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 2
}

# Print the optional effort token (3rd field) from config/secondmate-harness,
# the same way.
resolve_secondmate_effort() {
  local sm
  sm=$(secondmate_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 3
}

case "${1:-}" in
  crew) resolve_crew ;;
  secondmate) resolve_secondmate ;;
  secondmate-model) resolve_secondmate_model ;;
  secondmate-effort) resolve_secondmate_effort ;;
  *) detect_own ;;
esac
