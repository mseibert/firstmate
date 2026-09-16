# Cognee memory bridge

The Cognee memory bridge is a lean helper that queries the Cognee memory store
before a task and brings relevant entries in as context for the worker.
It is a direct, documented integration - a single query routine, not a
framework.

## Instance and dataset

- Instance: https://cognee.seibert.tools
- Dataset: `personal`

The instance and dataset are the bridge's defaults.
They can be overridden per run with `COGNEE_URL` and `COGNEE_DATASET`.

## API key location

The Cognee API key is stored in 1Password and is read at runtime, never
committed or hard-coded.

- 1Password vault: `ai-agent-reads`
- 1Password item: `Cognee martin.seibert@seibert.group` (id `sas5a33ahm5kug3wrc5zprwlw4`)
- 1Password field: `api_key`

Access goes through the 1Password service account only, never the captain's
interactive 1Password session.
The service-account token comes from `OP_SERVICE_ACCOUNT_TOKEN` when set,
otherwise from the configured service-account keychain item
`op-service-account-claude-code`.
This keeps the bridge usable whenever an agent runs, without an interactive
login.
If no service-account token is available, the bridge refuses with a clear
message and exits non-zero.

The vault, item, and field can be overridden per run with `COGNEE_OP_VAULT`,
`COGNEE_OP_ITEM`, and `COGNEE_OP_FIELD`.

## Usage

```sh
bin/fm-cognee-context.sh <query>... [options]
```

It needs the 1Password CLI (`op`), `curl`, and `python3` on `PATH`.
Session-start bootstrap does not check for them, because the bridge is optional
and opt-in, so a missing one surfaces as a named error on the first run rather
than as a `MISSING:` toolchain line.

Run `bin/fm-cognee-context.sh --help` for the exact options, their defaults, the
full environment configuration, and the exit codes.

Example:

```sh
bin/fm-cognee-context.sh "1Password service account secret references" --top-k 5
CTX=$(mktemp "${TMPDIR:-/tmp}/cognee-context.XXXXXX")
bin/fm-cognee-context.sh "fix the relay poll" --out "$CTX"
```

## How it hooks into the task flow

The routine is invoked at task intake, before a crewmate brief is written.
Firstmate runs `bin/fm-cognee-context.sh` with a query summarizing the upcoming
work and feeds the returned entries into the brief as a short context section,
or writes them to a file the worker reads.
The exact trigger, invocation, and feed point are owned by the `cognee-memory`
skill (`.agents/skills/cognee-memory/SKILL.md`).

## What it queries

The bridge calls Cognee's search API:

```text
POST /api/v1/search
X-Api-Key: <key>
{"searchType":"CHUNKS","query":"<query>","datasets":["personal"],"topK":N}
```

It renders each returned entry with its document name - or its id when the
response carries none - and its text.
Entries whose `text` is present but empty are skipped rather than rendered as
empty headings.
A result with no usable entries - whether the search returned nothing at all or
only empty ones - renders a "No relevant Cognee memory entries found." note and
succeeds.
A readable response that simply holds no memory is not an outage.

A missing key is a different case and fails closed, at both levels of the
response: a dataset group without a `search_result` field, and a response whose
returned entries carry no `text` field at all.
That is what a server-side body-key rename looks like, and it would otherwise
report "no memory" on every query while real memory exists.
A single entry carrying `text` shows the key survives, so a response that mixes
keyed and unkeyed entries renders what it has instead of failing.
A `search_result` that is present but empty still reads as no memory.

Both output modes run the same payload validation, so `--json` emits the
response verbatim only after it has been checked.

## Failure behavior

The bridge fails closed: a missing service-account token, an unreadable key, a
non-200 response, or a response body whose shape it cannot parse as memory
entries produces a clear error on stderr and a non-zero exit.
When 1Password refuses the read, the bridge repeats `op`'s own reason, so an
expired token is not misreported as a renamed item.
A non-200 search does the same with the server's own reason body, folded onto the
error line and truncated, so a rejected credential and a rejected request shape
are told apart rather than both reading as a bare status code.
An option value that is missing or empty is a usage error, so `--out "$CTX"` with
an unset variable exits 2 instead of quietly printing the context to stdout and
reporting success.
Once `--out` has been parsed, any non-zero exit removes that file - a usage
error, an out-of-range `COGNEE_TIMEOUT`, a credential failure, an outage, an
unreadable payload, or a signal - so a reader who checks the path instead of the
exit code cannot pick up an earlier run's context as if it were this run's.
An error found earlier in the argument list than `--out`, such as an unknown
option, exits before the file is known and leaves it untouched.
Because a failed run deletes the file it was given, the `--out` path must be
scoped to one task: the `cognee-memory` skill owns that rule, so a failure for
one task can never remove the context another task's worker was told to read.
The example above lets `mktemp` pick the name for that reason - a path built from
a variable becomes one shared name the moment the variable is empty.
The `cognee-memory` skill names a task-shaped path only for the case that needs a
predictable one.
The file's mode is the bridge's own responsibility rather than the caller's: it
empties the `--out` file at mode 600 before writing, so memory from the private
dataset never lands in a world-readable file, and a mode it cannot set is a
failure rather than a warning.
It never renders a context block it could not fill, so an unexpected payload can
never reach a worker looking like real memory.
A Cognee outage or credential gap does not block a task - firstmate reports the
reason in plain language and proceeds without memory context.

[`verification/cognee-memory-bridge.md`](verification/cognee-memory-bridge.md)
owns the active evidence that the real service account, 1Password item, and
Cognee search path work end to end.
