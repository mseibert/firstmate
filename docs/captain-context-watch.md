# Captain context watch

The captain decided on 2026-09-13 that the captain session (the Pi window `firstmate:captain`) restarts at 500k of context.
[`bin/fm-captain-context-watch.sh`](../bin/fm-captain-context-watch.sh) measures that value from outside the session and runs the restart behind a persist gate; [`bin/fm-captain-context-watch-arm.sh`](../bin/fm-captain-context-watch-arm.sh) installs it under a systemd `--user` unit and registers its liveness check.
Script headers own exact flags, environment knobs, and mechanics; this page owns the measured finding, the wiring rationale, and the evidence contract.

## Which footer value carries the threshold

Pi renders the bottom footer stats line as `<↑input> <↓output> [R cacheRead] [W cacheWrite] [CH%] [cost] <percent>%/<window> (auto)`.
The `↓` value is the session's cumulative **output** over every assistant message, not its context.
The context value is the `<percent>%/<window>` pair: Pi derives it from the last recorded assistant usage plus the estimated trailing content, divided by the model's context window.

Both readings were checked against the captain session on 2026-09-13 (`firstmate:captain` on claudeserver):

- Live footer sample, idle: `↑9.2M ↓144k 26.1%/1.0M (auto)`; its Pi session JSONL summed to 9,208,656 input tokens (`9.2M`) and 143,970 output tokens (`144k`), so `↓` is output and `26.1%/1.0M` is the context.
- The previous captain session (restarted that day at ~80% context) recorded cumulative output 548,854 (`549k`) in its JSONL while its last recorded context was about 80% of 1.0M, so the two values diverge by design.
- Twelve repeated `tmux capture-pane -p -t firstmate:captain | tail -1` samples on an idle session were byte-identical; during an active turn the footer moved with the turn (`↑4.2M ↓104k 20.8%` to `↑4.9M ↓110k 21.9%` to `↑9.2M ↓144k 26.1%`) and settled between turns.

Therefore **500k of context is 50.0% of this model's 1.0M window**, and the watch measures context tokens by default.
`FM_CCW_METRIC=output` keeps the literal `↓` reading available as a documented option; the threshold number itself stays one value (`FM_CCW_THRESHOLD`, default `500000`) either way.

The parser scans a bounded tail of the pane for the last line carrying the percent/window shape rather than trusting the very last line, because Pi renders extension status lines after the stats line.
It reports `no-footer`, `no-percent`, or `capture-error` instead of guessing; five consecutive unmeasurable samples surface through the registered check.
This defends against the known `tmux capture-pane` content unreliability on hosts where an overlay can share the pane: a capture that is not a footer never counts as one.

## Why it runs outside the session

A watcher that dies with the session it restarts is not one, so nothing here runs inside a captain turn.
[`docs/examples/systemd/firstmate-captain-context-watch.service`](examples/systemd/firstmate-captain-context-watch.service) is a tracked template installed by the arm helper at `~/.config/systemd/user/`, with `Restart=always`, exactly like the capacity brake.
The registered check `state/captain-context-watch.check.sh` is the only piece the watcher dispatches; it reads durable files only and prints one line on a check wake when firstmate should act.
The target is a tmux window, so the mechanism is tmux-based; a captain session on another runtime backend is out of scope for this mechanism.

## The flow and its safety properties

| Phase | What happens |
| --- | --- |
| `idle` | Measures every `FM_CCW_INTERVAL` seconds (default 60). At or above the threshold it captures the agent pid and writes a durable request. |
| `awaiting-answer` | Nothing restarts. The session persists its open records and runs `bin/fm-captain-context-watch.sh answer --corr <id>`. |
| `quiescing` | A bounded wait (default 300s) for the answered turn to end. |
| `restarting` | Kills ONLY the `pi` pid found as a direct child of the target pane's shell, then types `pi` into that pane. Re-entrant: a crash after the kill completes the start on the next cycle. |
| `aftercare` | Verifies a watcher beat newer than the new agent, otherwise sends the session-start nudge once, and records the new footer. |

The restart release is the correlated answer and nothing else: never a wall clock, never a timeout, never an assumption.
The answer file is bound to the request's correlation id, so a stale answer from an earlier crossing cannot release a later one.
A repeat trigger while a request is open opens no second request, a cooldown (default 300s) separates consecutive restarts, and every phase transition is appended to `state/.captain-context-watch.log`.
The restart never touches `systemctl --user restart firstmate-tmux` (that would restart the whole tmux session and kill every worker window), never signals a worker, and never merges anything.

## Arming, status, disarming

Arming is the private application step for this home and stays a firstmate post-step after the change lands, as it is for the capacity brake:

```sh
bin/fm-captain-context-watch-arm.sh arm
bin/fm-captain-context-watch-arm.sh status
bin/fm-captain-context-watch-arm.sh disarm
```

`arm` is idempotent, replaces only a verified naked watch loop, and writes the unit plus the registered check atomically enough that a home never holds an unauthenticated check shim.
`disarm` stops and removes the unit and the check, and drops a pending request/answer rather than leaving a stale release gate behind; the journal and state remain as evidence.

## Evidence contract

One real crossing must be readable from the journal alone: the old footer with its context and output values, the request correlation, the answer (with its note), the old and new agent pids, the new footer, and the post-restart watcher beat.
The durable files are all home-private and dot-prefixed under `state/`: `.captain-context-watch.state` (the phase record), `.captain-context-watch.request`, `.captain-context-watch.answer`, `.captain-context-watch.notified` (the check's report bookkeeping), `.captain-context-watch-beat` (the loop's liveness beat), `.captain-context-watch.lock`, and `.captain-context-watch.log` (the bounded journal).
The end-to-end transaction is proven against a disposable stand-in session in `tests/fm-captain-context-watch.test.sh`; the first live crossing adds the real session's own values and the watcher's delivery of the check line.
