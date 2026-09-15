# Policy wording deliverable carried by the change

Source: docs/fm-test-portable-shards.md at target commit 79bfa49.

## Cancelled checks are not red CI

`bin/fm-verdict-wait.sh` is the one CI reader every worker uses on both forges, and it holds a `cancelled` check or workflow run as not-passed: never red, so it cannot by itself produce the `action-required: ci red` exit, and never green, so it cannot authorize a merge.
The bounded wait names `ci not green (state=pending)` and keeps waiting for a re-run on the current head instead.
Forgejo has no cancelled state in its combined commit status - it publishes a cancelled job as `failure` with the description `Has been cancelled` - so the reader resolves a combined `failure` against the head's workflow runs from `/actions/tasks`: a cancelled run with no real failing run holds the head as not-passed, a real failing run stays red, and a failure no workflow run explains also stays red.
That rule is the captain's `~/.claude/pr-policy.md` entry for the case; that file is captain-private and is not edited from this repo, so this copy carries the wording into the change that implements it.

### Policy wording for `~/.claude/pr-policy.md`

**Case: a `cancelled` check is not a failed check (Martin, 2026-09-15).**

> *"check = failure mit der Beschreibung 'Has been cancelled' ist kein Fehlschlag, sondern der vom naechsten Push abgeraeumte Lauf. Wer das als rote CI liest, sucht einen Bug, den es nicht gibt."*

`gh pr checks <pr>` reports a cancelled run as `fail` with the description `Has been cancelled`, and `gh pr view <pr> --json statusCheckRollup` reports the same run as `COMPLETED` / `CANCELLED`.
Neither is a failed check.
But two different causes produce that one description, and only the first is benign:

1. **Superseded by a newer push - benign.** GitHub cancels the older run of a branch when a new commit lands, so there is no result to read; read the checks of the current head instead of the stale entry.
2. **Killed by the job's own `timeout-minutes` - not a code failure, and not benign either.** GitHub reports a job that exceeded its own cap with the same `cancelled` conclusion, so `gh pr checks` renders it identically; this one means the lane outgrew its bound, and the bound or the shard balance is what needs the change.

Distinguish the two by the run's own annotation, never by the `Has been cancelled` description:

```sh
gh api repos/<owner>/<repo>/commits/<head-sha>/check-runs \
  --jq '.check_runs[] | select(.conclusion=="cancelled") | [.name, (.id|tostring)] | @tsv'
gh api repos/<owner>/<repo>/check-runs/<id>/annotations \
  --jq '.[] | select(.annotation_level=="failure") | .message'
# "The job has exceeded the maximum execution time of 20m0s"  -> case 2
# no such annotation                                          -> case 1
```

A `cancelled` check is never a clean bill of health.
Re-run the cancelled job and read the result for the current head before merging; the exemption is from reading it as a failure, not from having a green head.
