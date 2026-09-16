# Park-release mechanism

The rule this mechanism serves: a task that is only waiting - for a merge or for a captain decision - must not occupy the operating point.
Its slot is released, the handoff lives in the PR or report, the status log, and the backlog, and the task is resumed later as a short run.
`bin/fm-park.sh` is the single owner of that release.

The always-loaded policy is in `AGENTS.md` section 7; this document owns the deterministic mechanics, the marker schema, the trigger rules, and the resume semantics.

## Triggers

A task is parked when firstmate handles a wake that shows a worker waiting, or when the bounded sweep finds one that was missed:

- A `done:` report whose only remainder is a merge: the task has a recorded `pr=` and the crew reads `done` or `parked`.
- A documented decision wait: the status log holds an open keyed `needs-decision` or `blocked` event, or the backlog row is captain-held (`hold_kind: captain`).
- A no-mistakes run parked at an ask-user/authority gate: the canonical current-state line reads `parked` from the run step and carries the `(ask-user: authority decision)` marker, which `bin/fm-crew-state.sh` derives from the gate findings' `action` column (a finding whose action is `ask-user`) - never from the gate's own note text, which mentions ask-user on every review-step gate. The pointer is the gate's open keyed status decision.
- A run parked at any other gate is refused: a `fix_review` gate is the pipeline's own fix round, and a gate whose findings carry no `ask-user` action waits on the worker, so the worker must answer it and parking would stop the process the gate is waiting on.
- A run parked at an ask-user gate whose decision key is not recorded refuses rather than guessing.

The sweep (`bin/fm-park.sh sweep`) is the bounded session-start and heartbeat housekeeping pass: the locked startup child of `bin/fm-startup-network.sh` runs it after the network sweeps, and heartbeat review runs it by hand.
It is silent on success, bounded by `FM_PARK_SWEEP_LIMIT` (default 2) and `FM_PARK_SWEEP_BUDGET_SECS` (default 20), and prints one `PARK_SWEEP:` line per release it could not complete.

## Eligibility

`fm-park.sh park <task-id>` refuses loudly unless every condition holds:

- The task is not a persistent secondmate; an idle secondmate is healthy and is never parked.
- The crew is not actively working: `bin/fm-crew-state.sh` must not read `working`. A run parked at a gate is allowed only through the gate rules above; a running pipeline run is not.
- There is a provable handoff pointer: an open keyed decision, a captain-held backlog row, or a recorded `pr=`.
- A merge pointer additionally requires crew state `parked` or `done` and no pending gate; a gate-pending run never falls through to the merge label, and a merge handoff on any other state is refused rather than guessed.

## What park does

1. Write `state/<id>.parked` (schema `fm-park.v1`) with `state=releasing` as the durable intent.
2. Append one status line: `<paused-verb> [key=park-<id>]: released awaiting <merge|decision> - <pointer>`, where `<paused-verb>` is the configured `FM_CLASSIFY_PAUSED_VERB` (default `paused`).
3. Record the handoff note in the task's backlog row under the same gate rules as every other lifecycle mutation: with an automatic backend and compatible tasks-axi the note is written through `tasks-axi update --body-file --archive-body`, a manual-backend home prints the exact note owed on stderr, and an automatic-backend home whose backend cannot be read is refused before any mutation.
4. Stop the worker through `bin/fm-control.sh <id> exit`, which preserves the endpoint, the worktree, the branch, and every uncommitted change, and which verifies through the backend's recovery-grade classifier that the agent actually stopped.
5. Rewrite the marker with `state=released` only after that stop is verified.

`state=releasing` means the intent is durable but the stop is not verified, so the task is not parked and its slot is not claimed free.
A failed or interrupted release stays at `releasing`; running `park` again retries the note and the stop and commits `released`.
An already-released task is idempotent success with no second exit.

## Marker schema

`state/<id>.parked` is one `key=value` per line:

| Field | Meaning |
| --- | --- |
| `schema` | `fm-park.v1`; any other value is refused rather than trusted. |
| `task` | The exact task id; a marker naming another task is refused. |
| `reason` | `merge` or `decision`. |
| `pointer` | The PR URL, `key=<decision-key>`, or `captain-hold: <reason>`. |
| `branch` | The released work branch, or `-`. |
| `pr` | The recorded PR URL, or `-`. |
| `epoch` | Unix seconds at park time. |
| `incarnation` | The released worker's `spawn_gen`, or `-`. |
| `state` | `releasing` or `released`; only `released` is parked state. |

The marker is a regular file under this home's `state/`; a symlink there is refused.
`bin/fm-crew-state.sh` reads a `released` marker as authoritative current state (`state: parked`, source `park-marker`), so the operating point sees the release without a second state source.
`bin/fm-fleet-snapshot.sh` projects the same read into its `occupancy` field, where `active` counts only `working` tasks and `parked` counts the released ones.
`bin/fm-teardown.sh` removes the marker with the rest of the task record.

## Resume

`fm-park.sh resume <task-id> --reason merge|decision [--note <text>]` requires a `released` marker whose reason matches, relaunches the worker through `bin/fm-control.sh <id> relaunch --note <short note>`, and removes the marker only after the relaunch succeeds.
The relaunch reuses the same endpoint and worktree and appends the note to the task's instructions, so the resumed worker reads exactly what changed.

- `--reason merge`: the note names the merged PR and asks for a head reconciliation, a rebase or fix only if needed, and a final `done:` for cleanup.
- `--reason decision`: `--note` carries the captain's words; the note states that they resolve the recorded pointer and asks the worker to finish the open work. When `--note` is omitted the pointer itself is named.
- A wrong `--reason` is refused: a task parked for a decision is never resumed as a merge, and the message points at `clear` for a release that no longer applies.

For a landing that is trivially and cleanly complete, firstmate may skip the resume entirely: `fm-park.sh clear <task-id>` removes the marker without relaunching, and the ordinary teardown path follows.
Cleanup therefore never depends on a worker relaunch.

The merge watch stays armed while the task is parked: `bin/fm-pr-poll.sh`'s validated poll and `bin/fm-pr-green-return.sh`'s bound green-return scan both read the task's recorded `pr=` independently of the worker, so the merged wake and the merge mandate arrive normally and their handler resumes or clears the parked task.

## Read surfaces

`fm-park.sh list` prints one TSV row per marker: id, reason, pointer, branch, pr, epoch, incarnation, state.
`fm-park.sh status <task-id>` prints `parked <id> ...` and exits 0 only for a released marker, `releasing <id> ...` and exits 1 for a recorded but unverified release, and `not-parked <id>` and exits 1 when no marker exists.
Both read only this home's `state/` directory.

## Fail-closed boundaries

Parking never discards work: the stop preserves the endpoint, the worktree, and every uncommitted change, and `bin/fm-teardown.sh` keeps its complete landed-work test.
Parking never merges and never tears down.
An unreadable or malformed marker is refused rather than acted on, and a marker naming a different task or schema is refused.
An automatic-backend home with an unreadable backlog refuses the release before it stops the worker, because an undocumented handoff is not a release.

## Tests

`tests/fm-park.test.sh` pins eligibility (done plus PR parks, working refuses, secondmate refuses, no pointer refuses), idempotency, the marker contents, the status line, resume notes and marker removal, clear, list/status, the backlog note through the gate library, the manual fallback, the sweep, and the snapshot's active-versus-parked occupancy projection.
`tests/fm-crew-state.test.sh` pins the marker read and `tests/fm-brief.test.sh` pins the generated ship/scout release note.
