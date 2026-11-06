# Sweep GitHub: assessment brief (read-only)

Each assessment agent spawned by `skills/sweep-github` follows this brief. The
coordinator adds the repo (`$REPO`, as `owner/repo`), the local checkout path,
the batch of PR numbers, the cached PR JSON, and notes for the group.

You are assessing a batch of open PRs in `$REPO`. You are **read-only**: do
not close, comment on, label, push to, merge or check out any PR. Do not create
worktrees and do not edit any file in the repo. The coordinator acts on your
report.

In the checkout, run `git fetch -q origin main` once, then use read-only
commands:

- `gh pr view <N> -R "$REPO" --json title,body,isDraft,mergeable,mergeStateStatus,baseRefName,additions,deletions,files,labels,comments,reviews,createdAt,updatedAt,headRefName,statusCheckRollup`
- `gh pr diff <N> -R "$REPO" --exclude '*.png' --exclude '*.webp' --exclude '*.jpg'`
  (pipe big ones through `head -400`; it fails above 20,000 lines, and
  `--json files` stops at 100 files, so use
  `gh api "repos/$REPO/pulls/<N>/files?per_page=100&page=2"` for huge ones)
- `git log origin/main --oneline -S '<distinctive string from the diff>'`
- `git show origin/main:<path>`, `git grep -n '<string>' origin/main -- <path>`,
  `git cat-file -e origin/main:<path>`
- `gh pr list -R "$REPO" --state all --search '<keywords>' --json number,title,state,mergedAt`

In zsh, spell out `origin/main:path` in full. `$M:path` is read as a history
modifier and fails with "bad substitution". Quote separators: `echo ===` fails
with "== not found".

## Part 1: is it dead?

Verdict **CLOSE** only when you are confident, and have concrete evidence, that
one of these holds:

1. **Superseded:** a merged PR (give its number) or a commit on main (give the
   sha) already delivers the change, or the diff is already on main.
2. **Duplicate of another open PR** in the sweep that is the better or newer
   one. Name the canonical PR. Recommend closing only the worse of the two.
3. **Surface gone:** the files, components or routes it edits no longer exist
   on main, or were redesigned so the change no longer applies. Say what
   replaced them.
4. **Obsolete by nature:** a changelog PR whose dates a later open or merged
   one covers, a dependency bump main already has, or a scheduled auto-review
   PR whose fixes are all on main.
5. **Explicitly abandoned:** a human comment on the PR says not to merge it, or
   that it was replaced.

A PR is not dead just because it is old, conflicting, big or a draft. A
conflicting PR whose idea is still missing on main is alive and needs rework.
When in doubt, verdict **KEEP**.

How to find the evidence fast:

- **Verify the bug on main, not the PR body.** Grep main for the function the
  PR touches, read it as it is now, then `git log -S '<string main now has>'`.
  That names the PR that fixed it, even when its title shares no words with
  this one.
- **A PR that conflicts, or whose diff has shrunk to tests only, usually means
  main already has the change.**
- **Two open PRs that look like duplicates of each other are often both
  superseded** by a third, merged PR. Check main before picking a canonical.
- **Search open PRs by other authors too.** A human's newer PR can supersede
  one in the sweep. Do not recommend closing in favour of an unmerged PR
  outside the sweep: keep it and say so in `notes`.
- **The fix may land in a new file.** A performance idea can arrive as a new
  wrapper component rather than in the file the PR edited.
- **Before calling a limit or guard PR alive, check that the limit still
  exists.**
- **Even when a PR's mechanism is obsolete, check whether its user-facing
  payload landed** before closing it.
- **External tracker ids rarely appear in merged PRs.** Search by the
  symptom's keywords instead. If the PR links a tracker card, check the card's
  status (e.g. backlog, blocked) if you have access.
- **A `duplicate` label rarely names its target.** List PRs created in the same
  window (`--search 'created:A..B'`).
- **Scheduled bot series** (changelog, `review(<area>)`): read the generating
  workflow's fetch limit and how it picks its start date, and list each diff's
  `+## date` headings. `gh run list --workflow <file>` shows missed runs.
- **Dependabot:** compare versions with main's manifest and lockfile. A
  Dependabot PR carrying anyone else's commit will not `@dependabot rebase`.
- **Read inline review-bot comments** with
  `gh api "repos/$REPO/pulls/<N>/comments"`. A summary comment can hide the
  individual findings.
- **Open bot review PRs outside your batch** often list the PRs they overlap
  in a "Not in this PR" section. Grep their bodies for your PR numbers.
- **Test mergeability without a checkout.** Fetch with
  `git fetch origin pull/<N>/head:refs/sweep/pr-<N>`, then run
  `git merge-tree --write-tree origin/main refs/sweep/pr-<N>`. Delete the
  `refs/sweep/*` refs when done.
- **Use the cached JSON the coordinator gives you** before calling `gh`. Many
  agents share one API rate limit.
- **A PR synced to an external tracker card that is still "in review"** may be
  reopened by the sync bot after a close. Say so in `notes`, so the
  coordinator closes the card too.

**Human threads:** when the operator's account also posts bot write-ups and
trigger comments (`/qa-review`, `/claude-fix`, `/claude-review`), read the
comment body before you count it as a human objection.

## Part 2: priority (skip drafts and CLOSE verdicts)

Score each live, non-draft PR from 1 to 10. **Higher means more urgent and
important.** These are buckets: use the whole range.

| Score | Meaning                                                                                                                                                                                    |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 10    | Production is broken or bleeding now: an active security hole, data loss, users charged or credited wrongly at scale, site down.                                                           |
| 9     | A security, auth, money-correctness or legal-compliance gap with real current exposure: a sensitive page publicly readable, a double-charging path, a missing legally required disclosure.    |
| 8     | A significant bug on a core flow (sign-in, billing, the product's main actions), PII reaching places it shouldn't, a compliance item with a concrete obligation, or a hard deadline within a month. |
| 7     | A clear bug fix with moderate reach, or a money edge case.                                                                                                                                 |
| 6     | A solid improvement with limited impact, a minor bug on a secondary surface, or a typical requested UI change.                                                                             |
| 5     | A nice-to-have feature, a worthwhile refactor, or analytics with a clear consumer.                                                                                                         |
| 4     | Minor polish, internal tooling or CI, docs with ongoing value.                                                                                                                             |
| 3     | Low-value docs or exploratory work.                                                                                                                                                        |
| 2     | Speculative work, an RFC, or a large epic with no clear path to landing.                                                                                                                   |
| 1     | Barely worth keeping open.                                                                                                                                                                 |

Calibration:

- **Money and security beat UI.** A live billing bug outranks any UI change.
- **Requested UI changes are human requests, usually 6–7.** Score 7 only for a
  core flow or a request marked high priority. A backlogged or blocked request
  goes lower.
- Urgency (is something hurting now, is there a deadline?) and importance
  (reach × severity) both count.
- **Readiness is not part of the score.** Report it separately.
- An existing `Priority-N` label is someone's earlier guess. Reassess from
  scratch.
- For "is it publicly readable?", test every hostname production answers on,
  including any platform-default hostname. An access proxy may cover only the
  custom domain. A read-only `curl` settles exposure faster than the code.

**Readiness:**

- `ready` means small, mergeable and green. `mergeStateStatus: CLEAN` on a PR
  months old comes from old CI, so call that `needs-main-merge`.
- An empty `statusCheckRollup` with `BLOCKED` often means the `pull_request`
  runs are stuck at `action_required`. `gh run list --branch <head>` shows them.
- Check `baseRefName`. A PR stacked on another branch is `blocked` until its
  base lands.

## Output

End with one fenced `json` block: an array with one object per PR. **Also write that array to the results file the coordinator names** (e.g. `$SCRATCH/results/<group>.json`) and check it parses with `jq length`. The coordinator works from the files, not from your message.

```json
{"pr": 1234, "verdict": "CLOSE" | "KEEP", "close_reason": "superseded|duplicate|surface-gone|obsolete|abandoned|null", "evidence": "one or two sentences, written to be pasted as the closing comment: merged PR #, sha, path, what replaced it", "canonical": 1235, "priority": 7, "priority_why": "one sentence", "readiness": "ready|needs-main-merge|needs-rework|blocked", "human_thread": false, "notes": "risk, sibling PRs that share files, blockers"}
```

`canonical` and `priority` may be null. Before the JSON, add up to five lines
of **lessons**: gotchas or faster commands that would improve this skill.
