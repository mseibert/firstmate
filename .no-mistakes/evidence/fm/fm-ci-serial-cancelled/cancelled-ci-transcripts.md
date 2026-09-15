# fm-verdict-wait.sh end-to-end transcripts: cancelled checks on both forges

Generated against the target commit 79bfa49 of fm/fm-ci-serial-cancelled.

## GitHub (gh pr checks buckets)

### G1 cancelled check alone: not red, not green (exit 1, waits)
$ fm-verdict-wait.sh https://github.com/example/repo/pull/42 --timeout 0
[exit 1]
fm-verdict-wait.sh: 0s: waiting: verdict fresh ("Good to merge"); ci pending
timeout: no fresh verdict (single read): ci not green (state=pending) with a fresh verdict "Good to merge" at 2026-09-09T11:05:00Z; ci pending

### G2 cancelled check beside a real failure: still red (exit 4)
$ fm-verdict-wait.sh https://github.com/example/repo/pull/42 --timeout 0
[exit 4]
action-required: ci red on head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb (2026-09-09T10:03:44Z); verdict "Good to merge" at 2026-09-09T11:05:00Z is fresh

## Forgejo (combined commit status state=failure, the normal path)

### F1 combined failure + cancelled run, no real failure: not red, not green (exit 1, waits)
$ fm-verdict-wait.sh https://forgejo.example.test/group/project/pulls/186 --timeout 0
[exit 1]
fm-verdict-wait.sh: 0s: waiting: verdict fresh ("Good to merge (LGTM)."); ci pending
timeout: no fresh verdict (single read): ci not green (state=pending) with a fresh verdict "Good to merge (LGTM)." at 2026-09-09T10:45:53Z; ci pending

### F2 combined failure + cancelled run beside a real failing run: still red (exit 4)
$ fm-verdict-wait.sh https://forgejo.example.test/group/project/pulls/186 --timeout 0
[exit 4]
action-required: ci red on head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (2026-09-09T12:03:44+02:00); verdict "Good to merge (LGTM)." at 2026-09-09T10:45:53Z is fresh

### F3 combined failure that no workflow run explains: stays red (exit 4)
$ fm-verdict-wait.sh https://forgejo.example.test/group/project/pulls/186 --timeout 0
[exit 4]
action-required: ci red on head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (2026-09-09T12:03:44+02:00); verdict "Good to merge (LGTM)." at 2026-09-09T10:45:53Z is fresh

### F4 combined failure whose workflow runs are unreadable: stays red (exit 4)
$ fm-verdict-wait.sh https://forgejo.example.test/group/project/pulls/186 --timeout 0
[exit 4]
action-required: ci red on head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (2026-09-09T12:03:44+02:00); verdict "Good to merge (LGTM)." at 2026-09-09T10:45:53Z is fresh

## Forgejo fallback path (no commit status at all)

### F5 no commit status + cancelled run: not red, not green (exit 1, waits)
$ fm-verdict-wait.sh https://forgejo.example.test/group/project/pulls/186 --timeout 0
[exit 1]
fm-verdict-wait.sh: 0s: waiting: verdict fresh ("Good to merge (LGTM)."); ci pending
timeout: no fresh verdict (single read): ci not green (state=pending) with a fresh verdict "Good to merge (LGTM)." at 2026-09-09T10:45:53Z; ci pending


## Bounded wait: the cancelled head keeps waiting for a re-run (real sleep)

$ fm-verdict-wait.sh https://github.com/example/repo/pull/42 --timeout 3 --interval 1
[exit 1]
fm-verdict-wait.sh: 0s: waiting: verdict fresh ("Good to merge"); ci pending
fm-verdict-wait.sh: 1s: waiting: verdict fresh ("Good to merge"); ci pending
fm-verdict-wait.sh: 2s: waiting: verdict fresh ("Good to merge"); ci pending
fm-verdict-wait.sh: 3s: waiting: verdict fresh ("Good to merge"); ci pending
timeout: no fresh verdict after 3s: ci not green (state=pending) with a fresh verdict "Good to merge" at 2026-09-09T11:05:00Z; ci pending

## Live read-only check against the real PR #21 (2026-09-15)

The cancelled job from the intent evidence is still on the PR head:

```
pass	SUCCESS	Behavior timing aggregate
cancel	CANCELLED	Behavior portable serial 4
pass	SUCCESS	Stock macOS Bash snapshot compatibility
pass	SUCCESS	Behavior portable serial 3
pass	SUCCESS	Behavior portable serial 1
pass	SUCCESS	Behavior portable serial 2
pass	SUCCESS	Lint
pass	SUCCESS	Behavior portable parallel 2
pass	SUCCESS	Behavior portable serial 5
pass	SUCCESS	Behavior portable parallel 1
pass	SUCCESS	Repo invariants
pass	SUCCESS	Test coverage guard
pass	SUCCESS	Behavior tests (Herdr)
```

$ bin/fm-verdict-wait.sh https://github.com/mseibert/firstmate/pull/21 --timeout 0
[exit 1]
fm-verdict-wait.sh: 0s: waiting: no verdict yet; ci pending
timeout: no fresh verdict (single read): no verdict found (no seibert-pr-agent comment with a **Verdict:** line); ci pending

The helper does not exit 4 ("action-required: ci red") while the cancelled check is present; the cancelled bucket is held as ci pending.

### Before the fix, same real PR (bin/fm-verdict-wait.sh at 7d4194f)

$ bin/fm-verdict-wait.sh https://github.com/mseibert/firstmate/pull/21 --timeout 0
[exit 4]
action-required: ci red on head 716704a73585c235a108950e94e7c14c32038a1c (2026-09-14T18:44:48Z); no fresh verdict

The pre-fix reader exits 4 ("action-required: ci red") on the same head that now reads ci pending.
