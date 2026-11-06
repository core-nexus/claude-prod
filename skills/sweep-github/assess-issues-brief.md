# Sweep GitHub: issue assessment brief (read-only)

Each issue-assessment agent spawned by `skills/sweep-github` follows this brief.
The coordinator adds the repo (`$REPO`, as `owner/repo`), the local checkout
path, the `SWEEP_SKIP_AUTHORS` list, the batch of issue numbers, the cached
issue JSON, and notes for the group.

Issues that nobody reads regularly get no review except this sweep. Your job is
to decide, for each open issue, whether it should be **closed** (with a good,
stated reason) or **kept and ranked**. Be thorough and decisive.

You are **read-only**: do not close, comment on, label or edit any issue or PR.
Do not create worktrees or edit repo files. The coordinator acts on your
report.

In the checkout, run `git fetch -q origin main` once, then use read-only
commands:

- `gh issue view <N> -R "$REPO" --json title,body,author,labels,comments,createdAt,updatedAt`
- `gh pr list -R "$REPO" --state all --search '<keywords or #N>' --json number,title,state,mergedAt`.
  A PR that says "Fixes #N" or "Closes #N" is the strongest evidence. Also run
  `gh pr list -R "$REPO" --state all --search '#<N> in:body'`, but count only
  "Closes/Fixes #N": a PR that lists the issue under "known gaps" or merely
  mentions it doesn't fix it.
- `git log origin/main --oneline -S '<string>'`, `git log origin/main --grep '#<N>'`
- `git grep -n '<string>' origin/main -- <path>`, `git show origin/main:<path>`,
  `git cat-file -e origin/main:<path>`

In zsh, spell out `origin/main:path` in full, and quote separators.

## Part 1: close, but only for a good reason

Lean toward closing. The human wants the issue list aggressively cleaned, but
**every close needs a concrete, stated reason**:

1. **Fixed:** a merged PR or a commit on main resolves it. Name the PR or sha,
   and check the code on main still shows the fix.
2. **Surface gone:** the feature, route, component or file it is about no
   longer exists or was redesigned so the issue no longer applies. Say what
   replaced it.
3. **Duplicate:** another open issue covers the same thing better. Name it. Or
   a merged PR delivered it (that counts as Fixed).
4. **Obsolete:** later decisions superseded it. Examples: a tool the team no
   longer uses, a design direction main abandoned, a finding from a scheduled
   `auto-review` bot whose code has since been rewritten. Give the evidence.
5. **Not actionable:** too vague to act on, with no reproduction, no clear
   ask, and no activity in months, **and** you checked that the obvious reading
   of it is not a live bug on main. Say what you checked.

**Not good reasons on their own:** that it's old, that it's large, or that
nobody has commented. An old issue describing a bug still present on main stays
open.

**Author care:**

- Issues by in-scope authors and bots (`app/claude`, `app/github-actions`, …):
  close freely under 1–5.
- Issues by a `SWEEP_SKIP_AUTHORS` login: only 1–3 (Fixed, Surface gone,
  Duplicate) with hard evidence. Never close their issues as Obsolete or Not
  actionable; rank them instead, and add a note if you think they're stale.

If an **open PR** already addresses the issue, verdict KEEP and put the PR
number in `open_pr`. Merging the PR will close it.

- **Duplicates of older issues:** check a new issue against older open issues,
  especially skipped authors'. The older one is canonical; say in `notes` which
  details to carry over in a comment before closing the newer one.
- **Issues filed from a session ledger:** read the ledger's PR lines first.
  Many say "build after #X merges"; put that in `blocker`.
- **Needs a production check you can't run?** Verdict KEEP and start `notes`
  with `needs-prod-check:` and the exact query, rather than leaving it open
  silently.

## Part 2: priority (for KEEP verdicts)

Same 1–10 scale as the PR assessment (`assess-brief.md`, Part 2). **Higher means
more urgent and important.**

| Score | Meaning                                                                          |
| ----- | -------------------------------------------------------------------------------- |
| 10    | Production broken or bleeding right now.                                         |
| 9     | A live security, auth, money or legal exposure.                                  |
| 8     | A significant core-flow bug, a PII leak, or a hard deadline within a month.      |
| 7     | A clear bug with moderate reach, or a money edge case.                           |
| 6     | A minor bug on a secondary surface, or a typical requested UI change.            |
| 5     | A nice-to-have feature, a worthwhile refactor, or tech debt with a clear payoff. |
| 4     | Polish, tooling, docs.                                                           |
| 3     | Exploratory.                                                                     |
| 2     | Speculative or a far-off epic.                                                   |
| 1     | Barely worth keeping.                                                            |

**Verify the bug on main before scoring a bug report.** Reading the current
code is enough. A bug that no longer reproduces is a CLOSE (Fixed), not a low
score.

## Part 3: can an agent just build it?

For every KEEP scored **8 or above**, judge whether an agent could open a PR
for it without asking a human:

- `buildable: true` means the fix is clear from the issue and the code. It
  needs no product, design, copy or policy decision, no production
  configuration or secrets, and no third-party account setup. It is
  testable test-first.
- Otherwise `buildable: false`, and `blocker` says exactly what decision or
  access is missing.

## Output

End with one fenced `json` block: an array with one object per issue. **Also write that array to the results file the coordinator names** (e.g. `$SCRATCH/results/<group>.json`) and check it parses with `jq length`. The coordinator works from the files, not from your message.

```json
{"issue": 123, "verdict": "CLOSE" | "KEEP", "close_reason": "fixed|surface-gone|duplicate|obsolete|not-actionable|null", "evidence": "one or two sentences, written to be pasted as the closing comment, citing a PR, sha or path", "canonical": 456, "open_pr": null, "priority": 6, "priority_why": "one sentence", "buildable": null, "blocker": null, "notes": "files involved, sibling issues"}
```

Before the JSON, add up to five lines of **lessons** that would improve this
skill.
