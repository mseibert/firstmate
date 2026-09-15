#!/usr/bin/env bash
# tests/fm-pi-harness.test.sh - portable regression for the Pi/claude
# marker-collision verdict in bin/fm-harness.sh.
#
# CLAUDECODE=1 and PI_CODING_AGENT=true can appear together without either
# naming this process's own harness: a shell profile may export CLAUDECODE=1
# into a hand-started Pi primary, and a claude session a human starts inside a
# Pi primary inherits PI_CODING_AGENT=true. fm-spawn clears each foreign marker
# at its own launch boundary, but a hand-started session never passes through
# it. The load-bearing contracts:
#   1. With both markers set, the NEAREST harness ancestor decides: a real
#      `pi` process resolves pi, a real `claude` process stays claude even
#      nested inside a pi process, and any other or unreadable chain keeps
#      the conservative claude verdict instead of flipping to pi. Claude's
#      native installer names the per-session executable by its version, so
#      the nested claude fixture is the version-named install-path shape, not
#      a binary named claude.
#   2. A lone marker keeps its existing meaning: CLAUDECODE alone is claude,
#      PI_CODING_AGENT alone is pi, and pi-signed still comes only from
#      FM_PI_HARNESS together with Pi's own marker.
#   3. FM_PI_HARNESS can never select a Pi identity on its own, without Pi
#      ancestry or Pi's marker.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-pi-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# The ambient markers of whichever harness launched this suite outrank every
# case below, so each invocation drops the full foreign-marker set first and
# then states the markers it means to test.
CLEAN_MARKERS=(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u FM_OMP_HARNESS
  -u GROK_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI
  -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI)

# Real processes whose kernel-recorded identity is `pi`, `pi-signed`,
# `claude`, or `codex`: symlinks to the system shell, never copies (a copied
# platform binary fails macOS code signing). `ps -o comm=` reports the symlink
# name, the exact signal under test, and every -c body ends in a no-op so bash
# does not exec-optimize the named process away.
make_named_shells() {  # <dir> -> echoes <bindir>
  local dir=$1 name
  mkdir -p "$dir"
  for name in pi pi-signed claude codex; do
    ln -sf /bin/bash "$dir/$name"
  done
  printf '%s' "$dir"
}

# Claude Code's native installer names the per-session executable by its
# version (~/.local/share/claude/versions/2.1.220), so the basename identifies
# nothing: Linux reports comm=2.1.220 with the install path in argv[0], macOS
# reports the whole version path as comm. The same shape
# tests/fm-session-lock-ancestry.test.sh pins for the session-lock owner.
make_versioned_claude() {  # <dir> -> echoes the version-named executable path
  local dir=$1
  mkdir -p "$dir/share/claude/versions"
  ln -sf /bin/bash "$dir/share/claude/versions/2.1.220"
  printf '%s' "$dir/share/claude/versions/2.1.220"
}

# A `ps` that reports no harness anywhere in the chain, so the conservative
# both-marker verdict is deterministic no matter what launched this suite.
make_fake_ps_no_harness() {  # <fakebin>
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
set -u
field=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) shift 2 ;;
    *) shift ;;
  esac
done
case "$field" in
  comm=) printf '%s\n' bash ;;
  args=) printf '%s\n' bash ;;
  ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$1/ps"
}

test_both_markers_defer_to_the_nearest_harness_ancestor() {
  local bin out versioned_claude
  bin=$(make_named_shells "$TMP_ROOT/named")
  versioned_claude=$(make_versioned_claude "$TMP_ROOT/claude-install")

  # Case 1: a hand-started Pi primary whose shell exported CLAUDECODE=1.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$("${CLEAN_MARKERS[@]}" CLAUDECODE=1 PI_CODING_AGENT=true \
    "$bin/pi" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = pi ] || fail "a real pi process with an inherited CLAUDECODE must resolve pi, got '$out'"

  # Case 2: a claude worker under a Pi primary inherits PI_CODING_AGENT.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$("${CLEAN_MARKERS[@]}" CLAUDECODE=1 PI_CODING_AGENT=true \
    "$bin/claude" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = claude ] || fail "a real claude process with an inherited PI_CODING_AGENT must stay claude, got '$out'"

  # The NEAREST ancestor decides, not any Pi ancestor further up: a
  # version-named claude process nested inside a pi process must still resolve
  # claude. The trailing no-op keeps the pi ancestor alive instead of letting
  # bash exec-replace it with the claude process, and the version-named
  # install path is the real native shape whose basename names nothing.
  # shellcheck disable=SC2016 # both layers expand inside their named shells
  out=$("${CLEAN_MARKERS[@]}" CLAUDECODE=1 PI_CODING_AGENT=true \
    "$bin/pi" -c '"$1" -c '\''"$1"; :'\'' _ "$2"; :' _ "$versioned_claude" "$HARNESS")
  [ "$out" = claude ] || fail "a version-named claude process nested inside a pi process must resolve claude, got '$out'"

  # A markerless harness under the same inherited markers keeps the
  # conservative verdict, so this branch changes no other adapter's identity.
  # shellcheck disable=SC2016 # both layers expand inside their named shells
  out=$("${CLEAN_MARKERS[@]}" CLAUDECODE=1 PI_CODING_AGENT=true \
    "$bin/pi" -c '"$1" -c '\''"$1"; :'\'' _ "$2"; :' _ "$bin/codex" "$HARNESS")
  [ "$out" = claude ] || fail "both markers under a codex ancestor must keep the conservative claude verdict, got '$out'"

  # The signed identity still comes from the launch marker once ancestry proves pi.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$("${CLEAN_MARKERS[@]}" CLAUDECODE=1 PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed \
    "$bin/pi" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = pi-signed ] || fail "FM_PI_HARNESS=pi-signed under a real pi ancestor must stay pi-signed, got '$out'"

  # ...and an unmarked pi-signed ancestry remains plain pi.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$("${CLEAN_MARKERS[@]}" CLAUDECODE=1 PI_CODING_AGENT=true \
    "$bin/pi-signed" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = pi ] || fail "unmarked pi-signed ancestry with both markers must resolve pi, got '$out'"

  pass "fm-harness: both markers defer to the nearest real harness ancestor"
}

test_both_markers_without_a_harness_ancestor_stay_claude() {
  local dir fakebin out
  dir="$TMP_ROOT/no-ancestor"
  fakebin=$(fm_fakebin "$dir")
  make_fake_ps_no_harness "$fakebin"

  out=$("${CLEAN_MARKERS[@]}" CLAUDECODE=1 PI_CODING_AGENT=true \
    PATH="$fakebin:$BASE_PATH" "$HARNESS")
  [ "$out" = claude ] || fail "both markers with no readable harness ancestor must stay claude, got '$out'"

  # FM_PI_HARNESS cannot select a Pi identity on its own either.
  out=$("${CLEAN_MARKERS[@]}" CLAUDECODE=1 PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed \
    PATH="$fakebin:$BASE_PATH" "$HARNESS")
  [ "$out" = claude ] || fail "FM_PI_HARNESS without pi ancestry must not select pi-signed, got '$out'"

  pass "fm-harness: an unreadable chain keeps the conservative claude verdict"
}

test_single_marker_meanings_are_unchanged() {
  local bin out
  bin=$(make_named_shells "$TMP_ROOT/single")

  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$("${CLEAN_MARKERS[@]}" CLAUDECODE=1 "$bin/claude" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = claude ] || fail "CLAUDECODE alone must still resolve claude, got '$out'"

  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$("${CLEAN_MARKERS[@]}" PI_CODING_AGENT=true "$bin/pi" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = pi ] || fail "PI_CODING_AGENT alone must still resolve pi, got '$out'"

  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$("${CLEAN_MARKERS[@]}" PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed \
    "$bin/pi" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = pi-signed ] || fail "the pi-signed selection marker must still select pi-signed, got '$out'"

  pass "fm-harness: the single-marker verdicts are unchanged"
}

test_both_markers_defer_to_the_nearest_harness_ancestor
test_both_markers_without_a_harness_ancestor_stay_claude
test_single_marker_meanings_are_unchanged
