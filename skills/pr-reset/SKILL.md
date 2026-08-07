---
name: pr-reset
description: >-
  Collapse a multi-commit PR into ONE clean commit on top of the latest default
  branch, open it as a fresh PR, and close the old one, so the repo's full
  commit-hook gate runs over the entire diff at once. Use when the user says
  "reset this PR", "restart the PR clean", "close and reopen this PR", "squash
  it to one commit", "get a full pre-push", or when a PR's history is full of
  bot-autofix or --no-verify commits that skipped the hooks. Takes a PR link, PR
  number, or branch name. Never force-pushes and never rewrites the old branch.
disable-model-invocation: true
argument-hint: '[PR-link | PR-number | branch-name]'
---

# PR Reset

Turn a messy, many-commit PR into a **single clean commit on top of the latest
default branch**, reopened as a **fresh PR**, with the old PR closed and the two
cross-linked.

Also answers to `pr-restart`, which is an alias for this skill.

## Why this exists

Commits reach a PR branch without ever passing the repo's commit hooks:

- an automated review-fix workflow pushes its own commits,
- `pr-merge-main` merge commits are made with `--no-verify` on purpose,
- anyone can hand-commit with `--no-verify`.

Whatever the repo runs on commit (pre-commit, husky/lint-staged, a formatter, a
linter) never saw those. CI may re-run some of it, but a bot commit landing
after the last green run can merge without the gate having seen it at all.

Squashing the whole PR into **one fresh commit** and committing it **normally
(hooks enabled)** makes those hooks run over the **entire accumulated diff at
once**, and lands the change as a single reviewable commit on the newest default
branch.

## The argument

`$ARGUMENTS` is any of:

- a full PR URL (`https://github.com/OWNER/REPO/pull/NNNN`)
- a bare PR number
- a branch name

Resolve it to `{ old_pr_number?, old_branch, base, title, body }`:

- **URL or number**: `gh pr view NNNN --json headRefName,baseRefName,title,body,state,mergedAt`
- **Branch name**: find its open PR with `gh pr list --head <branch> --json number,...`. If none exists there is no PR to close. Do the squash, open a new PR, and say there was nothing to close.

### Guards: stop and ask before proceeding

- **Merged PR**: already done, and merged history must never be reused. Tell the user and stop unless they confirm they want a brand-new follow-up PR.
- **Base is not the default branch** (a stacked PR): confirm the intended base first. Squashing a stacked PR onto the default branch folds in its parent's diff.

Your own working tree does not need to be clean. The squash is built in a fresh
worktree, so uncommitted and untracked files where you are standing are left
alone.

## Steps

### 1. Prepare the squashed branch

Pick a new branch name that will not collide. Append `-reset` to the old branch
name (`-reset2`, `-reset3`, and so on if taken), keeping whatever prefix
convention the repo uses.

```bash
skills/pr-reset/scripts/prepare-squash.sh <old-branch> <new-branch>
```

Read the script before running it. It:

1. Detects the default branch via `gh repo view --json defaultBranchRef`.
2. Fetches the default branch and `<old-branch>` fresh.
3. Creates `<new-branch>` in a **new git worktree** under `.claude/worktrees/`, off the latest default branch, so the checkout you are standing in is never switched out from under you or anyone else sharing it. It uses `git worktree add -b` (not `-B`), so a leftover branch from an aborted run fails loudly instead of being clobbered.
4. Runs `git merge --squash origin/<old-branch>`, which stages the **full net diff** including adds, deletes and renames. (`git checkout -- .` silently drops deletions, so it is never used.)
5. **Verifies nothing was lost** by comparing feature *contributions* rather than whole trees, so it holds even when the default branch has advanced. What the new branch adds over the latest default branch (`git diff --cached origin/<base>`) must equal what the old branch introduced over its merge base (`git diff origin/<base>...origin/<old-branch>`). The two are compared with `git patch-id --stable`, a content hash of the changed lines, so blob SHAs and line-number shifts from an advancing default branch do not cause a false mismatch. If they still differ, the script prints the delta and exits non-zero. Investigate before committing.

It stops **without committing**, leaving the whole diff staged in the worktree,
and prints the worktree path.

### 2. Commit normally, with the hooks on

```bash
cd .claude/worktrees/<new-branch-dir>
git commit -m "<same subject as the PR title>"
```

**Do NOT pass `--no-verify`.** The hook running here is the entire point.

Match the repo's own commit-message convention. Check `git log` if unsure.

- If a hook **auto-fixes** something, it re-stages the fix into this commit. Good. Confirm the commit still carries the change: `git diff origin/<base>...HEAD` against `git diff origin/<base>...origin/<old-branch>` should differ only by that formatting.
- If a hook **fails**, that is the problem the old history hid. Fix it properly and commit again, rather than adding a disable comment to get past it.
- **Watch what the hooks touch.** If a repo checks in generated or byte-exact files that its formatters would rewrite, revert those with `git checkout -- <path>` rather than shipping the rewrite.

### 3. Push the new branch

```bash
git push -u origin <new-branch>
```

Retry network failures with backoff (2s, 4s, 8s, 16s).

### 4. Open the fresh PR

Base the default branch, head `<new-branch>`. **Carry over the old PR's title and
body verbatim**, prepending a short note:

> Fresh single-commit reset of #OLD, squashed onto the latest default branch so
> the full commit-hook gate runs over the whole diff. Supersedes #OLD.

Create it ready for review, not a draft.

### 5. Close the old PR and cross-link

```bash
gh pr close OLD --comment "Superseded by #NEW, squashed to a single commit on the latest default branch for a full hook run. Closing in favor of that one."
```

Make sure the new PR's body says `Supersedes #OLD`.

Note: closing a PR tears down any per-PR preview or review app it had, and a
later reopen does not reliably bring it back. That is fine here because the work
moves to a new PR which gets its own, but it is a reason never to use
close/reopen on the *same* PR as a CI retrigger.

### 6. Report

Give the user both PR URLs, the new branch name, the commit SHA, and whether the
hooks changed anything or surfaced a real fix.

## Hard rules

- **Never force-push. Never rewrite the old branch.** Its history stays intact. You only close its PR. All cleanup happens on a *new* branch, which is what keeps this compatible with a no-rebase, no-force-push rule.
- **One commit.** The new branch is exactly the default branch plus one squashed commit, plus any hook auto-fixes folded into it.
- **Preserve the change.** The new branch's contribution over the latest default branch must equal the old branch's contribution, except for hook formatting and anything the newer default branch legitimately reworked. If unrelated content changed, something was lost. Stop and investigate.
- **Do not reuse a merged PR** for new work.

## Cleaning up

When the new PR is merged, remove the worktree:

```bash
git worktree remove .claude/worktrees/<new-branch-dir>
git worktree prune
```

## Related

- `pr-merge-main` merges the default branch **into** a branch and keeps history. Use that when you just need to be current. Use **this** when you want to collapse to one clean commit and re-run the full gate.
- `babysit` watches open PRs and nudges the review/fix/CI pipeline along.
