# Park-release mechanism

The rule this mechanism serves: a task that is only waiting - for a merge or for a captain decision - must not occupy the operating point.
Its slot is released, the handoff lives in the PR or report, the status log, and the backlog, and the task is resumed later as a short run.
`bin/fm-park.sh` is the single owner of that release.

The operating point's slots are live worker processes, not rows in a table: the measured incident behind this rule was three waiting tasks holding all three worker slots with nothing running.
A marker alone would leave the endpoint, its process, and its resources in place, so the release is a verified stop through the control plane, not a status edit.
The price is explicit: a resume is a fresh worker that inherits the local copy and none of the previous conversation, which is why the handoff must be durable in the PR or report, the status log, and the backlog before the stop.

The always-loaded policy is in `AGENTS.md` section 7; this document owns the deterministic mechanics, the marker schema, the trigger rules, and the resume semantics.

## Triggers

A task is parked when firstmate handles a wake that shows a worker waiting, or when the bounded sweep finds one that was missed:

- A `done:` report whose only remainder is a merge: the task has a recorded `pr=` and the crew reads `done` or `parked`.
- A documented decision wait: the status log holds an open keyed `needs-decision` or `blocked` event, or the backlog row is captain-held (`hold_kind: captain`).
- A no-mistakes run parked at an ask-user/authority gate: the canonical current-state line reads `parked` from the run step and carries the `(ask-user: authority decision)` marker, which `bin/fm-crew-state.sh` derives from the gate findings' `action` column (a finding whose action is `ask-user`) - never from the gate's own note text, which mentions ask-user on every review-step gate. The pointer is the gate's open keyed status decision.
- A run parked at any other gate is refused: a `fix_review` gate is the pipeline's own fix round, and a gate whose findings carry no `ask-user` action waits on the worker, so the worker must answer it and parking would stop the process the gate is waiting on.
  `bin/fm-crew-state.sh` never adds the authority marker to a `fix_review` gate, so even a fix-review finding with an `ask-user` action leaves that run refused.
- A run parked at an ask-user gate whose decision key is not recorded refuses rather than guessing.

The sweep (`bin/fm-park.sh sweep`) is the bounded session-start and heartbeat housekeeping pass: the locked startup child of `bin/fm-startup-network.sh` runs it after the network sweeps, and heartbeat review runs it by hand.
It is silent on success apart from a manual-backend home's owed backlog note on stderr, bounded by `FM_PARK_SWEEP_LIMIT` (default 2) and `FM_PARK_SWEEP_BUDGET_SECS` (default 20), and prints one `PARK_SWEEP:` line per release it could not complete.
It is best-effort housekeeping: the startup bound is shared with the network sweeps, so a slow startup can skip the sweep entirely, and one park attempt (a current-state read plus the control plane's stop wait) can outlive the sweep's own budget.
Nothing is lost when that happens: park is idempotent, every task stays exactly as the sweep found it, and the next session start or heartbeat sweep picks it up.

## Eligibility

`fm-park.sh park <task-id>` refuses loudly unless every condition holds:

- The task is not a persistent secondmate; an idle secondmate is healthy and is never parked.
- The crew is not actively working: `bin/fm-crew-state.sh` must not read `working`. A run parked at a gate is allowed only through the gate rules above; a running pipeline run is not.
- There is a provable handoff pointer: an open keyed decision, a captain-held backlog row, or a recorded `pr=`.
- A merge pointer additionally requires crew state `parked` or `done` and no pending gate; a gate-pending run never falls through to the merge label, and a merge handoff on any other state is refused rather than guessed.
- The per-task supervision lease allows this actor to change the task; the guard covers the whole mutation, not only the stop.

The refusal is built on the canonical current-state read, so its certainty is the reader's certainty.
When no-mistakes is unreadable, `bin/fm-crew-state.sh` falls back to the worker's own last declaration; park then relies on that declaration, exactly as the supervisor does.
A run that is actively fixing while its worker sits idle and an old keyed decision is still open can therefore be parked in that degraded window; the pipeline continues in its own checkout and the resume path reattaches the worker at its next gate.
The alternative - refusing every wait whenever the run reader is unavailable - would break the ordinary decision wait this mechanism exists for.

## What park does

1. Write `state/<id>.parked` (schema `fm-park.v1`) with `state=releasing` as the durable intent.
2. Append one status line: `<paused-verb> [key=park-<id>]: released awaiting <merge|decision> - <pointer>`, where `<paused-verb>` is the configured `FM_CLASSIFY_PAUSED_VERB` (default `paused`).
3. Record the handoff note in the task's backlog row under the same gate rules as every other lifecycle mutation: with an automatic backend and compatible tasks-axi the note is written through `tasks-axi update --body-file --archive-body`, a manual-backend home prints the exact note owed on stderr, and an automatic-backend home whose backend cannot be read is refused before the backlog mutation and before the worker is stopped.
4. Stop the worker through `bin/fm-control.sh <id> exit`, which preserves the endpoint, the worktree, the branch, and every uncommitted change, and which verifies through the backend's recovery-grade classifier that the agent actually stopped.
5. Rewrite the marker with `state=released` only after that stop is verified.

`state=releasing` means the intent is durable but the stop is not verified, so the task is not parked and its slot is not claimed free.
The status line records the intent from the moment it is written; the marker's `state` is the verified outcome, and only `released` frees the slot.
A failed or interrupted release stays at `releasing`; running `park` again restores the status line, retries the note and the stop, and commits `released`.
A `releasing` marker with a dead agent is not an expected stop, so the watcher's dead-worker rule still applies to it and surfaces the failure.
An already-released task is idempotent success with no second exit.

## Marker schema

`state/<id>.parked` is one `key=value` per line:

| Field | Meaning |
| --- | --- |
| `schema` | `fm-park.v1`; any other value is refused rather than trusted. |
| `task` | The exact task id; a marker naming another task is refused. |
| `reason` | `merge` or `decision`. |
| `pointer` | The PR URL, `key=<decision-key>`, `captain-hold`, or `captain-hold: <reason>`. |
| `branch` | The released work branch, or `-`. |
| `pr` | The recorded PR URL, or `-`. |
| `epoch` | Unix seconds at park time. |
| `incarnation` | The released worker's `spawn_gen`, or `-`. |
| `state` | `releasing` or `released`; only `released` is parked state. |

The marker is a regular file under this home's `state/`; a symlink there is refused.
`bin/fm-park-lib.sh` is the single reader, and it counts a marker only when the schema is exactly `fm-park.v1`, the `task=` names the task, and the recorded `incarnation=` is the task's current `spawn_gen`.
A marker left by an earlier incarnation - a control-plane relaunch or a recovery respawn that started a new worker outside `fm-park` - is stale: it never reads as a released slot, `fm-park.sh status` reports it as `stale` and exits 1, and a later `park` drops it before writing a fresh release.
`bin/fm-crew-state.sh` reads a live `released` marker as authoritative current state (`state: parked`, source `park-marker`), so the operating point sees the release without a second state source.
`bin/fm-fleet-snapshot.sh` projects the same read into its `occupancy` field, where `active` counts only `working` tasks and `parked` counts every task whose canonical state is `parked`.
`bin/fm-watch.sh` treats a live `released` marker as an expected-stopped worker, so a release never escalates as a dead worker ([architecture.md](architecture.md) owns that rule).
The startup digest labels the same task's endpoint `parked (released)` instead of `dead`, so a release does not match the stuck-worker trigger on the next session start.
`bin/fm-teardown.sh` removes the marker with the rest of the task record.

## Resume

`fm-park.sh resume <task-id> --reason merge|decision [--note <text>]` requires a `released` marker whose reason matches, relaunches the worker through `bin/fm-control.sh <id> relaunch --note <short note>`, and removes the marker only after the relaunch succeeds.
The relaunch reuses the same endpoint and worktree and appends the note to the task's instructions, so the resumed worker reads exactly what changed.

- `--reason merge`: the note names the merged PR and asks for a head reconciliation, a rebase or fix only if needed, and a final `done:` for cleanup.
- `--reason decision`: `--note` carries the captain's words into the task's instructions; the note points at the recorded decision and asks the worker to finish the open work. When `--note` is omitted the pointer itself is named. The captain's answer's durable closure belongs to the keyed-answer intake, not to this note: firstmate delivers it through `bin/fm-send.sh --resolve-key`, which closes the open keyed decision in the fold, and the resumed worker reads it from its durable inbox. A resume alone relaunches the worker without closing the record, so the decision would keep surfacing in OPEN DECISIONS.
- A wrong `--reason` is refused: a task parked for a decision is never resumed as a merge, and the message points at `clear` for a release that no longer applies.
- A task whose recorded harness is a raw launch command's basename is resumed on the resolved verified adapter family, the same resolution the stop used, because the control plane cannot reconstruct the original command.

For a landing that is trivially and cleanly complete, firstmate may skip the resume entirely: `fm-park.sh clear <task-id>` removes the marker without relaunching, and the ordinary teardown path follows.
Cleanup therefore never depends on a worker relaunch.

The merge watch stays armed while the task is parked: `bin/fm-pr-poll.sh`'s validated poll and `bin/fm-pr-green-return.sh`'s bound green-return scan both read the task's recorded `pr=` independently of the worker, so the merged wake and the merge mandate arrive normally and their handler resumes or clears the parked task.

## Read surfaces

`fm-park.sh list` prints one TSV row per marker: id, reason, pointer, branch, pr, epoch, incarnation, state.
`fm-park.sh status <task-id>` prints `parked <id> ...` and exits 0 only for a live released marker, `releasing <id> ...` and exits 1 for a recorded but unverified release, `stale <id> ...` and exits 1 for a marker recorded by an earlier incarnation, and `not-parked <id>` and exits 1 when no marker exists.
Both read only this home's `state/` directory.

## Fail-closed boundaries

Parking never discards work: the stop preserves the endpoint, the worktree, and every uncommitted change, and `bin/fm-teardown.sh` keeps its complete landed-work test.
Parking never merges and never tears down.
An unreadable or malformed marker is refused rather than acted on, and a marker naming a different task or schema is refused.
A stale marker from an earlier incarnation is never authoritative; `clear` removes it explicitly, and `park` replaces it with a fresh release.
An automatic-backend home with an unreadable backlog refuses the release before it stops the worker, because an undocumented handoff is not a release.

## Tests

`tests/fm-park.test.sh` pins eligibility (done plus PR parks, working refuses, secondmate refuses, no pointer refuses), the run-step gate rules (an ask-user gate parks as a decision, a fix-review gate and a keyless ask-user gate refuse), idempotency, the releasing retry's restored status line, the release, the releasing retry, and resume under the real lease guard, the stale-incarnation marker, the raw-harness resume, the marker contents, the status line, resume notes and marker removal, clear, list/status, the backlog note through the gate library, the manual fallback, the sweep, and the snapshot's active-versus-parked occupancy projection.
`tests/fm-crew-state.test.sh` pins the marker read and the gate-scoped authority parser, `tests/fm-watch-dead-worker.test.sh` pins the expected-stopped predicate, and `tests/fm-brief.test.sh` pins the generated ship/scout release note.
