# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current candidate timings came from the 2026-08-20 concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The proof ran 24 candidates with four workers and no failures.

| duration_ms | script |
|---:|---|
| 45356 | `tests/fm-backend-herdr.test.sh` |
| 35415 | `tests/fm-x-mode.test.sh` |
| 35095 | `tests/fm-captain-hold-lifecycle.test.sh` |
| 27529 | `tests/fm-arm-pretool-check.test.sh` |
| 20922 | `tests/fm-test-run.test.sh` |
| 17558 | `tests/fm-crew-state.test.sh` |
| 16582 | `tests/fm-cd-pretool-check.test.sh` |
| 9766 | `tests/fm-lint.test.sh` |
| 9562 | `tests/fm-herdr-lab.test.sh` |
| 6768 | `tests/fm-grok-harness.test.sh` |
| 6290 | `tests/fm-pr-merge.test.sh` |
| 5569 | `tests/fm-composer-ghost.test.sh` |
| 4563 | `tests/fm-send-popup-settle.test.sh` |
| 4021 | `tests/fm-tmux-submit-busy.test.sh` |
| 3544 | `tests/fm-composer-lib.test.sh` |
| 3025 | `tests/fm-send-strict.test.sh` |
| 2753 | `tests/fm-send-settle.test.sh` |
| 2166 | `tests/fm-review-diff.test.sh` |
| 1315 | `tests/fm-brief.test.sh` |
| 975 | `tests/fm-spawn-batch.test.sh` |
| 598 | `tests/fm-pi-primary-types.test.sh` |
| 513 | `tests/fm-ensure-agents-md.test.sh` |
| 331 | `tests/fm-supervision-instructions.test.sh` |
| 99 | `tests/fm-transition-lib.test.sh` |

## Parallel lanes

The two parallel lanes use longest-processing-time assignment from those measured durations.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 134295 ms (~134.3 s) |
| `portable-parallel-2` | 13 | 126020 ms (~126.0 s) |
| imbalance | | 8275 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
The 159 current hints include the slowest measurements retained from the `fm-test-timing-portable-serial-*` artifacts of eight green CI runs on 2026-09-13/14: [34885988388](https://github.com/mseibert/firstmate/actions/runs/34885988388), [34874114551](https://github.com/mseibert/firstmate/actions/runs/34874114551), [34874093783](https://github.com/mseibert/firstmate/actions/runs/34874093783), [34874080148](https://github.com/mseibert/firstmate/actions/runs/34874080148), [34812566654](https://github.com/mseibert/firstmate/actions/runs/34812566654), and [34759444930](https://github.com/mseibert/firstmate/actions/runs/34759444930) on `seibert/main`, plus [34838500046](https://github.com/mseibert/firstmate/actions/runs/34838500046) and [34787351600](https://github.com/mseibert/firstmate/actions/runs/34787351600) on the fork's pull-request line, plus the 5121 ms native-Windows focused runner measurement for `tests/fm-pi-windows-shell-invocation.test.sh` from 2026-09-06T21:02Z.
Those per-script maxima total 4929143 ms of conservative balance weight.
The two `fm-self-update-timer` scripts added on 2026-09-15 carry the slowest of three local green runs until the next CI refresh.
Taking the slowest of several CI runs rather than a single run keeps the balance honest on a slow runner: individual scripts varied by up to 20% between runs.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default; the current 161-script lane has two such scripts, bringing its assignment weight to 4983143 ms.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
That is not hypothetical: by 2026-09-01 the lane had grown from 116 to 139 scripts and from ~42 to ~63 minutes, 17 scripts were still unmeasured, and several hints were low by 2-5x, so shard 3 of 4 ran 17-20 minutes against its 20-minute cap while shard 1 ran 11.5 minutes and run [33574154856](https://github.com/kunchenguid/firstmate/actions/runs/33574154856) timed out seconds after a passing test.
The 2026-09-14 refresh above came from the same drift one lane generation later, and shows what the symptom looks like from outside: `portable-serial-4of5` still carried a 14.00-minute hint while its measured scripts averaged 16.69 minutes and peaked at 19.88 minutes, so it reached the 20-minute job cap on four runs in 24 hours and the run concluded `cancelled` - which `gh pr checks` renders as `fail` and which reads as a broken check rather than a lane that outgrew its cap.
`bin/fm-test-run.sh --check-coverage` reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so hint drift fails the coverage guard instead of silently pushing one shard into its job cap, but a lane that gains scripts while every hint stays measured passes that bound while its balance rots.
Refresh the hints whenever the serial lane gains scripts, rather than waiting for that bound to trip.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of5` | 32 | 996653 ms (~16.61 min) |
| `portable-serial-2of5` | 32 | 996618 ms (~16.61 min) |
| `portable-serial-3of5` | 33 | 996618 ms (~16.61 min) |
| `portable-serial-4of5` | 31 | 996636 ms (~16.61 min) |
| `portable-serial-5of5` | 33 | 996618 ms (~16.61 min) |
| imbalance | | 35 ms |

The current table is generated from the runner's retained maxima plus its default for the two unhinted scripts.
Every shard's assignment weight is its conservative worst case, 16.61 min, which is 37% of the 45-minute job cap.

Before the refresh the same partition was balanced on hints that no longer described the lane: shard 4's hint said 14.00 min while the scripts it held measured 16.69 min on average and 19.88 min at their slowest.

| Lane | Hint before | Measured mean before | Measured worst before |
|---|---:|---:|---:|
| `portable-serial-1of5` | 14.00 min | 14.91 min | 16.09 min |
| `portable-serial-2of5` | 14.00 min | 14.95 min | 16.93 min |
| `portable-serial-3of5` | 14.00 min | 12.23 min | 13.45 min |
| `portable-serial-4of5` | 14.00 min | 16.69 min | 19.88 min |
| `portable-serial-5of5` | 14.00 min | 14.59 min | 15.70 min |

The single longest script, `tests/fm-watch-triage.test.sh` at 396105 ms, is the floor for any shard count.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs, replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`, and updating the tables above:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh run download "$run" -R mseibert/firstmate --pattern 'fm-test-timing-portable-serial-*' -D "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

A timed-out shard uploads no artifact, so pick runs where every serial shard is green or the lane's slowest scripts go unmeasured in exactly the shard that needs them most.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
It reports the unmeasured serial share as `serial_unhinted=` and refuses when that share exceeds `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so the shards stay balanced on evidence rather than on the default weight.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Lane | Bound | Rationale |
|---|---|---|
| portable parallel 1/2 | job `timeout-minutes: 10` | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial 1-5 | job `timeout-minutes: 45` | Each balanced shard carries 16.61 minutes of conservative assignment weight, and the worst shard measured so far ran 29m44s of test time in [run 34911370911](https://github.com/mseibert/firstmate/actions/runs/34911370911) on 2026-09-15 - `tests/fm-watch-triage.test.sh` alone took 22m17s against its 6m36s hint - in a job the 30-minute cap cancelled before its timing artifact finished uploading even though every test had passed. 45 minutes keeps the bound a hang tripwire with roughly 1.5x margin over the worst measured shard instead of the routine end of the lane. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finished around 7 minutes before this lane gained `fm-backend-herdr-focus-flash-e2e`, which measures about 2 minutes against a real lab locally, so the step bound is still the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. Refresh this figure from the lane's uploaded timing artifact. |

Timeouts are hang tripwires rather than expected healthy durations.
`.github/workflows/ci.yml` owns the exact numbers.

## Cancelled checks are not red CI

`bin/fm-verdict-wait.sh` is the one CI reader for both forges, and it holds a `cancelled` check or workflow run as not-passed: never red, so it cannot by itself produce the `action-required: ci red` exit, and never green, so it cannot authorize a merge.
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
