#!/usr/bin/env bash
# Live drive of the seibert/main fork-line sync behavior against the real
# product (bin/fm-fleet-sync.sh, bin/fm-update.sh, bin/fm-teardown.sh).
# Every command below runs the real scripts from the worktree under test.
set -u
ROOT=/home/mseibert/.no-mistakes/worktrees/4a711a5cbbc5/01M2J8STHHJK4BF9T1SJVAWJGD
SB=/tmp/fm-live-evidence
PREFIX=/tmp/fm-live-evidence-prefix
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid

rm -rf "$SB" "$PREFIX"
mkdir -p "$SB" "$PREFIX"
git -C "$ROOT" archive fc0f99e bin | tar -x -C "$PREFIX"
echo "worktree under test: $ROOT"
echo "target commit: $(git -C "$ROOT" rev-parse HEAD)"
echo "pre-fix bin:   fc0f99e (parent) extracted at $PREFIX/bin"

cmd() { printf '\n$ %s\n' "$*"; "$@"; }
note() { printf '\n--- %s ---\n' "$*"; }

# ---------------------------------------------------------------------------
# world builders
# ---------------------------------------------------------------------------

# build_world <dir> <binpath>: origin with main (C0) and a durable seibert/main
# fork line (C1 line-own commit, then C2 pushed to origin); home clone on
# seibert/main at C1 (0 commits behind origin/main, 1 behind origin/seibert/main).
build_world() {
  local w=$1 binpath=$2
  mkdir -p "$w"
  git init -q "$w/work"
  git -C "$w/work" symbolic-ref HEAD refs/heads/main
  printf '/bin\n/projects/\n/state/\n/data/\n/config/\n' > "$w/work/.gitignore"
  printf 'v0\n' > "$w/work/file.txt"
  git -C "$w/work" add -A
  git -C "$w/work" commit -qm C0
  git clone -q --bare "$w/work" "$w/origin.git"
  local ra
  ra=$(cd "$w/origin.git" && pwd)
  git -C "$w/work" remote add origin "file://$ra"
  git -C "$w/work" push -q -u origin main
  git -C "$w/work" checkout -q -b seibert/main
  printf 'fork line own commit\n' > "$w/work/line.txt"
  git -C "$w/work" add line.txt
  git -C "$w/work" commit -qm "C1 fork line own commit"
  git -C "$w/work" push -q -u origin seibert/main
  git clone -q "file://$ra" "$w/home"
  git -C "$w/home" checkout -q seibert/main
  ln -s "$binpath" "$w/home/bin"
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config" "$w/home/projects"
  touch "$w/home/state/.last-watcher-beat"
  git -C "$w/work" checkout -q seibert/main
  printf 'v2\n' > "$w/work/file.txt"
  git -C "$w/work" add file.txt
  git -C "$w/work" commit -qm "C2 fork line advance"
  git -C "$w/work" push -q origin seibert/main
  git -C "$w/home" fetch -q origin
  printf '%s\n' "$w/home"
}

# ===========================================================================
echo
echo "########################################################################"
echo "# A. fleet sync of the primary checkout on the seibert/main fork line"
echo "#    (the exact call shape fm-teardown.sh's post-sync makes: script from"
echo "#     the home's own bin/, the home as the project argument, no overrides)"
echo "########################################################################"
A=$(build_world "$SB/a" "$ROOT/bin")
A_HEAD=$(git -C "$A" rev-parse HEAD)
A_BRANCH=$(git -C "$A" symbolic-ref --short HEAD)
note "before: branch=$A_BRANCH head=$(git -C "$A" rev-parse --short HEAD) behind_origin_main=$(git -C "$A" rev-list --count HEAD..origin/main) behind_origin_seibert_main=$(git -C "$A" rev-list --count HEAD..origin/seibert/main)"
cmd env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_PROJECTS_OVERRIDE "$A/bin/fm-fleet-sync.sh" "$A"
note "after"
echo "branch: $(git -C "$A" symbolic-ref --short HEAD) (before $A_BRANCH)"
echo "HEAD moved: $([ "$(git -C "$A" rev-parse HEAD)" = "$A_HEAD" ] && echo no || echo YES)"
echo "working tree: [$(git -C "$A" status --porcelain)]"
echo "origin/seibert/main refreshed by the fetch to: $(git -C "$A" rev-parse --short origin/seibert/main)"

echo
echo "########################################################################"
echo "# B. same drive on the PRE-FIX tree: the exact reported false alarm"
echo "########################################################################"
B=$(build_world "$SB/b" "$PREFIX/bin")
B_HEAD=$(git -C "$B" rev-parse HEAD)
note "before: branch=$(git -C "$B" symbolic-ref --short HEAD) head=$(git -C "$B" rev-parse --short HEAD) behind_origin_main=$(git -C "$B" rev-list --count HEAD..origin/main)"
cmd env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_PROJECTS_OVERRIDE "$B/bin/fm-fleet-sync.sh" "$B"
echo "HEAD moved: $([ "$(git -C "$B" rev-parse HEAD)" = "$B_HEAD" ] && echo no || echo YES)"
echo "reported Anlass line reproduced:"
grep -F "STUCK: on branch seibert/main, 0 commits behind origin/main - needs attention" \
  <(env -u FM_HOME -u FM_ROOT_OVERRIDE "$B/bin/fm-fleet-sync.sh" "$B") >/dev/null && echo MATCH || echo NO-MATCH

echo
echo "########################################################################"
echo "# C. scope guard: a project clone under projects/ on a branch named"
echo "#    seibert/main must still STUCK and stay untouched"
echo "########################################################################"
C="$SB/c"
F=$(build_world "$C" "$ROOT/bin")
# separate origin for the foreign clone: main (f0) + a seibert/main branch (f1),
# with origin/main advanced (f2) so the STUCK is quantified.
mkdir -p "$C/foreign"
git init -q "$C/fw"
git -C "$C/fw" symbolic-ref HEAD refs/heads/main
printf 'f0\n' > "$C/fw/f.txt"
git -C "$C/fw" add -A
git -C "$C/fw" commit -qm f0
git clone -q --bare "$C/fw" "$C/foreign.git"
FA=$(cd "$C/foreign.git" && pwd)
git -C "$C/fw" remote add origin "file://$FA"
git -C "$C/fw" push -q -u origin main
git -C "$C/fw" checkout -q -b seibert/main
printf 'f1\n' > "$C/fw/line.txt"
git -C "$C/fw" add -A
git -C "$C/fw" commit -qm "f1 seibert/main branch commit"
git -C "$C/fw" push -q -u origin seibert/main
git -C "$C/fw" checkout -q main
printf 'f2\n' > "$C/fw/f.txt"
git -C "$C/fw" add -A
git -C "$C/fw" commit -qm "f2 main advance"
git -C "$C/fw" push -q origin main
git clone -q "file://$FA" "$F/projects/foreign"
git -C "$F/projects/foreign" checkout -q seibert/main
CF_HEAD=$(git -C "$F/projects/foreign" rev-parse HEAD)
cmd env -u FM_HOME -u FM_ROOT_OVERRIDE "$F/bin/fm-fleet-sync.sh" projects/foreign
cmd env -u FM_HOME -u FM_ROOT_OVERRIDE "$F/bin/fm-fleet-sync.sh"
echo "foreign clone branch: $(git -C "$F/projects/foreign" symbolic-ref --short HEAD)"
echo "foreign clone moved: $([ "$(git -C "$F/projects/foreign" rev-parse HEAD)" = "$CF_HEAD" ] && echo no || echo YES)"

echo
echo "########################################################################"
echo "# D. adversarial: a DIRTY primary on seibert/main still STUCKs and keeps"
echo "#    the uncommitted work (the allowance must not swallow the dirty case)"
echo "########################################################################"
D=$(build_world "$SB/d" "$ROOT/bin")
printf 'uncommitted captain edit\n' >> "$D/file.txt"
D_HEAD=$(git -C "$D" rev-parse HEAD)
cmd env -u FM_HOME -u FM_ROOT_OVERRIDE "$D/bin/fm-fleet-sync.sh" "$D"
echo "HEAD moved: $([ "$(git -C "$D" rev-parse HEAD)" = "$D_HEAD" ] && echo no || echo YES)"
echo "edit preserved: $(grep -c 'uncommitted captain edit' "$D/file.txt") occurrence(s)"

echo
echo "########################################################################"
echo "# E. the benign path keeps the home's refresh work: fetch + branch pruning"
echo "########################################################################"
E=$(build_world "$SB/e" "$ROOT/bin")
# a local branch whose upstream is gone (pushed then deleted on origin)
git -C "$SB/e/work" checkout -q -b feature
printf 'feature\n' > "$SB/e/work/feature.txt"
git -C "$SB/e/work" add feature.txt
git -C "$SB/e/work" commit -qm "feature work"
git -C "$SB/e/work" push -q origin feature
git -C "$SB/e/work" push -q origin --delete feature
git -C "$SB/e/work" checkout -q seibert/main
git -C "$E" branch -q feature HEAD
git -C "$E" config branch.feature.remote origin
git -C "$E" config branch.feature.merge refs/heads/feature
E_HEAD=$(git -C "$E" rev-parse HEAD)
note "branches before: [$(git -C "$E" branch --format='%(refname:short)' | tr '\n' ' ')]"
cmd env -u FM_HOME -u FM_ROOT_OVERRIDE "$E/bin/fm-fleet-sync.sh" "$E"
note "branches after: [$(git -C "$E" branch --format='%(refname:short)' | tr '\n' ' ')]"
echo "HEAD moved: $([ "$(git -C "$E" rev-parse HEAD)" = "$E_HEAD" ] && echo no || echo YES)"

echo
echo "########################################################################"
echo "# F. adversarial: a symlinked home path still gets the benign report"
echo "########################################################################"
ln -sfn "$A" "$SB/link-home"
note "6a: script and project arg both through the symlink"
cmd env -u FM_HOME -u FM_ROOT_OVERRIDE "$SB/link-home/bin/fm-fleet-sync.sh" "$SB/link-home"
note "6b: script via physical home, project arg via symlink"
cmd env -u FM_HOME -u FM_ROOT_OVERRIDE "$A/bin/fm-fleet-sync.sh" "$SB/link-home"
note "6c: script via symlink, project arg via physical home"
cmd env -u FM_HOME -u FM_ROOT_OVERRIDE "$SB/link-home/bin/fm-fleet-sync.sh" "$A"

echo
echo "########################################################################"
echo "# G. no regression: ordinary project clones still fast-forward / report"
echo "#    current, while the foreign seibert/main clone still STUCKs"
echo "########################################################################"
G="$SB/g"
GH=$(build_world "$G" "$ROOT/bin")
mkdir -p "$G/ab"
git init -q "$G/abw"
git -C "$G/abw" symbolic-ref HEAD refs/heads/main
printf 'a0\n' > "$G/abw/a.txt"
git -C "$G/abw" add -A
git -C "$G/abw" commit -qm a0
git clone -q --bare "$G/abw" "$G/ab.git"
GA=$(cd "$G/ab.git" && pwd)
git -C "$G/abw" remote add origin "file://$GA"
git -C "$G/abw" push -q -u origin main
git clone -q "file://$GA" "$GH/projects/alpha"
git clone -q "file://$GA" "$GH/projects/beta"
printf 'a1\n' > "$G/abw/a.txt"
git -C "$G/abw" add -A
git -C "$G/abw" commit -qm a1
git -C "$G/abw" push -q origin main
git clone -q "$FA" "$GH/projects/foreign"
git -C "$GH/projects/foreign" checkout -q seibert/main
note "before: alpha=$(git -C "$GH/projects/alpha" rev-parse --short HEAD) origin/main=$(git -C "$GH/projects/alpha" rev-parse --short origin/main)"
cmd env -u FM_HOME -u FM_ROOT_OVERRIDE "$GH/bin/fm-fleet-sync.sh"
echo "alpha after: head=$(git -C "$GH/projects/alpha" rev-parse --short HEAD) origin/main=$(git -C "$GH/projects/alpha" rev-parse --short origin/main) branch=$(git -C "$GH/projects/alpha" symbolic-ref --short HEAD)"

echo
echo "########################################################################"
echo "# H. self-sync (fm-update.sh) on a mirror-less primary on seibert/main"
echo "########################################################################"
H="$SB/h"
mkdir -p "$H"
# dedicated origin: main u0; seibert/main u1 (line own) + u2 (remote advance)
git init -q "$H/work"
git -C "$H/work" symbolic-ref HEAD refs/heads/main
printf 'base\n' > "$H/work/base.txt"
git -C "$H/work" add -A
git -C "$H/work" commit -qm u0
git clone -q --bare "$H/work" "$H/origin.git"
HA=$(cd "$H/origin.git" && pwd)
git -C "$H/work" remote add origin "file://$HA"
git -C "$H/work" push -q -u origin main
git -C "$H/work" checkout -q -b seibert/main
printf 'line own\n' > "$H/work/LINE.md"
git -C "$H/work" add -A
git -C "$H/work" commit -qm "u1 line own"
git -C "$H/work" push -q -u origin seibert/main
printf 'line remote\n' > "$H/work/LINE-REMOTE.md"
git -C "$H/work" add -A
git -C "$H/work" commit -qm "u2 line remote advance"
git -C "$H/work" push -q origin seibert/main
U0=$(git -C "$H/origin.git" rev-parse main)
U1=$(git -C "$H/origin.git" rev-parse seibert/main~1)
git clone -q "file://$HA" "$H/home"
git -C "$H/home" checkout -q seibert/main
git -C "$H/home" reset -q --hard "$U1"
git -C "$H/home" branch -D main >/dev/null
ln -s "$ROOT/bin" "$H/home/bin"
printf 'bin\nstate\ndata\nconfig\nprojects\n' >> "$H/home/.git/info/exclude"
mkdir -p "$H/home/state" "$H/home/data" "$H/home/config" "$H/home/projects"
touch "$H/home/state/.last-watcher-beat"
git -C "$H/home" fetch -q origin
H_HEAD=$(git -C "$H/home" rev-parse HEAD)
note "before: branch=$(git -C "$H/home" symbolic-ref --short HEAD) head=$(git -C "$H/home" rev-parse --short HEAD) local-main=$(git -C "$H/home" rev-parse --verify -q main || echo ABSENT)"
cmd env -u FM_HOME -u FM_ROOT_OVERRIDE "$H/home/bin/fm-update.sh"
note "after"
echo "branch: $(git -C "$H/home" symbolic-ref --short HEAD)"
echo "HEAD moved: $([ "$(git -C "$H/home" rev-parse HEAD)" = "$H_HEAD" ] && echo no || echo YES) (to origin/seibert/main: $(git -C "$H/home" rev-parse --short HEAD))"
echo "local main mirror: $(git -C "$H/home" rev-parse --short main 2>/dev/null || echo ABSENT) parents=$(git -C "$H/home" rev-list --parents -n1 main 2>/dev/null | wc -w)"
cmd env -u FM_HOME -u FM_ROOT_OVERRIDE "$H/home/bin/fm-update.sh"

echo
echo "########################################################################"
echo "# I. self-sync with a stale clean main mirror and moved upstream main:"
echo "#    the mirror advances ref-only and merges into the line"
echo "########################################################################"
I="$SB/i"
mkdir -p "$I"
cp -a "$H/work" "$I/work"
cp -a "$H/origin.git" "$I/origin.git"
IA=$(cd "$I/origin.git" && pwd)
git -C "$I/work" remote set-url origin "file://$IA"
# advance upstream main AFTER the line commits, so a mirror merge is required
git -C "$I/work" checkout -q main
printf 'upstream\n' > "$I/work/upstream.txt"
git -C "$I/work" add -A
git -C "$I/work" commit -qm "u3 upstream main advance"
git -C "$I/work" push -q origin main
git -C "$I/work" checkout -q seibert/main
I0=$(git -C "$I/origin.git" rev-parse main~1)
I1=$(git -C "$I/origin.git" rev-parse seibert/main~1)
git clone -q "file://$IA" "$I/home"
git -C "$I/home" checkout -q seibert/main
git -C "$I/home" reset -q --hard "$I1"
git -C "$I/home" branch -f main "$I0"
ln -s "$ROOT/bin" "$I/home/bin"
printf 'bin\nstate\ndata\nconfig\nprojects\n' >> "$I/home/.git/info/exclude"
mkdir -p "$I/home/state" "$I/home/data" "$I/home/config" "$I/home/projects"
touch "$I/home/state/.last-watcher-beat"
git -C "$I/home" fetch -q origin
I_HEAD=$(git -C "$I/home" rev-parse HEAD)
note "before: branch=$(git -C "$I/home" symbolic-ref --short HEAD) head=$(git -C "$I/home" rev-parse --short HEAD) local-main=$(git -C "$I/home" rev-parse --short main) origin/main=$(git -C "$I/home" rev-parse --short origin/main)"
cmd env -u FM_HOME -u FM_ROOT_OVERRIDE "$I/home/bin/fm-update.sh"
note "after"
echo "branch: $(git -C "$I/home" symbolic-ref --short HEAD) (must stay seibert/main)"
echo "HEAD moved: $([ "$(git -C "$I/home" rev-parse HEAD)" = "$I_HEAD" ] && echo no || echo YES)"
echo "local main mirror: $(git -C "$I/home" rev-parse --short main) wordcount=$(git -C "$I/home" rev-list --parents -n1 main | wc -w) (2 = single parent, ref-only advance)"
echo "line tip wordcount: $(git -C "$I/home" rev-list --parents -n1 HEAD | wc -w) (3 = two parents, merge)"
echo "line contains origin/main: $(git -C "$I/home" merge-base --is-ancestor origin/main HEAD && echo yes || echo no)"
echo "line contains origin/seibert/main: $(git -C "$I/home" merge-base --is-ancestor origin/seibert/main HEAD && echo yes || echo no)"
echo "line-own commit survived: $(git -C "$I/home" merge-base --is-ancestor "$I1" HEAD && echo yes || echo no)"
cmd env -u FM_HOME -u FM_ROOT_OVERRIDE "$I/home/bin/fm-update.sh"

echo
echo "########################################################################"
echo "# J. adversarial: a self-modified main mirror keeps the fork line"
echo "#    untouched (skip, never force)"
echo "########################################################################"
J="$SB/j"
mkdir -p "$J"
cp -a "$H/work" "$J/work"
cp -a "$H/origin.git" "$J/origin.git"
JA=$(cd "$J/origin.git" && pwd)
git -C "$J/work" remote set-url origin "file://$JA"
J1=$(git -C "$J/origin.git" rev-parse seibert/main~1)
git clone -q "file://$JA" "$J/home"
git -C "$J/home" checkout -q seibert/main
git -C "$J/home" reset -q --hard "$J1"
git -C "$J/home" branch -f main "$J1"   # mirror self-modified onto the line's own commit
ln -s "$ROOT/bin" "$J/home/bin"
printf 'bin\nstate\ndata\nconfig\nprojects\n' >> "$J/home/.git/info/exclude"
mkdir -p "$J/home/state" "$J/home/data" "$J/home/config" "$J/home/projects"
touch "$J/home/state/.last-watcher-beat"
git -C "$J/home" fetch -q origin
J_HEAD=$(git -C "$J/home" rev-parse HEAD)
note "before: branch=$(git -C "$J/home" symbolic-ref --short HEAD) head=$(git -C "$J/home" rev-parse --short HEAD) local-main=$(git -C "$J/home" rev-parse --short main) origin/main=$(git -C "$J/home" rev-parse --short origin/main)"
cmd env -u FM_HOME -u FM_ROOT_OVERRIDE "$J/home/bin/fm-update.sh"
echo "branch: $(git -C "$J/home" symbolic-ref --short HEAD) HEAD moved: $([ "$(git -C "$J/home" rev-parse HEAD)" = "$J_HEAD" ] && echo no || echo YES)"

echo
echo "########################################################################"
echo "# K. end-to-end teardown of a firstmate-repo task (the reported Anlass):"
echo "#    fm-teardown.sh post-sync on the home, post-fix tree"
echo "########################################################################"
teardown_case() { # <case> <binpath> ; echoes case dir
  local case=$1 binpath=$2
  mkdir -p "$case/state" "$case/config" "$case/data" "$case/fakebin"
  cat > "$case/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$case/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$case/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  axi) shift; case "${1:-}" in status|abort) exit 0 ;; esac ;;
  runs) exit 0 ;;
esac
exit 0
SH
  chmod +x "$case/fakebin/"*
  git init -q --bare "$case/origin.git"
  git -C "$case/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case/origin.git" "$case/_seed" 2>/dev/null
  git -C "$case/_seed" commit -q --allow-empty -m "origin baseline"
  git -C "$case/_seed" push -q origin main
  rm -rf "$case/_seed"
  git clone -q "$case/origin.git" "$case/home"
  git -C "$case/home" checkout -q -b seibert/main
  printf 'fork line commit\n' > "$case/home/LINE.md"
  git -C "$case/home" add LINE.md
  git -C "$case/home" commit -qm "fork line own commit"
  git -C "$case/home" push -q -u origin seibert/main
  ln -s "$binpath" "$case/home/bin"
  printf 'bin\nprojects/\n' >> "$case/home/.git/info/exclude"
  mkdir -p "$case/home/projects"
  touch "$case/state/.last-watcher-beat"
  git -C "$case/home" worktree add -q -b fm/task-x1 "$case/wt" seibert/main
  printf 'shippable work\n' > "$case/wt/feature.txt"
  git -C "$case/wt" add feature.txt
  git -C "$case/wt" commit -qm "shippable work"
  git -C "$case/wt" push -q origin fm/task-x1
  git -C "$case/home" fetch -q origin
  {
    printf 'window=firstmate:fm-task-x1\n'
    printf 'endpoint_task_id=task-x1\n'
    printf 'worktree=%s/wt\n' "$case"
    printf 'project=%s/home\n' "$case"
    printf 'kind=ship\n'
    printf 'mode=no-mistakes\n'
    printf 'spawn_gen=teardown-e2e-task-x1\n'
  } > "$case/state/task-x1.meta"
  # advance origin/seibert/main, as in the report
  git clone -q "$case/origin.git" "$case/line-seed"
  git -C "$case/line-seed" checkout -q -B seibert/main origin/seibert/main
  printf 'line remote\n' > "$case/line-seed/LINE-REMOTE.md"
  git -C "$case/line-seed" add -A
  git -C "$case/line-seed" commit -qm "fork line remote advance"
  git -C "$case/line-seed" push -q origin seibert/main
}

KC="$SB/teardown-post"
teardown_case "$KC" "$ROOT/bin"
K_HEAD=$(git -C "$KC/home" rev-parse HEAD)
note "before teardown: branch=$(git -C "$KC/home" symbolic-ref --short HEAD) head=$(git -C "$KC/home" rev-parse --short HEAD) behind_origin_main=$(git -C "$KC/home" rev-list --count HEAD..origin/main)"
printf '\n$ FM_ROOT_OVERRIDE=%s/home ... %s/home/bin/fm-teardown.sh task-x1\n' "$KC" "$KC"
env FM_ROOT_OVERRIDE="$KC/home" FM_STATE_OVERRIDE="$KC/state" FM_DATA_OVERRIDE="$KC/data" \
  FM_CONFIG_OVERRIDE="$KC/config" FM_GATE_REFUSE_BYPASS=1 PATH="$KC/fakebin:$PATH" \
  "$KC/home/bin/fm-teardown.sh" task-x1 > "$SB/teardown-post.out" 2> "$SB/teardown-post.err"
echo "teardown exit=$?"
echo "--- teardown stdout ---"
cat "$SB/teardown-post.out"
echo "--- teardown post state ---"
echo "branch: $(git -C "$KC/home" symbolic-ref --short HEAD) (must stay seibert/main)"
echo "HEAD moved: $([ "$(git -C "$KC/home" rev-parse HEAD)" = "$K_HEAD" ] && echo no || echo YES)"
echo "STUCK lines in teardown output: $(grep -c STUCK "$SB/teardown-post.out")"

echo
echo "########################################################################"
echo "# L. same end-to-end teardown on the PRE-FIX tree: the reported alarm"
echo "########################################################################"
LC="$SB/teardown-prefix"
teardown_case "$LC" "$PREFIX/bin"
L_HEAD=$(git -C "$LC/home" rev-parse HEAD)
note "before teardown: branch=$(git -C "$LC/home" symbolic-ref --short HEAD) behind_origin_main=$(git -C "$LC/home" rev-list --count HEAD..origin/main)"
printf '\n$ FM_ROOT_OVERRIDE=%s/home ... %s/home/bin/fm-teardown.sh task-x1\n' "$LC" "$LC"
env FM_ROOT_OVERRIDE="$LC/home" FM_STATE_OVERRIDE="$LC/state" FM_DATA_OVERRIDE="$LC/data" \
  FM_CONFIG_OVERRIDE="$LC/config" FM_GATE_REFUSE_BYPASS=1 PATH="$LC/fakebin:$PATH" \
  "$LC/home/bin/fm-teardown.sh" task-x1 > "$SB/teardown-prefix.out" 2> "$SB/teardown-prefix.err"
echo "teardown exit=$?"
echo "--- teardown stdout ---"
cat "$SB/teardown-prefix.out"
echo "STUCK lines in teardown output: $(grep -c STUCK "$SB/teardown-prefix.out")"
echo "HEAD moved: $([ "$(git -C "$LC/home" rev-parse HEAD)" = "$L_HEAD" ] && echo no || echo YES)"

echo
echo "done"
