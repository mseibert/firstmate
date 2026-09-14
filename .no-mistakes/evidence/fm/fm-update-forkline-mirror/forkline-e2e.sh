#!/usr/bin/env bash
# Independent end-to-end driver for the mirror-less seibert/main fork-line update.
# Builds real isolated git worlds (bare origin + primary clone + fake tmux) and
# runs the REAL bin/fm-update.sh (pre-fix tree and target worktree) against them.
# No mocks of git; the product entry point is executed as an end user runs it.
set -u

TARGET_ROOT=${TARGET_ROOT:?}
PRE_ROOT=${PRE_ROOT:?}
WORK=${WORK:?}

PASS=0
FAIL=0
say() { printf '%s\n' "$*"; }
check() { # <desc> <expected-substring> <actual>
  case "$3" in
    *"$2"*) say "  PASS: $1"; PASS=$((PASS + 1)) ;;
    *) say "  FAIL: $1"; say "        expected to contain: $2"; say "        actual: $3"; FAIL=$((FAIL + 1)) ;;
  esac
}
check_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then say "  PASS: $1"; PASS=$((PASS + 1));
  else say "  FAIL: $1"; say "        expected: $2"; say "        actual:   $3"; FAIL=$((FAIL + 1)); fi
}
check_not() {
  case "$3" in
    *"$2"*) say "  FAIL: $1 (unexpectedly contains: $2)"; FAIL=$((FAIL + 1)) ;;
    *) say "  PASS: $1"; PASS=$((PASS + 1)) ;;
  esac
}

# new_world <dir>: bare origin with one commit on main, seed clone, primary clone.
new_world() {
  local w=$1
  mkdir -p "$w/home/state" "$w/home/data" "$w/fakebin" "$w/fake"
  : > "$w/fake/windows"
  cat > "$w/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) cat "$FM_FAKE_DIR/windows" ;;
  display-message)
    target=
    for arg in "$@"; do
      case "$arg" in main:fm-*) target=$arg ;; esac
    done
    case "${*: -1}" in
      *pane_current_command*)
        id=${target##*fm-}
        if [ -e "$FM_FAKE_DIR/dead-$id" ]; then printf 'zsh\n'; else printf 'claude\n'; fi
        ;;
      *) printf '\n' ;;
    esac
    ;;
esac
SH
  chmod +x "$w/fakebin/tmux"
  touch "$w/home/state/.last-watcher-beat"
  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null
  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$w/seed/bin/fm-remote-secondmate-control.sh"
  chmod +x "$w/seed/bin/fm-remote-secondmate-control.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main
  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true
}

# line_world <dir> <own-commits> <remote-commits> <keep-mirror>:
# primary on seibert/main; own unpushed commits on the line; remote line advanced.
line_world() {
  local w=$1 own=$2 remote=$3 keep_mirror=$4 i
  new_world "$w"
  git -C "$w/main" checkout -q -b seibert/main main
  if [ "$own" -gt 0 ]; then
    for i in $(seq 1 "$own"); do
      printf 'own-%s\n' "$i" > "$w/main/OWN-$i.md"
      git -C "$w/main" add "OWN-$i.md"
      git -C "$w/main" commit -qm "own-$i"
    done
  fi
  git -C "$w/main" push -q origin seibert/main
  if [ "$keep_mirror" != yes ]; then
    git -C "$w/main" branch -D main >/dev/null
  fi
  if [ "$remote" -gt 0 ]; then
    git clone -q "$w/origin.git" "$w/line-seed"
    git -C "$w/line-seed" checkout -q -B seibert/main origin/seibert/main
    for i in $(seq 1 "$remote"); do
      printf 'remote-%s\n' "$i" >> "$w/line-seed/REMOTE.md"
      [ "$i" -eq 1 ] && printf 'v2-line\n' > "$w/line-seed/AGENTS.md"
      git -C "$w/line-seed" add -A
      git -C "$w/line-seed" commit -qm "remote-$i"
    done
    git -C "$w/line-seed" push -q origin seibert/main
  fi
}

run_update() { # <root> <world>
  local root=$1 w=$2
  PATH="$w/fakebin:$PATH" FM_FAKE_DIR="$w/fake" FM_SSH_BIN=ssh \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$root/bin/fm-update.sh" 2>/dev/null
}

say "=== P1: PRE-FIX, mirror-less seibert/main 7 behind origin/seibert/main ==="
w1="$WORK/p1"
line_world "$w1" 0 7 no
head_before=$(git -C "$w1/main" rev-parse HEAD)
say "  local main mirror exists: $(git -C "$w1/main" show-ref --verify --quiet refs/heads/main && echo yes || echo no)"
out1=$(run_update "$PRE_ROOT" "$w1")
say "--- pre-fix fm-update.sh output ---"
say "$out1"
say "-----------------------------------"
check "pre-fix run reports the reported skip" "firstmate: skipped: cannot read main" "$out1"
check_eq "pre-fix run leaves the line behind" "$head_before" "$(git -C "$w1/main" rev-parse HEAD)"

say ""
say "=== P2: FIXED, same mirror-less 7-behind world ==="
w2="$WORK/p2"
line_world "$w2" 0 7 no
head_before=$(git -C "$w2/main" rev-parse HEAD)
line_tip=$(git -C "$w2/line-seed" rev-parse HEAD)
out2=$(run_update "$TARGET_ROOT" "$w2")
say "--- fixed fm-update.sh output ---"
say "$out2"
say "---------------------------------"
check "fixed run reports an update" "firstmate: updated " "$out2"
check "fixed run names the direct line fast-forward" "fast-forwarded origin/seibert/main" "$out2"
check_not "no 'cannot read main' skip" "cannot read main" "$out2"
check_eq "line advanced to origin/seibert/main tip" "$line_tip" "$(git -C "$w2/main" rev-parse HEAD)"
check_eq "line stayed on seibert/main" "seibert/main" "$(git -C "$w2/main" symbolic-ref --short HEAD)"
check_eq "advance is a single-parent fast-forward" "2" "$(git -C "$w2/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')"
check_eq "created main mirror is at origin/main" "$(git -C "$w2/main" rev-parse origin/main)" "$(git -C "$w2/main" rev-parse refs/heads/main)"
check_eq "created main mirror carries no commits of its own" "0 0" "$(git -C "$w2/main" rev-list --count main..origin/main) $(git -C "$w2/main" rev-list --count origin/main..main)"
check_eq "mirror is not checked out in any worktree" "" "$(git -C "$w2/main" for-each-ref --format='%(worktreepath)' refs/heads/main)"
check "instruction change from the remote line flips the reread gate" "reread-firstmate: yes" "$out2"
check "instruction change is named" "instructions changed: AGENTS.md" "$out2"

say ""
say "=== P3: GUARD, mirror-less line behind but dirty working tree ==="
w3="$WORK/p3"
line_world "$w3" 0 7 no
printf 'uncommitted work\n' >> "$w3/main/README.md"
head_before=$(git -C "$w3/main" rev-parse HEAD)
out3=$(run_update "$TARGET_ROOT" "$w3")
say "--- output ---"
say "$out3"
say "--------------"
check "dirty fork line is skipped" "firstmate: skipped: dirty working tree" "$out3"
check_eq "dirty line did not move" "$head_before" "$(git -C "$w3/main" rev-parse HEAD)"
check "local edit preserved" "uncommitted work" "$(cat "$w3/main/README.md")"
check_eq "no stash entry was created" "0" "$(git -C "$w3/main" stash list | wc -l | tr -d ' ')"

say ""
say "=== P4: mirror-less line with own commits + upstream advanced ==="
w4="$WORK/p4"
line_world "$w4" 1 0 no
own_tip=$(git -C "$w4/main" rev-parse HEAD)
printf 'upstream-2\n' >> "$w4/seed/README.md"
git -C "$w4/seed" add -A
git -C "$w4/seed" commit -qm upstream-2
git -C "$w4/seed" push -q origin main
out4=$(run_update "$TARGET_ROOT" "$w4")
say "--- output ---"
say "$out4"
say "--------------"
check "mirror-less line with own commits updates" "firstmate: updated " "$out4"
check "missing mirror is created and merged" "merged main" "$out4"
check_not "no 'cannot read main' skip" "cannot read main" "$out4"
git -C "$w4/main" merge-base --is-ancestor "$own_tip" HEAD && own_ok=yes || own_ok=no
check_eq "line's own commit survived" "yes" "$own_ok"
git -C "$w4/main" merge-base --is-ancestor origin/main HEAD && up_ok=yes || up_ok=no
check_eq "upstream origin/main reconciled into the line" "yes" "$up_ok"
check_eq "line stayed on seibert/main" "seibert/main" "$(git -C "$w4/main" symbolic-ref --short HEAD)"

say ""
say "=== P5: GUARD, self-modified (diverged) main mirror with a remote line advance ==="
w5="$WORK/p5"
line_world "$w5" 0 3 yes
# Self-modify the mirror: a commit on main that origin/main does not have.
git -C "$w5/main" checkout -q main
printf 'mirror-own\n' > "$w5/main/MIRROR.md"
git -C "$w5/main" add MIRROR.md
git -C "$w5/main" commit -qm mirror-own
git -C "$w5/main" checkout -q seibert/main
mirror_before=$(git -C "$w5/main" rev-parse main)
line_before=$(git -C "$w5/main" rev-parse HEAD)
out5=$(run_update "$TARGET_ROOT" "$w5")
say "--- output ---"
say "$out5"
say "--------------"
check "diverged mirror skips the whole update" "firstmate: skipped: main diverged from origin/main" "$out5"
check_eq "diverged mirror was not moved" "$mirror_before" "$(git -C "$w5/main" rev-parse main)"
check_eq "line was not fast-forwarded past the guard" "$line_before" "$(git -C "$w5/main" rev-parse HEAD)"

say ""
say "=== P6: ADVERSARIAL, UNPUSHED own commit + moved remote line is never force-moved ==="
w6="$WORK/p6"
new_world "$w6"
git -C "$w6/main" checkout -q -b seibert/main main
git -C "$w6/main" push -q origin seibert/main
printf 'unpushed\n' > "$w6/main/OWN-UNPUSHED.md"
git -C "$w6/main" add OWN-UNPUSHED.md
git -C "$w6/main" commit -qm own-unpushed
git -C "$w6/main" branch -D main >/dev/null
git clone -q "$w6/origin.git" "$w6/line-seed"
git -C "$w6/line-seed" checkout -q -B seibert/main origin/seibert/main
for i in 1 2 3; do
  printf 'remote-%s\n' "$i" >> "$w6/line-seed/REMOTE.md"
  git -C "$w6/line-seed" add -A
  git -C "$w6/line-seed" commit -qm "remote-$i"
done
git -C "$w6/line-seed" push -q origin seibert/main
own_tip=$(git -C "$w6/main" rev-parse HEAD)
remote_tip=$(git -C "$w6/line-seed" rev-parse HEAD)
out6=$(run_update "$TARGET_ROOT" "$w6")
say "--- output ---"
say "$out6"
say "--------------"
check_not "no forced fast-forward of a diverged line" "fast-forwarded origin/seibert/main" "$out6"
check_eq "line tip not force-moved onto the remote" "$own_tip" "$(git -C "$w6/main" rev-parse HEAD)"
check_eq "line tip differs from remote (unpushed commit kept)" "no" "$([ "$own_tip" = "$remote_tip" ] && echo yes || echo no)"
git -C "$w6/main" merge-base --is-ancestor "$own_tip" HEAD && own_ok=yes || own_ok=no
check_eq "unpushed own commit still reachable" "yes" "$own_ok"
check_eq "line stayed on seibert/main" "seibert/main" "$(git -C "$w6/main" symbolic-ref --short HEAD)"
check_eq "working tree still clean" "" "$(git -C "$w6/main" status --porcelain)"
check_eq "no stash entry was created" "0" "$(git -C "$w6/main" stash list | wc -l | tr -d ' ')"

say ""
say "=== P7: BOUNDARY, mirror-less line already on origin/seibert/main ==="
w7="$WORK/p7"
line_world "$w7" 0 0 no
head_before=$(git -C "$w7/main" rev-parse HEAD)
out7=$(run_update "$TARGET_ROOT" "$w7")
say "--- output ---"
say "$out7"
say "--------------"
check "already-current mirror-less line stays a no-op" "firstmate: already current" "$out7"
check_not "no false update reported" "firstmate: updated" "$out7"
check_eq "HEAD unchanged" "$head_before" "$(git -C "$w7/main" rev-parse HEAD)"
check_eq "missing mirror still created ref-only at origin/main" "$(git -C "$w7/main" rev-parse origin/main)" "$(git -C "$w7/main" rev-parse refs/heads/main)"

say ""
say "=== RESULT: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
