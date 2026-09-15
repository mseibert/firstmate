#!/usr/bin/env bash
# Manual end-to-end drive of the REAL bin/fm-update.sh (the mechanical half of
# /updatefirstmate) against isolated git worlds. Reproduces the reported
# incident: a home on the seibert/main fork line, 7 commits behind
# origin/seibert/main, with no local main mirror branch.
set -u

REPO=/home/mseibert/.no-mistakes/worktrees/4a711a5cbbc5/01M2J42BRS7GGJY6WMRX751T4Q
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.com
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
unset GIT_DIR GIT_WORK_TREE 2>/dev/null || true

FAILS=0
check() {  # <description> <command...>
  local desc=$1; shift
  if "$@"; then
    printf 'CHECK ok   - %s\n' "$desc"
  else
    printf 'CHECK FAIL - %s\n' "$desc"
    FAILS=$((FAILS + 1))
  fi
}
check_contains() {  # <desc> <haystack> <needle>
  case "$2" in
    *"$3"*) printf 'CHECK ok   - %s\n' "$1" ;;
    *) printf 'CHECK FAIL - %s\n  wanted: %s\n  got:\n%s\n' "$1" "$3" "$2"; FAILS=$((FAILS + 1)) ;;
  esac
}
check_not_contains() {
  case "$2" in
    *"$3"*) printf 'CHECK FAIL - %s (unexpected: %s)\n' "$1" "$3"; FAILS=$((FAILS + 1)) ;;
    *) printf 'CHECK ok   - %s\n' "$1" ;;
  esac
}

build_world() {  # <worlddir> <extra line commits pushed to origin/seibert/main>
  local w=$1 n=$2 i
  mkdir -p "$w/home/state" "$w/fakebin"
  touch "$w/home/state/.last-watcher-beat"
  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed"
  printf 'v1\n' > "$w/seed/AGENTS.md"
  mkdir -p "$w/seed/bin"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 'state/\ndata/\n' > "$w/seed/.gitignore"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main
  git clone -q "$w/origin.git" "$w/primary"
  git -C "$w/primary" checkout -q -b seibert/main main
  git -C "$w/primary" push -q origin seibert/main
  git clone -q "$w/origin.git" "$w/line-seed"
  git -C "$w/line-seed" checkout -q -B seibert/main origin/seibert/main
  for i in $(seq 1 "$n"); do
    printf 'v%s\n' "$i" > "$w/line-seed/AGENTS.md"
    printf 'echo %s\n' "$i" > "$w/line-seed/bin/tool.sh"
    git -C "$w/line-seed" add -A
    git -C "$w/line-seed" commit -qm "line-$i"
  done
  git -C "$w/line-seed" push -q origin seibert/main
  git -C "$w/primary" branch -D main >/dev/null   # mirror-less home, like the incident
}

run_product() {  # <world> [product-repo]
  local w=$1 repo=${2:-$REPO}
  FM_ROOT_OVERRIDE="$w/primary" FM_HOME="$w/home" PATH="$w/fakebin:$PATH" \
    bash "$repo/bin/fm-update.sh" 2>&1
}

parents_of() { git -C "$1" rev-list --parents -n1 "$2" | wc -w | tr -d ' '; }

TMP=$(mktemp -d /tmp/fm-forkline-live.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

printf '================ S1: mirror-less fork line, 7 commits behind origin/seibert/main ================\n'
W=$TMP/s1
build_world "$W" 7
BEFORE=$(git -C "$W/primary" rev-parse HEAD)
LINE_TIP=$(git -C "$W/line-seed" rev-parse HEAD)
printf 'home HEAD before: %s (%s)\n' "$BEFORE" "$(git -C "$W/primary" log --oneline -1)"
printf 'origin/seibert/main tip: %s\n' "$LINE_TIP"
printf 'refs/heads/main before: %s\n' "$(git -C "$W/primary" show-ref --verify --quiet refs/heads/main && git -C "$W/primary" rev-parse main || echo ABSENT)"
OUT=$(run_product "$W"); RC=$?
printf 'exit=%s\n--- product output ---\n%s\n----------------------\n' "$RC" "$OUT"
check_contains "S1 reports the fork line updated" "$OUT" "firstmate: updated "
check_contains "S1 reports the direct origin/seibert/main fast-forward" "$OUT" "fast-forwarded origin/seibert/main"
check_not_contains "S1 no longer refuses with 'cannot read main'" "$OUT" "cannot read main"
check "S1 HEAD is now origin/seibert/main tip" [ "$(git -C "$W/primary" rev-parse HEAD)" = "$LINE_TIP" ]
check "S1 previous tip is still an ancestor (no work lost)" git -C "$W/primary" merge-base --is-ancestor "$BEFORE" HEAD
check "S1 advance is a single-parent fast-forward (never a merge commit, never forced)" [ "$(parents_of "$W/primary" HEAD)" -eq 2 ]
check "S1 stays on the seibert/main fork line" [ "$(git -C "$W/primary" symbolic-ref --short HEAD)" = "seibert/main" ]
check "S1 created main mirror ref-only at origin/main" [ "$(git -C "$W/primary" rev-parse main)" = "$(git -C "$W/primary" rev-parse origin/main)" ]
check "S1 created mirror is not a merge commit (ref-only)" [ -z "$(git -C "$W/primary" rev-list --merges -n1 main)" ]
printf 'home HEAD after: %s (%s)\n' "$(git -C "$W/primary" rev-parse HEAD)" "$(git -C "$W/primary" log --oneline -1)"
printf 'refs/heads/main after: %s\n' "$(git -C "$W/primary" rev-parse main)"

printf '\n--- S1b: second run is an idempotent no-op ---\n'
OUT2=$(run_product "$W")
printf '%s\n' "$OUT2"
check_contains "S1b second run reports already current" "$OUT2" "firstmate: already current"
check "S1b HEAD unchanged by the second run" [ "$(git -C "$W/primary" rev-parse HEAD)" = "$LINE_TIP" ]

printf '\n================ S2: counterfactual on the BASE commit (pre-fix product) ================\n'
BASE_COMMIT=$(git -C "$REPO" rev-parse 899329d^)   # pre-fix product: fork-line path with the missing-mirror skip
BASE=/tmp/fm-base-prefix
rm -rf "$BASE"; mkdir -p "$BASE"
git -C "$REPO" archive "$BASE_COMMIT" | tar -x -C "$BASE"
printf 'pre-fix product commit: %s\n' "$BASE_COMMIT"
W2=$TMP/s2
build_world "$W2" 7
BEFORE2=$(git -C "$W2/primary" rev-parse HEAD)
OUT_BASE=$(run_product "$W2" "$BASE"); RC_BASE=$?
printf 'exit=%s\n--- base product output ---\n%s\n--------------------------\n' "$RC_BASE" "$OUT_BASE"
check_contains "S2 base product reproduces the reported failure" "$OUT_BASE" "firstmate: skipped: cannot read main"
check "S2 base product leaves the home behind (manual ff was required)" [ "$(git -C "$W2/primary" rev-parse HEAD)" = "$BEFORE2" ]

printf '\n================ S3: mirror-less line with own unpushed commits (no force, no rebase) ================\n'
W3=$TMP/s3
build_world "$W3" 3
printf 'own-work\n' > "$W3/primary/LINE-OWN.md"
git -C "$W3/primary" add LINE-OWN.md
git -C "$W3/primary" commit -qm line-own
OWN_TIP=$(git -C "$W3/primary" rev-parse HEAD)
OUT3=$(run_product "$W3")
printf '%s\n' "$OUT3"
check_not_contains "S3 no longer refuses with 'cannot read main'" "$OUT3" "cannot read main"
check "S3 own commit was never rebased or force-moved (HEAD unchanged)" [ "$(git -C "$W3/primary" rev-parse HEAD)" = "$OWN_TIP" ]
check "S3 own commit is still the tip" git -C "$W3/primary" merge-base --is-ancestor "$OWN_TIP" HEAD
check "S3 own working file survived" [ -f "$W3/primary/LINE-OWN.md" ]
check "S3 missing mirror was created ref-only at origin/main" [ "$(git -C "$W3/primary" rev-parse main)" = "$(git -C "$W3/primary" rev-parse origin/main)" ]

printf '\n================ S4: diverged main mirror is still skipped, line untouched ================\n'
W4=$TMP/s4
build_world "$W4" 3
git -C "$W4/primary" branch main origin/main
git -C "$W4/primary" checkout -q main
printf 'mirror-own\n' > "$W4/primary/MIRROR.md"
git -C "$W4/primary" add MIRROR.md
git -C "$W4/primary" commit -qm mirror-own
git -C "$W4/primary" checkout -q seibert/main
BEFORE4=$(git -C "$W4/primary" rev-parse HEAD)
MIRROR4=$(git -C "$W4/primary" rev-parse main)
OUT4=$(run_product "$W4")
printf '%s\n' "$OUT4"
check_contains "S4 diverged mirror still skips" "$OUT4" "firstmate: skipped: main diverged from origin/main"
check "S4 line was not moved past the diverged mirror" [ "$(git -C "$W4/primary" rev-parse HEAD)" = "$BEFORE4" ]
check "S4 diverged mirror ref was not moved" [ "$(git -C "$W4/primary" rev-parse main)" = "$MIRROR4" ]

printf '\n================ S5: dirty fork-line home is still skipped, edit preserved ================\n'
W5=$TMP/s5
build_world "$W5" 3
printf 'unlanded-edit\n' > "$W5/primary/UNLANDED.md"
BEFORE5=$(git -C "$W5/primary" rev-parse HEAD)
OUT5=$(run_product "$W5")
printf '%s\n' "$OUT5"
check_contains "S5 dirty working tree still skips" "$OUT5" "firstmate: skipped: dirty working tree"
check "S5 HEAD did not move" [ "$(git -C "$W5/primary" rev-parse HEAD)" = "$BEFORE5" ]
check "S5 unlanded edit preserved" [ -f "$W5/primary/UNLANDED.md" ]
check "S5 no stash was created" [ -z "$(git -C "$W5/primary" stash list)" ]

printf '\n================ S6: offline origin is still skipped ================\n'
W6=$TMP/s6
build_world "$W6" 3
git -C "$W6/primary" remote set-url origin "$W6/does-not-exist.git"
BEFORE6=$(git -C "$W6/primary" rev-parse HEAD)
OUT6=$(run_product "$W6")
printf '%s\n' "$OUT6"
check_contains "S6 unreachable origin still skips with fetch failed" "$OUT6" "firstmate: skipped: fetch failed"
check "S6 HEAD did not move" [ "$(git -C "$W6/primary" rev-parse HEAD)" = "$BEFORE6" ]

printf '\n================ S7: line fast-forward survives an unmergeable upstream merge ================\n'
W7=$TMP/s7
build_world "$W7" 0
printf 'line-conflict\n' > "$W7/line-seed/README.md"
git -C "$W7/line-seed" add README.md
git -C "$W7/line-seed" commit -qm line-conflict
git -C "$W7/line-seed" push -q origin seibert/main
LINE_TIP7=$(git -C "$W7/line-seed" rev-parse HEAD)
printf 'upstream-conflict\n' > "$W7/seed/README.md"
git -C "$W7/seed" add README.md
git -C "$W7/seed" commit -qm upstream-conflict
git -C "$W7/seed" push -q origin main
OUT7=$(run_product "$W7")
printf '%s\n' "$OUT7"
check_contains "S7 safe line advance is reported as updated" "$OUT7" "firstmate: updated "
check_contains "S7 reports the direct fast-forward" "$OUT7" "fast-forwarded origin/seibert/main"
check_contains "S7 names the unmergeable upstream merge" "$OUT7" "merge of main failed"
check "S7 line stayed on origin/seibert/main after the failed merge" [ "$(git -C "$W7/primary" rev-parse HEAD)" = "$LINE_TIP7" ]
check "S7 failed merge was aborted (no MERGE_HEAD)" [ ! -e "$W7/primary/.git/MERGE_HEAD" ]

printf '\n================ S8: new path adds no new clobber hazard (equivalence with the default-branch path) ================\n'
# The new fork-line advance uses the same `git merge --ff-only` mechanism as the
# ordinary default-branch path. Drive the same ignored-untracked collision on
# both paths and prove the outcome is equivalent.
W8=$TMP/s8a
build_world "$W8" 0
mkdir -p "$W8/line-seed/state"
printf 'remote-state\n' > "$W8/line-seed/state/foo"
git -C "$W8/line-seed" add -f state/foo
git -C "$W8/line-seed" commit -qm line-state
git -C "$W8/line-seed" push -q origin seibert/main
mkdir -p "$W8/primary/state"
printf 'local-state\n' > "$W8/primary/state/foo"
printf 'fork-line pre-run status --porcelain (ignored file invisible): [%s]\n' "$(git -C "$W8/primary" status --porcelain)"
OUT8A=$(run_product "$W8")
HEAD8A=$(git -C "$W8/primary" rev-parse HEAD)
FILE8A=$(cat "$W8/primary/state/foo")
printf '%s\nfork-line HEAD after: %s, state/foo: %s\n' "$OUT8A" "$HEAD8A" "$FILE8A"

W8B=$TMP/s8b
build_world "$W8B" 0
git -C "$W8B/primary" checkout -q main
mkdir -p "$W8B/seed/state"
printf 'remote-state\n' > "$W8B/seed/state/foo"
git -C "$W8B/seed" add -f state/foo
git -C "$W8B/seed" commit -qm main-state
git -C "$W8B/seed" push -q origin main
mkdir -p "$W8B/primary/state"
printf 'local-state\n' > "$W8B/primary/state/foo"
printf 'default-branch pre-run status --porcelain (ignored file invisible): [%s]\n' "$(git -C "$W8B/primary" status --porcelain)"
OUT8B=$(run_product "$W8B")
HEAD8B=$(git -C "$W8B/primary" rev-parse HEAD)
FILE8B=$(cat "$W8B/primary/state/foo")
printf '%s\ndefault-branch HEAD after: %s, state/foo: %s\n' "$OUT8B" "$HEAD8B" "$FILE8B"

check "S8 both paths report the same updated/skip outcome" \
  [ "$(printf '%s' "$OUT8A" | grep -c '^firstmate: updated ')" = "$(printf '%s' "$OUT8B" | grep -c '^firstmate: updated ')" ]
check "S8 both paths leave state/foo in the same state" [ "$FILE8A" = "$FILE8B" ]
check "S8 both paths advance the checkout" [ "$(printf '%s' "$OUT8A" | grep -c 'firstmate: updated ')" = "$(printf '%s' "$OUT8B" | grep -c 'firstmate: updated ')" ]

printf '\n================ RESULT: %s failed check(s) ================\n' "$FAILS"
[ "$FAILS" -eq 0 ]
