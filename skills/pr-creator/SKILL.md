---
name: pr-creator
description: Use when completing work on a git branch that should be submitted as a pull request. Auto-activates when pushing commits, finishing tasks, or when asked to 'create a PR', 'make a pull request', or 'open a PR'. Gathers context, drafts a description that renders correctly on GitHub, and creates the PR with the GitHub CLI (or hands back a manual PR link).
allowed-tools: Bash, Read, Glob, Grep
---

# Pull Request Creator

Turn a finished branch into a pull request: gather context from its commits and diff, draft a description a reviewer can trust, and open the PR.

## When to Use

- Pushing commits to a feature branch
- The user says "create a PR", "make a pull request", "open a PR"
- Finishing implementation work that needs review
- The user asks "are we ready for a PR?"

## Step 1: Verify Branch State

```bash
DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)"
git branch --show-current                    # must NOT be $DEFAULT_BRANCH
git status                                   # working tree clean?
git ls-remote --heads origin "$(git branch --show-current)"
```

Requirements:

- On a feature branch, never the default branch. If you are on the default branch with unpushed commits, create a branch first and move the commits there.
- Working tree clean. If there are uncommitted or untracked files that don't obviously belong to this change, **ask** before leaving them out — never silently skip a file.
- Branch pushed: `git push -u origin HEAD`.

## Step 2: Gather Context

```bash
git log "origin/$DEFAULT_BRANCH..HEAD" --oneline
git diff "origin/$DEFAULT_BRANCH...HEAD" --stat
git log -5 --oneline          # the repo's commit/title style
ls .github/pull_request_template.md .github/PULL_REQUEST_TEMPLATE* 2>/dev/null
```

Extract: every commit in the PR, the files changed, the nature of the change (feature, fix, refactor, docs), and the repo's title convention. If the repo has a PR template, fill it in rather than replacing it.

## Step 3: Draft the Description

**Describe the end state, not the history.** The description tells a reviewer who never watched the work what the PR does now and why. Don't write "first we tried X, then switched to Y", "the previous commit only moved the file", or "this started as A and grew into B" — that is history and belongs in commit messages, if anywhere. When the PR changes later, rewrite the description (and title) to match; don't append a changelog.

**One line per paragraph.** GitHub renders a single newline inside a paragraph in a PR body or comment as a hard line break, so hard-wrapped prose (the ~76-column wrapping most editors and heredocs produce) renders as a shredded stack of short lines. Put each paragraph on ONE line, a blank line between paragraphs, and each list item on its own single line. This applies only to GitHub-rendered PR/issue/comment text — not to commit messages or committed `.md` files.

Default sections:

```markdown
## Summary

One or two sentences on what changed and why it matters.

- Bullet per notable change, focused on the why and the impact
- Call out breaking changes prominently

## What Changed

- `path/to/file`: what changed there and any non-obvious decision

## Test Plan

- [x] Targeted tests for the changed code (name them)
- [x] Manual check of the main flow
- [ ] Anything not yet verified, said plainly
```

See `references/pr-templates.md` for variants (bug fix, refactor, docs, dependency update, performance).

## Step 4: Create the PR

```bash
gh pr create --title "<title>" --body-file /path/to/body.md
```

Writing the body to a file and using `--body-file` avoids shell-quoting surprises; the one-line-per-paragraph rule still applies inside that file. If the repo or the user wants attribution lines at the end of the body, add them there.

**If `gh` is not available:** give the user the PR-creation URL from the `git push` output, show the formatted description for them to paste, and say which base branch to pick.

## Step 5: Verify and Report

- Report the PR URL as a clickable link.
- Summarize what was included.
- Note follow-ups, and watch CI if the repo's workflow expects you to (see the "Landing the Plane" section of `AGENTS.md`, if present).
- Do **not** merge the PR or enable auto-merge unless the user explicitly asked for that PR to be merged.

## Title Guidelines

- Follow the repo's existing convention (check `git log`; many repos use Conventional Commits like `feat: …`, `fix(scope): …`).
- Imperative mood ("Add export", not "Added export"), at most ~72 characters.
- Say what the PR does, not how it was built.

## Error Handling

- **No default branch found:** `git branch -r`, then ask the user for the base.
- **`gh` missing or unauthenticated:** fall back to the manual link (Step 4).
- **Unpushed commits:** `git push -u origin "$(git branch --show-current)"`, then retry.
