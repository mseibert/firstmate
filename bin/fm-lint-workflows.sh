#!/usr/bin/env bash
# fm-lint-workflows.sh - owner of firstmate's workflow lint.
#
# Runs pinned actionlint on every .github/workflows/*.{yml,yaml} and every
# .forgejo/workflows/*.{yml,yaml} so a malformed workflow, including a
# self-broken ci.yml, fails in the local and no-mistakes lint lane before merge.
# A broken ci.yml cannot report its own breakage, so this check must not live
# only as a step inside that workflow. bin/fm-lint.sh invokes this owner on its
# default (no explicit-path) path, which CI and commands.lint both use.
#
# Both directories are linted because this repository carries a lane on each:
# .github/workflows is the GitHub lane, .forgejo/workflows the Forgejo one, and a
# push runs whichever the receiving forge reads. Linting only one would let a
# broken workflow ship in the other.
#
# Usage:
#   fm-lint-workflows.sh                 lint workflows under this repo
#   fm-lint-workflows.sh --root <dir>    lint workflows under <dir>
#   fm-lint-workflows.sh <path>...       lint explicit workflow files
#   fm-lint-workflows.sh --required-version
#   fm-lint-workflows.sh --help
set -eu

REQUIRED_ACTIONLINT=1.7.12
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-lint-workflows.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_ACTIONLINT"
  exit 0
fi

fm_lint_workflows_usage() {
  sed -n '2,16{s/^# \{0,1\}//;p;}' "$SELF"
}

EXPLICIT_ROOT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || {
        printf 'fm-lint-workflows.sh: --root requires a directory.\n' >&2
        exit 2
      }
      EXPLICIT_ROOT=$2
      shift 2
      ;;
    --root=*)
      EXPLICIT_ROOT=${1#*=}
      shift
      ;;
    --help|-h)
      fm_lint_workflows_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'fm-lint-workflows.sh: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if [ -n "$EXPLICIT_ROOT" ]; then
  [ -d "$EXPLICIT_ROOT" ] || {
    printf 'fm-lint-workflows.sh: --root is not a directory: %s\n' "$EXPLICIT_ROOT" >&2
    exit 2
  }
  ROOT="$(cd "$EXPLICIT_ROOT" && pwd)"
fi

collect_workflow_files() {
  local dir=$1
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \) -type f \
    | LC_ALL=C sort
}

FILES=()
FORGEJO_FILES=()
if [ "$#" -gt 0 ]; then
  for path in "$@"; do
    case "$path" in
      *.yml|*.yaml) ;;
      *)
        printf 'fm-lint-workflows.sh: not a workflow YAML file: %s\n' "$path" >&2
        exit 2
        ;;
    esac
    [ -f "$path" ] || {
      printf 'fm-lint-workflows.sh: workflow file not found: %s\n' "$path" >&2
      exit 2
    }
    case "$path" in
      */.forgejo/workflows/*|.forgejo/workflows/*) FORGEJO_FILES+=("$path") ;;
      *) FILES+=("$path") ;;
    esac
  done
else
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    FILES+=("$path")
  done < <(collect_workflow_files "$ROOT/.github/workflows")
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    FORGEJO_FILES+=("$path")
  done < <(collect_workflow_files "$ROOT/.forgejo/workflows")
  if [ "${#FILES[@]}" -eq 0 ] && [ "${#FORGEJO_FILES[@]}" -eq 0 ]; then
    printf 'fm-lint-workflows.sh: no workflow files found under %s or %s\n' \
      "$ROOT/.github/workflows" "$ROOT/.forgejo/workflows" >&2
    exit 1
  fi
fi

if ! command -v actionlint >/dev/null 2>&1; then
  printf 'fm-lint-workflows.sh: actionlint not found; install actionlint %s with bin/fm-install-actionlint.sh <destination-directory> and put that directory on PATH.\n' \
    "$REQUIRED_ACTIONLINT" >&2
  exit 1
fi
ACTIONLINT_BIN=$(command -v actionlint)
resolved=$("$ACTIONLINT_BIN" -version | awk 'NR==1 {print; exit}')
printf 'fm-lint-workflows.sh: actionlint %s (pinned %s)\n' "$resolved" "$REQUIRED_ACTIONLINT" >&2
if [ "$resolved" != "$REQUIRED_ACTIONLINT" ]; then
  printf 'fm-lint-workflows.sh: actionlint %s required for CI parity, found %s. Install %s with bin/fm-install-actionlint.sh <destination-directory>.\n' \
    "$REQUIRED_ACTIONLINT" "$resolved" "$REQUIRED_ACTIONLINT" >&2
  exit 1
fi

# fm-lint.sh owns ShellCheck of the canonical shell set. Disable actionlint's
# extra shell and Python subprocess linters so this gate is the named workflow
# linter, not a second shell lint of `run:` blocks.
#
# The Forgejo lane is linted with one rule suppressed. Forgejo needs `uses:` to
# carry a full `https://github.com/...` URL, because a bare `owner/repo` resolves
# against forgejo.seibert.tools, where that repository does not exist. actionlint
# accepts only the bare form, so it rejects every URL-shaped `uses:` as malformed.
# The ignore is anchored on that URL prefix and on the message actionlint emits
# for it, so a genuinely broken reference - a missing ref, an unknown owner, a
# bare name that is not an action - still fails. Everything else actionlint
# checks, including the expressions, the shell of every `run:` block it is told
# to skip, and the job graph, is checked for the Forgejo lane too.
FORGEJO_USES_IGNORE='specifying action "https://github.com/'

rc=0
if [ "${#FILES[@]}" -gt 0 ]; then
  set +e
  "$ACTIONLINT_BIN" -no-color -shellcheck= -pyflakes= -- "${FILES[@]}"
  rc=$?
  set -e
fi
if [ "${#FORGEJO_FILES[@]}" -gt 0 ]; then
  set +e
  "$ACTIONLINT_BIN" -no-color -shellcheck= -pyflakes= \
    -ignore "$FORGEJO_USES_IGNORE" -- "${FORGEJO_FILES[@]}"
  forgejo_rc=$?
  set -e
  [ "$rc" -ne 0 ] || rc=$forgejo_rc
fi

if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi

printf 'fm-lint-workflows.sh: %s workflow files valid (%s GitHub, %s Forgejo)\n' \
  "$(( ${#FILES[@]} + ${#FORGEJO_FILES[@]} ))" "${#FILES[@]}" "${#FORGEJO_FILES[@]}"
exit 0
