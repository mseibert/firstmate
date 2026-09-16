# Verification: the Cognee memory bridge

Audience: maintainer verification.

Active empirical evidence that the real path behind the Cognee memory bridge
works end to end: 1Password service account -> the Cognee API key item -> a
Cognee search -> rendered context.
[`docs/cognee-memory-bridge.md`](../cognee-memory-bridge.md) owns the
operator-facing facts and `bin/fm-cognee-context.sh --help` owns the flags,
defaults, and exit codes; this record owns how those facts were established and
what is still unproven.

`tests/fm-cognee-context.test.sh` is hermetic by design - it stubs `op`,
`security`, and `curl` - so it can only prove the contract written into its
stubs.
This record exists because item, vault, and field resolution under a real
service-account token, and the real response shape, are exactly what stubs
cannot establish.

## Subject

| Field | Value |
|---|---|
| Verified | 2026-08-23 |
| Instance | `https://cognee.seibert.tools`, dataset `personal` |
| 1Password CLI | `op` 2.38.1 |
| 1Password identity | `User Type: SERVICE_ACCOUNT` |
| Platform | macOS arm64 (Darwin 25.6.0) |

## The service account can read the Cognee item

The token came from the `op-service-account-claude-code` keychain item, the same
non-interactive source the bridge uses; no interactive `op signin` ran.

```
$ op --version
2.38.1

$ op whoami   # account subdomain and integration id withheld
User Type:         SERVICE_ACCOUNT
```

This repository is public, so the account subdomain and the service-account
integration id are withheld here on purpose.
The `User Type` line is the part that proves the claim - the reads below ran as a
service account, not through an interactive session - and no account or
integration identity is needed for that.

The default item title resolves under that service account, and the item id is
stable:

```
$ op item list --vault ai-agent-reads --format json   # filtered to the Cognee item
{"id": "sas5a33ahm5kug3wrc5zprwlw4", "title": "Cognee martin.seibert@seibert.group", "vault": "ai-agent-reads"}

$ op item get "Cognee martin.seibert@seibert.group" --vault ai-agent-reads --format json
id: sas5a33ahm5kug3wrc5zprwlw4
title: Cognee martin.seibert@seibert.group
vault: ai-agent-reads
category: LOGIN
field: username | type: STRING | has_value: True
field: password | type: CONCEALED | has_value: True
field: notesPlain | type: STRING | has_value: False
field: api_key | type: CONCEALED | has_value: True
field: api_key_id | type: STRING | has_value: True
field: user_id | type: STRING | has_value: True
```

The `op item get` output above is reduced to field labels and presence on
purpose: the run never printed a concealed value, so no secret is recorded here.

This settles a live-versus-recorded conflict worth keeping: an older operator
note recorded this credential's title with parentheses, which is why a
plaintext-title reference was believed to fail.
The live service account shows the title without parentheses, and the id matches
the item the note names, so the bridge's default title is the correct one.
The vault is readable by the service account, so the default vault, item, and
field need no override.

## The real search call returns memory and renders

Run from the repository root with no `COGNEE_*` overrides, so every default was
exercised:

```
$ bin/fm-cognee-context.sh --top-k 3 "1Password service account secret references"
# Cognee memory context

- Dataset: personal
- Query: 1Password service account secret references
- Search type: CHUNKS

## op-read-secret-references-vertragen-keine-sonderzeichen-im-i

# op read: Secret References vertragen keine Sonderzeichen im Item-Titel

Problem: 'op read op://<Vault>/<Titel>/<Feld>' schlaegt fehl, sobald der
Item-Titel Zeichen wie Em-Dash, Klammern o.ae. enthaelt. [...]

(saved 2026-08-08)

## vllm-gateway-ai-hub-service-accounts-und-crab-d-config-sync-
[...]
$ echo $?
0
```

The entries are elided with `[...]` where they were long; the structure, the
header block, and the per-entry headings are verbatim.

The same day, after the request header moved onto `curl`'s stdin (`--config -`,
so the key touches neither the argument list nor the filesystem) and the parser
learned to accept options after the query, the documented trailing-option form
was re-run live against the same instance:

```
$ bin/fm-cognee-context.sh "1Password service account secret references" --top-k 2 --out /tmp/cog.md
$ echo $?
0
```

It exited 0, printed nothing to stdout or stderr, wrote the rendered context to
the named file, and the request carried `"query":"1Password service account
secret references"` with no flag text - so the key really does authenticate from
stdin, and the trailing `--out` really is parsed as the out-file.

## The response shape both search types actually return

`--json` captured the raw response so the renderer's assumptions could be checked
against the server rather than against a hand-written fixture.

Both `CHUNKS` and `SUMMARIES` return a list of dataset groups, each an object
with `dataset_id`, `dataset_name`, `dataset_tenant_id`, and a `search_result`
list of objects.
Each entry object carries the body in `text`.

The one difference that matters to rendering: under `SUMMARIES`, `document_name`
and `document_id` are `null`, so the entry heading falls back to the entry `id`:

```
$ bin/fm-cognee-context.sh --search-type SUMMARIES --top-k 2 "1Password service account secret references"
# Cognee memory context

- Dataset: personal
- Query: 1Password service account secret references
- Search type: SUMMARIES

## 04d63cdf-0fce-5f93-af2f-912209e18d69

This chunk is about:
- Products: 1Password CLI
- Systems: Secret References
- Topics: Error handling in secret retrieval scripts

Facts:
- On August 8, 2026, an issue was documented regarding 1Password CLI 2.35.0 on
macOS where 'op read' fails when item titles contain special characters like
em-dashes or parentheses. [...]
```

So `text` is the correct body key for both search types the bridge accepts, and
the `document_name` fallback to `id` is load-bearing rather than defensive.

The bridge treats a group that has lost its `search_result` key as drift rather
than as an empty result, so the question of what a genuinely empty result looks
like on the wire was probed directly.
Two attempts, both on 2026-08-23:

```
$ bin/fm-cognee-context.sh --json --top-k 3 "zzqqxx nonexistent gibberish token wharrgarbl 91772"
[{"dataset_id":"...","dataset_name":"personal","dataset_tenant_id":null,"search_result":[ ...3 entries... ]}]

$ bin/fm-cognee-context.sh --json --top-k 3 --dataset zzz-nonexistent-dataset "anything"
error: Cognee search returned HTTP 404
```

The search is nearest-neighbour, so a query that matches nothing semantically
still returns `topK` entries rather than an empty list, and an unknown dataset is
a 404 rather than an empty group.
Both lines are the output of the bridge as it stood on that date, before it began
appending the server's reason body to a non-200 message.
No observed response omits `search_result` or returns it as anything but a list,
which is why requiring the key cannot relabel a legitimate empty result.
An empty `search_result` list, and a top-level empty list, both still render the
no-entries note and succeed.

## A headless Linux firstmate resolves the token from the file

The record above was taken on macOS. On 2026-09-16 the bridge was measured on the
two headless Linux hosts that actually run firstmate, and the token guard - not
the credential - turned out to be the blocker.

Both hosts answered the same way, with the bridge as it stood before this branch:

```
$ bin/fm-cognee-context.sh "firstmate Forgejo Umzug" --top-k 2
error: no 1Password service-account token available (set OP_SERVICE_ACCOUNT_TOKEN or install the op-service-account-claude-code keychain item); refusing interactive sign-in
```

while the credential itself was fine on both, read through the same service
account and the same item:

```
$ op read op://ai-agent-reads/sas5a33ahm5kug3wrc5zprwlw4/api_key | wc -c
64
```

Neither host has a keychain, so neither of the guard's two sources could ever
resolve there. Both do have the fleet's `op` wrapper on `PATH`, and that wrapper
injects the service-account token from `~/.config/op/sa-token` on every
invocation - which is why the `op read` above worked while the bridge refused.

With the file added as the third source, both hosts render real memory:

| Host | Before | After |
|---|---|---|
| proxmox | `exit=1`, no service-account token | `exit=0`, entries rendered |
| claudeserver | `exit=1`, no service-account token | `exit=0`, entries rendered |

Reachability is not the constraint: `https://cognee.seibert.tools` answered HTTP
200 in 0.05 s from proxmox and 0.07 s from claudeserver, and the `personal`
dataset returned hits for every probe query.

The `HOME`-unset path was measured at the same time, under the script's `set -u`:
the first version of this fallback expanded `$HOME` unguarded and died with
`HOME: unbound variable` before reaching the fail-closed message. It is guarded
now, and a hermetic test covers both halves.

## What is still unproven

- The `team` dataset. Every run above used the default `personal` dataset.
- A genuinely empty `search_result` from this instance. The probes above could
  not produce one, so the empty-result rendering is covered only by the hermetic
  test's fixtures.
- Cold-start latency. The runs above hit a warm instance and returned in a few
  seconds, so the 60 second default request timeout is a margin chosen against
  the instance's documented warm-up behavior, not a measured worst case.
- A live authentication failure. The unknown-dataset probe above exercised real
  non-200 handling, but no real credential was invalidated to observe a live
  401, so the credential failure paths are covered only by the hermetic test's
  stubbed `curl`.
- The `--out` file's mode. The live `--out` run recorded above predates the
  bridge taking ownership of that file's mode, so the mode-600 guarantee - the
  file emptied at mode 600 before the context is written, and a mode that cannot
  be set treated as a failure - is covered only by the hermetic test.
- What this instance puts in a non-200 reason body. The bridge appends a bounded
  excerpt of that body to the error line, but the recorded 404 probe predates
  that change and was not re-run, so whether this instance sends a `detail`
  object, some other shape, or an empty body on a 404 is unobserved. An empty
  body leaves the message exactly as recorded above; the appending itself is
  covered only by the hermetic test's stubbed bodies.
- The headless token file's own permissions. Both Linux hosts keep it at mode 600
  and the bridge only requires that it be readable, so the mode is a host
  convention this record observed, not a guarantee the bridge enforces.
- A file that exists but holds an empty or malformed token. The file branch was
  measured only with a real token; the empty case falls through to the
  fail-closed message by construction, but no live run observed it.
