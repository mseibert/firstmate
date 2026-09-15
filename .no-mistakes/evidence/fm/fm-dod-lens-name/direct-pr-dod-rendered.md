# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
A review verdict only covers the branch head it was computed on, so order the loop so every verdict lands on the final mergeable head.
Three of the last five fleet PRs shipped a verdict older than their head, because a commit or rebase landed after the verdict and invalidated it.
Enforce that ordering structurally instead of by discipline:

1. Implement the change and apply every fix. Make no further code changes after this step.
2. Rebase onto the current main as the LAST code step, so the branch is up to date and mergeable.
3. Request the verdict only after that rebase: when your task's instructions call for a review verdict, request it once the branch is pushed and the PR is open.
4. Freeze the branch until the verdict has landed and is verified to cover your head: after step 3, make no commits and run no rebase until the verdict's timestamp is newer than the branch head it must cover.
5. Read the verdict timestamp correctly per forge. Ein frisches Verdict auf Forgejo erkennst du am updated_at des crabd-Tracking-Kommentars, NICHT an created_at und NICHT daran, dass ein neuer Kommentar erscheint. crabd editiert denselben Kommentar. Vergleiche updated_at gegen die Commit-Zeit deines Kopfes. Auf GitHub ist es umgekehrt.

Before every verdict request, check the PR's target base first: it must be the project's intended integration branch, never the default branch.
On the firstmate fork that base is seibert/main, and a PR pointed at main trips the red "PR must be raised via no-mistakes" check - the early warning for a wrong base, not a broken check.
Correct a wrong base before requesting anything, then check that the branch is mergeable onto the current main; if it is not (main has moved), rebase first, then request the verdict.

The PR body must carry its own `## Five-lens gate` section with the result of every lens, because a missing, incomplete, or unreported gate counts exactly like an open finding.
Run the five lenses over the branch diff, each in its own fresh context (a subagent or a fresh session), and fix what they find: `code-review` (correctness), `maintainability-review` (rot, bandaids, speculative scaffolding), `structural-fit-review` (structural fit and defended choices), `design-decision-questioner` (challenge the decisions), `self-containment-review` (context a repo reader cannot resolve).
The captain's list calls the `structural-fit-review` lens `architecture-system-design-reviewer`.
Record one row per lens in the PR body - whether it ran, how many findings it reported, how many you fixed - in this shape, replacing every placeholder with the real result:

## Five-lens gate
| Lens | Ran | Findings | Fixed |
|---|---|---|---|
| code-review | <yes or no> | <n> | <n> |
| maintainability-review | <yes or no> | <n> | <n> |
| structural-fit-review | <yes or no> | <n> | <n> |
| design-decision-questioner | <yes or no> | <n> | <n> |
| self-containment-review | <yes or no> | <n> | <n> |

End it with `Result: clean` only when every `Ran` cell says `yes` and no finding remains open; otherwise name what is not clean there, as `Result: 1 finding open - see <lens>` or `Result: 1 lens did not report - see <lens>`.
Fix findings and re-run the lenses each fix affects, up to three rounds (a round is one lens pass plus its fixes; a later round re-runs only the lenses a fix affects); a lens that could not run is retried once before it is recorded as not-run.
Run the gate on the branch content you are about to push, after the rebase and before the verdict request and freeze in the ordering above; re-run the lenses affected by any later change - a fix, or a rebase that changed the diff - so every pushed line has been gated.
If the final result is not clean, append `done: PR {url} - five-lens gate: <what is not clean>` instead of the plain done line, so the open gate reaches firstmate with the ready signal.

The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with `gh-axi`, then append `done: PR {url}` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
