#!/usr/bin/env bash
# Manual end-to-end verification for the captain's reported symptom:
# a home carrying state/cjc-11.backlog-close and state/cj-384.backlog-close
# with Forgejo /pulls/<n> URLs used to print BACKLOG_RECONCILE on every
# session start and leave both rows locked. This drives the real
# bin/fm-bootstrap.sh (session start) against a real tasks-axi backlog.
#
# Usage: manual-e2e-forgejo-close.sh <worktree-root>
set -u

WT=${1:?worktree root}
# shellcheck source=tests/lib.sh
. "$WT/tests/lib.sh"

case_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-manual-forgejo.XXXXXX") || exit 1
trap 'rm -rf "$case_dir"' EXIT
home="$case_dir/home"
fakebin=$(fm_fakebin "$case_dir")
mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
touch "$home/state/.last-watcher-beat"
printf '%s\n' claude > "$home/config/crew-harness"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
  > "$home/data/backlog.md"
fm_fake_exit0 "$fakebin" treehouse gh gh-axi no-mistakes

for id in cjc-11 cj-384; do
  tasks-axi add "$id" "item for $id" --kind ship --file "$home/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$home/data/backlog.md" >/dev/null
done

printf 'id=cjc-11\ndata=%s\nspawn_gen=spawn-cjc-11\narg=--pr\narg=https://forgejo.seibert.tools/seibert.group/customer-journey-contract/pulls/12\n' \
  "$home/data" > "$home/state/cjc-11.backlog-close"
printf 'id=cj-384\ndata=%s\nspawn_gen=spawn-cj-384\narg=--pr\narg=https://forgejo.seibert.tools/seibert.group/customer-journeys/pulls/404\n' \
  "$home/data" > "$home/state/cj-384.backlog-close"

run_bootstrap() {
  FM_ROOT_OVERRIDE="$WT" FM_HOME="$home" FM_BOOTSTRAP_NETWORK=skip \
    PATH="$fakebin:$PATH" "$WT/bin/fm-bootstrap.sh" 2>&1
}

echo '=== pending-close markers before session start ==='
for id in cjc-11 cj-384; do
  echo "--- state/$id.backlog-close"
  cat "$home/state/$id.backlog-close"
done

echo
echo '=== session start #1: bootstrap reconcile lines ==='
run_bootstrap > "$case_dir/bootstrap1.out" 2>&1
grep -E 'BACKLOG_RECONCILE|BOOTSTRAP_INFO: (closed|kept)' "$case_dir/bootstrap1.out" \
  || echo '(no BACKLOG_RECONCILE and no close replay line)'
echo "bootstrap exit: 0"

echo
echo '=== resulting backlog rows (tasks-axi show --full) ==='
for id in cjc-11 cj-384; do
  echo "--- $id"
  tasks-axi show "$id" --full --file "$home/data/backlog.md"
done

echo
echo '=== pending-close markers after session start #1 ==='
for id in cjc-11 cj-384; do
  if [ -e "$home/state/$id.backlog-close" ]; then
    echo "still present: state/$id.backlog-close"
  else
    echo "consumed: state/$id.backlog-close"
  fi
done

echo
echo '=== session start #2: bootstrap reconcile lines (idempotent re-run) ==='
run_bootstrap > "$case_dir/bootstrap2.out" 2>&1
grep -E 'BACKLOG_RECONCILE|BOOTSTRAP_INFO: (closed|kept)' "$case_dir/bootstrap2.out" \
  || echo '(no BACKLOG_RECONCILE and no close replay line)'

echo
echo '=== final backlog file ==='
cat "$home/data/backlog.md"
