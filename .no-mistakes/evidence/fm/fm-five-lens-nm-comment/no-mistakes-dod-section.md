# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe it is complete, append `done: {summary}` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.
A review verdict only covers the branch head it was computed on, so order the loop so every verdict lands on the final mergeable head.
Three of the last five fleet PRs shipped a verdict older than their head, because a commit or rebase landed after the verdict and invalidated it.
Enforce that ordering structurally instead of by discipline:

1. Implement the change and apply every fix. Make no further code changes after this step.
2. Rebase onto the current main as the LAST code step, so the branch is up to date and mergeable.
3. Request the verdict only after that rebase: start or continue the no-mistakes run that computes the review verdict against the branch head.
4. Freeze the branch until the verdict has landed and is verified to cover your head: after step 3, make no commits and run no rebase until the verdict's timestamp is newer than the branch head it must cover.
5. Read the verdict timestamp correctly per forge. Ein frisches Verdict auf Forgejo erkennst du am updated_at des crabd-Tracking-Kommentars, NICHT an created_at und NICHT daran, dass ein neuer Kommentar erscheint. crabd editiert denselben Kommentar. Vergleiche updated_at gegen die Commit-Zeit deines Kopfes. Auf GitHub ist es umgekehrt.

Before every verdict request, check the PR's target base first: it must be the project's intended integration branch, never the default branch.
On the firstmate fork that base is seibert/main, and a PR pointed at main trips the red "PR must be raised via no-mistakes" check - the early warning for a wrong base, not a broken check.
Correct a wrong base before requesting anything, then check that the branch is mergeable onto the current main; if it is not (main has moved), rebase first, then request the verdict.

The freeze in step 4 covers the pipeline head the run validates; keep it until the verdict has landed and covers that head.
The five-lens pass below is then the designated post-verdict step, and any fix commit it pushes becomes the final head the comment must cover.
You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, pass `--intent` as only this brief's `## Captain's intent` subsection plus any later words the captain actually said.
For a legacy brief with no such subsection, include only words explicitly labeled `Captain:`, `Captain's words:`, `Captain's ask:`, or `Captain's intent:`; never copy its mixed `# Task` wholesale. If it has no provenance-marked captain words, stop and ask firstmate instead of starting no-mistakes.
Do not include `## Firstmate spec`, later Firstmate build constraints, or your own decisions and tradeoffs.
The `--intent` string you pass must be self-sufficient: that string plus the codebase must let a reader reconstruct roughly the same specification, without depending on a separate report, a PR, or context that lives only in this conversation.
When the captain's intent refers to a report, decision, or PR ("do items 1, 2, 3, and 7 of the report"), write the substance of the referenced items into `--intent` in the captain's terms, not only the pointer; that substance is the captain's ask by reference, while Firstmate's build instructions and your own decisions still stay out.
This replaces the no-mistakes skill's advice to enrich `--intent` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

One drive call blocks until the next gate or outcome, which routinely outlives what your harness lets a single command run: Claude Code kills a command at ten minutes maximum, while one fix round is capped around thirty minutes and up to three rounds chain.
So background the drive call and poll `no-mistakes axi status` from a separate call instead of sitting in one blocking hold your harness will kill.
Where a harness's own command limit is not established, assume it bounds commands and use that same background-and-poll shape.
A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
Reattach and keep going rather than reporting the pipeline blocked; rule 7 owns the checks that decide when a pipeline block is real.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
  Firstmate applies `ask-user-authority` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass `--yes` (or `-y`) to `no-mistakes axi run` or `no-mistakes axi respond`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.
no-mistakes opens the PR through the pipeline, so the five-lens gate for this mode is a separate PR comment instead of a PR-body section.
After the pipeline opens the PR, run the five lenses over the branch diff, each in its own fresh context (a subagent or a fresh session): `code-review` (correctness), `maintainability-review` (rot, bandaids, speculative scaffolding), `architecture-system-design-reviewer` (structural fit and defended choices), `design-decision-questioner` (challenge the decisions), `self-containment-review` (context a repo reader cannot resolve).
Fix what they find and push the fixes as an ADDITIONAL commit on the same branch; when nothing was found, push nothing and say so in the comment.
Then post exactly ONE comment on the PR with the title `Findings and fixes from 5-lenses-review`, recording one row per lens in this shape, replacing every placeholder with the real result:

| Lens | Ran | Findings | Fixed |
|---|---|---|---|
| code-review | <yes or no> | <n> | <n> |
| maintainability-review | <yes or no> | <n> | <n> |
| architecture-system-design-reviewer | <yes or no> | <n> | <n> |
| design-decision-questioner | <yes or no> | <n> | <n> |
| self-containment-review | <yes or no> | <n> | <n> |

End it with `Result: clean` only when every `Ran` cell says `yes` and no finding remains open; otherwise name what is not clean there, as `Result: 1 finding open - see <lens>` or `Result: 1 lens did not report - see <lens>`.
The comment must name the FINAL head SHA and the CI state on that head; after a fix commit the gate covers the head after that commit, not the pipeline head.
Keep the order strict: lenses, then fixes, then push, then the comment.
Never merge the PR; the configured merge authority decides.
The captain's merge policy still requires the `## Five-lens gate` body block on every PR (its Hard-Stop 1), and until the captain's policy recognizes this comment, the comment does NOT count as evidence for that stop.
Do not treat the comment as having satisfied that stop.

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), run the five-lens pass and post its comment.
The pipeline's CI monitor re-arms on base movement, not on a new head, so when a lens fix commit moved the head, wait for CI to report on that final head and record its state in the comment.
Append `done: PR {url} checks green` only once CI is green on the final head the comment names, or `done: PR {url} checks green - five-lens comment: <what is not clean>` when CI is green there but the comment's Result is not clean; when CI is red on that final head, append `done: PR {url} checks red - <what failed>` instead of any checks-green line, then stop.
You are finished.
