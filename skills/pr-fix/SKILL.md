---
name: pr-fix
description: Read the review comments on a PR, fix every issue rated LOW or above, then push and keep fixing until CI is green
allowed-tools: Bash(gh *),Bash(git *),Read,Edit,Write,Grep,Glob,Skill
argument-hint: '<PR-number>'
---

Fix review issues on PR `$ARGUMENTS`. You are a fixer, not a reviewer — your output is code changes, not commentary. If you finish without making any git commits, you have failed.

This is the hands-on, local counterpart of the `/claude-fix` comment command in `claude-pr-review.yml`. The workflow auto-fixes findings at or above `MAXIMUM_FIX_PRIORITY` (default `MEDIUM`); when a human invokes this skill, fix **LOW** and above too.

## Step 1 — Merge the default branch and resolve conflicts

Before doing anything else, bring the branch up to date. Stale branches cause false CI failures and merge conflicts that mask real issues.

Run `/pr-merge-main $ARGUMENTS` (the `pr-merge-main` skill) to merge the default branch into the PR branch and resolve any conflicts. Work in a git worktree, never by switching the primary checkout's branch.

If the merge brought in changes that already fix some review findings, note that — fewer things to fix by hand.

## Step 2 — Read the review (MANDATORY)

```
gh api --paginate "repos/{owner}/{repo}/issues/$ARGUMENTS/comments?per_page=100"
gh api --paginate "repos/{owner}/{repo}/pulls/$ARGUMENTS/comments?per_page=100"   # inline review comments
gh pr diff $ARGUMENTS
```

Find the latest review comment with numbered findings and severity levels (the one ending in `MAXIMUM_FIX_PRIORITY:<LEVEL>`), plus the latest `<!-- ai-qa-review -->` QA comment if the repo runs QA review. If such comments exist, you MUST fix every issue rated LOW or above.

**"CI is green" does NOT mean the review is addressed.** CI checks lint/types/tests — it does not catch the logic errors, security issues, or architectural problems the review identified. Fix review findings even when CI is green.

Verify each finding against the actual code before changing anything: a finding that is wrong gets a one-line technical pushback in your final comment, not a change.

## Step 3 — Gather additional context

a) Check CI status: `gh pr checks $ARGUMENTS`. If any jobs failed, read their logs (`gh run view <RUN_ID> --log-failed`). Every required check must pass.

b) Find the repo's quality gates — `CLAUDE.md` / `AGENTS.md`, the CI workflow files, and the package manifest's scripts — and run the **narrowest** ones that cover the code you will touch (the targeted tests for those files, a linter scoped to those files). Don't run whole-repo lint/type/build scans unless the repo's instructions say to; the pre-commit hook and CI own those.

c) Read the PR diff. If you spot obvious bugs, missing error handling, or missing tests, fix them even if no review mentioned them.

## Step 4 — Fix everything

Edit files. Write tests. Fix lint/type/test errors.

Rules:

- Do NOT skip hard fixes — that's exactly why automation is fixing it.
- Tests are MANDATORY if the review flagged missing tests or you changed logic lacking coverage. Write the failing test first (the `test-driven-development` skill). Mock only external service boundaries, never your own modules.
- Fix tests correctly: if a test fails, decide whether the implementation or the test is wrong. NEVER delete or skip a test to make CI green. NEVER weaken assertions.
- Priority order: security > correctness > performance > tests > style.

## Step 5 — Verify locally

Re-run the targeted tests and checks from Step 3 and fix any failures. Repeat until they pass. Do NOT push until they do.

## Step 6 — Commit and push

- Each commit message explains what was fixed and why.
- Reference review item numbers (e.g. `fix 3): add missing auth check`).
- Do NOT write `#` followed by a number in commit messages — GitHub turns it into an issue link. Use `1)`, `3)`, etc.
- Commit normally so the pre-commit hook runs — never `--no-verify` on a code commit.
- Push new commits to the PR branch. NEVER force-push, rebase, or amend.

If the repo runs an automated review-fix bot on the same PR, `git pull --no-rebase` before every push and build on top of its commits rather than racing it.

## Step 7 — Wait for CI and fix until green (max 3 iterations)

1. Wait ~60s for CI to start.
2. Poll: `gh pr checks $ARGUMENTS --watch --fail-fast`.
3. All pass → done.
4. Any fail → read the logs (`gh run view <RUN_ID> --log-failed`), fix, re-run the local checks, commit and push, repeat. A genuine flake or a run cancelled by a newer push gets an empty retrigger commit (`git commit --allow-empty -m "chore: retrigger CI"`), not a code change.

After 3 iterations, if still red, post one PR comment explaining what you tried and what is still failing (each paragraph on a single line — GitHub renders a hard wrap as a line break).
