#!/usr/bin/env bash
# fm-ci-unprivileged.sh - run a CI command as an unprivileged user when the
# runner executes the job as root.
#
# Why this exists
#
# Several suites prove that a failure path really fails by injecting the failure
# with file permissions: a directory is made 0500 and the command under test must
# not be able to write into it. Root ignores those bits, so on a runner that
# executes the job as root the injection creates no failure at all and the proof
# is vacuous - the suite either passes for the wrong reason or, where the test is
# written to fail closed, fails loudly.
#
# Measured 2026-09-16 in the Forgejo runner image
# (ghcr.io/catthehacker/ubuntu:act-24.04, job uid 0), running each suite as root
# and then as an unprivileged user:
#
#   suite                              root      unprivileged
#   fm-captain-hold-lifecycle          13/1      36/0
#   fm-public-followup                  0/1      73/0
#   fm-send-resolve-key                18/1      20/0
#   fm-session-start                    2/1      54/0
#   fm-sessionstart-nudge              18/1      23/0
#   fm-shared-captain-inheritance       0/1       8/0
#   fm-startup-network                  4/1      22/0
#
# Seven suites, one shared cause. The GitHub runner image runs jobs as the
# `runner` user and never showed it.
#
# What it does
#
# Not root: the command runs unchanged, so a developer's machine and the GitHub
# lane are unaffected. Root: the command is re-executed as an unprivileged user
# with a private TMPDIR and a writable copy of the runner's temp root, which is
# where the suite and its JSON artifact write.
#
# Usage:
#   fm-ci-unprivileged.sh <command> [args...]
#
# Environment:
#   FM_CI_USER   user to drop to; default the first uid >= 1000 in /etc/passwd,
#                falling back to a created `fmrunner`.
set -eu

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_ci_unprivileged_usage() {
  sed -n '2,42{s/^# \{0,1\}//;p;}' "$SELF_DIR/fm-ci-unprivileged.sh"
}

case "${1:-}" in
  --help|-h)
    fm_ci_unprivileged_usage
    exit 0
    ;;
  '')
    printf 'fm-ci-unprivileged.sh: a command is required\n' >&2
    exit 2
    ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  exec "$@"
fi

fm_ci_pick_user() {
  local name
  if [ -n "${FM_CI_USER:-}" ]; then
    id -u "$FM_CI_USER" >/dev/null 2>&1 || {
      printf 'fm-ci-unprivileged.sh: FM_CI_USER=%s does not exist\n' "$FM_CI_USER" >&2
      return 1
    }
    printf '%s\n' "$FM_CI_USER"
    return 0
  fi
  name=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd)
  if [ -n "$name" ]; then
    printf '%s\n' "$name"
    return 0
  fi
  useradd -m fmrunner >/dev/null 2>&1 || {
    printf 'fm-ci-unprivileged.sh: no unprivileged user and could not create one\n' >&2
    return 1
  }
  printf '%s\n' fmrunner
}

command -v setpriv >/dev/null 2>&1 || {
  printf 'fm-ci-unprivileged.sh: setpriv is required to drop privileges\n' >&2
  exit 1
}

CI_USER=$(fm_ci_pick_user) || exit 1
CI_UID=$(id -u "$CI_USER")
CI_GID=$(id -g "$CI_USER")
CI_HOME=$(getent passwd "$CI_USER" | awk -F: '{print $6}')
[ -n "$CI_HOME" ] || CI_HOME=/tmp

# A private scratch root the dropped user owns. The suite writes its fixtures
# under TMPDIR and its timing JSON under RUNNER_TEMP, so both are handed over.
CI_TMP=$(mktemp -d "${RUNNER_TEMP:-/tmp}/fm-ci-unprivileged.XXXXXX")
chown "$CI_UID:$CI_GID" "$CI_TMP"
if [ -n "${RUNNER_TEMP:-}" ] && [ -d "$RUNNER_TEMP" ]; then
  chown -R "$CI_UID:$CI_GID" "$RUNNER_TEMP" 2>/dev/null || true
fi

# The checkout belongs to the dropped user too. Some suites resolve a firstmate
# home from the working tree and create `state/` beside it, which fails for an
# unprivileged user on a root-owned workspace:
#   mkdir: cannot create directory '/workspace/<owner>/<repo>/state': Permission denied
# Measured 2026-09-17 in the Forgejo lane, where that single line was the whole
# reason tests/fm-spawn-batch.test.sh failed. The chown is best-effort: a
# workspace that cannot be chowned still runs, it just cannot write beside the
# checkout.
if [ -n "${GITHUB_WORKSPACE:-}" ] && [ -d "$GITHUB_WORKSPACE" ]; then
  chown -R "$CI_UID:$CI_GID" "$GITHUB_WORKSPACE" 2>/dev/null || true
elif [ -n "${PWD:-}" ] && [ -d "$PWD" ]; then
  chown -R "$CI_UID:$CI_GID" "$PWD" 2>/dev/null || true
fi

exec setpriv --reuid="$CI_UID" --regid="$CI_GID" --init-groups \
  env "HOME=$CI_HOME" "TMPDIR=$CI_TMP" "PATH=$PATH" \
  "FM_CI_UNPRIVILEGED=1" "$@"
