---
name: pr-restart
description: >-
  Alias for the pr-reset skill. Collapse a multi-commit PR into ONE clean commit
  on top of the latest default branch, open it as a fresh PR, and close the old
  one, so the repo's full commit-hook gate runs over the entire diff at once.
  Use when the user says "restart this PR", "reset this PR", "close and reopen
  this PR", "squash it to one commit", or when a PR's history is full of
  bot-autofix or --no-verify commits that skipped the hooks.
disable-model-invocation: true
argument-hint: '[PR-link | PR-number | branch-name]'
---

# PR Restart

This is an alias. The skill lives at `pr-reset`.

Read `skills/pr-reset/SKILL.md` and follow it exactly, passing `$ARGUMENTS`
through unchanged.

Both names exist because this workflow is called `pr-restart` in the
`core-nexus/core` repo and `pr-reset` in `aistrology/aistrologer`, and either
should work in either place.
