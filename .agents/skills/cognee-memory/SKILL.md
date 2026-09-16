---
name: cognee-memory
description: >-
  Agent-only routine for pulling relevant Cognee memory into a task before it is
  commissioned. Load before writing a crewmate brief (ship or scout) so relevant
  stored memory reaches the worker as context. The routine is a lean documented
  bridge, not a framework: run bin/fm-cognee-context.sh with a query
  summarizing the upcoming work, and feed the returned entries into the brief.
  The Cognee API key is read from 1Password at runtime through the service
  account only, never the captain's interactive 1Password session.
user-invocable: false
metadata:
  internal: true
---

# cognee-memory

Load this before commissioning a task, when the upcoming work could benefit from
memory firstmate or the captain has stored before.
It pulls relevant entries out of the Cognee memory store and turns them into
context the worker can read, so a task does not start without the memory that
already exists about its subject.

The bridge is deliberately lean: one query, one rendered context block, one
explicit feed point.
There is no control plane, no watcher, and no automatic hook.
Firstmate decides when memory context is worth pulling.

## What it is

`bin/fm-cognee-context.sh` is the executable routine.
It queries the Cognee memory store and renders the relevant entries as Markdown.
The instance, dataset, key location, and exact usage live in
[docs/cognee-memory-bridge.md](../../../docs/cognee-memory-bridge.md).

## When to use it

Load and run this before writing a crewmate brief for a task whose subject may
already be in memory.
Examples: a task that revisits an earlier investigation, a fix for something
that was diagnosed before, a request that names a person, project, or system
firstmate has worked on.

Do not run it when the task is trivial, purely mechanical, or when the query
would not name anything specific.

## How to run it

Run the bridge with a query summarizing the upcoming work:

```sh
bin/fm-cognee-context.sh "replace the cognee plugin CLI path" --top-k 5
```

The rendered context prints to stdout.
To capture it into a file the worker can read or the brief can reference, let
`mktemp` name the file:

```sh
CTX=$(mktemp "${TMPDIR:-/tmp}/cognee-context.XXXXXX")
bin/fm-cognee-context.sh "replace the cognee plugin CLI path" --out "$CTX"
```

Prefer this form always.
It cannot collapse into a path two tasks share, and the template behaves the same
on macOS and Linux unlike `mktemp -t`.
The bridge restricts the file to mode 600 itself, whichever path it is given, so
the `personal`-dataset memory it holds is never left world-readable in a shared
directory.

Only when the task genuinely needs a stable, predictable path - a worker that is
told the path before the file exists, say - name it after the task instead:

```sh
bin/fm-cognee-context.sh "replace the cognee plugin CLI path" --out "/tmp/cognee-context-<task-id>.md"
```

Then substitute the real task id for `<task-id>`; never leave the placeholder,
and never expand a variable that could be empty, because either way the path
collapses to one shared name.
A shared path is the one thing that turns this file into a hazard: two tasks
would then read and write the same context, and a failed run for the second task
removes the file the first task's worker was told to read.

Use `--json` when you want the raw entries instead of the rendered block.

A failed run removes its own `--out` file, so the path is never an earlier run's
memory wearing this task's name.
Put `--out` first when the invocation is assembled from parts, so a mistake in a
later argument still sheds that file.
Either way, branch on the exit code rather than on the file existing: a failure
means proceed without memory context.

## How to feed the context in

Add the rendered context to the task brief as a short section under the
instructions, headed with the source so the worker knows what it is:

> Relevant Cognee memory context (dataset "personal", query "<query>"):
> <rendered entries>

When the context is long, write it to the task-scoped `--out` path and tell the
worker in the brief to read that file.
The worker reads it after dispatch, so the path must belong to this task alone.
Keep the feed point minimal and explicit: the context is background, never a
replacement for the task's own instructions.

## Key access - service account only

The bridge reads the Cognee API key from 1Password at runtime through the
service account only.
It never uses the captain's interactive 1Password session, so it can never be
locked behind a missing interactive login.
It resolves the service-account token itself, from the sources
[docs/cognee-memory-bridge.md](../../../docs/cognee-memory-bridge.md) names.
When no service-account access exists, the bridge refuses with a clear message
and exits non-zero.
Never fall back to an interactive 1Password sign-in on its behalf.

## When the bridge fails

If the bridge exits non-zero, report the reason to the captain in plain
language and proceed with the task without memory context.
A missing service-account token, an unreadable key, or a Cognee outage must not
block the task itself.
When the captain wants the memory path fixed, that is a separate piece of work.
