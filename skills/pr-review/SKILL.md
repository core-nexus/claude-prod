---
name: pr-review
description: Review a PR or branch in an isolated git worktree, then fix HIGH and MEDIUM findings TDD-style on the PR branch. Triggers on '/pr-review <PR_URL_OR_NUMBER_OR_BRANCH_NAME>', 'review this PR', 'code review branch X', or completing work that needs review-then-fix.
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent
argument-hint: '<PR_URL_OR_NUMBER_OR_BRANCH_NAME>'
---

# PR Review

Review a PR or branch against the default branch in an isolated worktree, **then fix every HIGH and MEDIUM finding on the PR branch**. Fixes are made with the `test-driven-development` skill.

Uses the same five-level severity scale as `.github/workflows/claude-pr-review.yml` and `codebase-review.yml`: `NONE`, `XLOW`, `LOW`, `MEDIUM`, `HIGH`. The fix threshold matches the workflows' default `MAXIMUM_FIX_PRIORITY` of `MEDIUM` — fix HIGH and MEDIUM, leave LOW and XLOW for human follow-up.

**Argument:** `$ARGUMENTS` — a PR URL (e.g. `https://github.com/owner/repo/pull/123`), a PR number (`#123` / `123`), or a branch name.

## ⚠️ This skill MUST fix HIGH and MEDIUM findings, not just report them

The skill is **not done** when the review report is written. It is done when:

1. Every HIGH finding that survives verification has a fix committed to the PR branch.
2. Every MEDIUM finding that survives verification has a fix committed to the PR branch.
3. Each fix has a failing-test-first regression test (TDD), now passing.
4. The fixes are pushed to `origin/<PR-branch>` (NOT a new branch, NOT the default branch).

**A "review only, no fixes" outcome is a failure of this skill** — unless every HIGH/MEDIUM finding was dropped during Step 3 verification (with reasoning recorded), or branch permissions genuinely block the push (a cross-fork PR you can't push to). In that case, say so explicitly in the report.

If you find yourself about to reply with a list of findings and stop: don't. Keep going through Steps 4–6.

## Companion skill (load before reviewing)

1. `test-driven-development` (+ its `testing-anti-patterns.md`) — required for any fix: failing test first, then minimal implementation.

Also re-read the repo's own conventions (`CLAUDE.md` / `AGENTS.md`, contributing docs) before touching code. The review applies them.

## Step 0 — Resolve the target

From `$ARGUMENTS` derive:

- `PR_NUMBER` (if a PR URL or `#NNN`) — use `gh pr view` to get `headRefName`, `baseRefName`, `headRepository`.
- `BRANCH` — branch to check out for review.
- `BASE` — base branch. For PRs use `baseRefName`; otherwise the repo's default branch (`gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`).

```bash
git fetch origin
gh pr view "$PR_NUMBER" --json number,title,url,headRefName,baseRefName,headRepository,isCrossRepository
```

If no `$ARGUMENTS` was supplied, ask which PR/branch to review and stop until answered.

## Step 1 — Set up an isolated worktree

**Never review or fix in the primary checkout.** Use a git worktree.

Pick a worktree path. Preference order, first that's already gitignored wins:

1. `.claude/worktrees/<safe-branch>`
2. `.worktrees/<safe-branch>`
3. `worktrees/<safe-branch>`
4. A directory under your system temp dir (fallback, always safe)

Before using a repo-local path, confirm its parent directory is gitignored (`git check-ignore -q <dir>`). If none is ignored and you want repo-local, add the chosen entry to `.gitignore` first (single-line append, no other edits). Otherwise use the temp-dir fallback.

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
SAFE_BRANCH="$(echo "$BRANCH" | tr '/' '-')"
WORKTREE="<chosen path>/${SAFE_BRANCH}"

if [ -d "$WORKTREE" ]; then
  git -C "$WORKTREE" reset --hard HEAD && git -C "$WORKTREE" clean -fd
  git -C "$WORKTREE" checkout "$BRANCH"
  git -C "$WORKTREE" fetch origin
  git -C "$WORKTREE" reset --hard "origin/$BRANCH"
else
  git -C "$REPO_ROOT" worktree add "$WORKTREE" "$BRANCH"
fi
```

For cross-repo (fork) PRs, run `gh pr checkout "$PR_NUMBER"` — but still inside a worktree, not the primary checkout.

## Step 2 — Review pass

Review `origin/$BASE...HEAD`:

```bash
BASE_SHA=$(git -C "$WORKTREE" merge-base "origin/$BASE" HEAD)
HEAD_SHA=$(git -C "$WORKTREE" rev-parse HEAD)
git -C "$WORKTREE" diff --stat "$BASE_SHA..$HEAD_SHA"
git -C "$WORKTREE" diff "$BASE_SHA..$HEAD_SHA"
```

Review the diff. Focus on production-impacting issues:

- Correctness, logic bugs, race conditions
- Auth / authorization bypasses
- Data loss, irreversible state changes
- Data-access patterns: unbounded queries, missing indexes, N+1 reads
- Missing or swallowed error handling — violations of the fail-fast rules in `CLAUDE.md` / `AGENTS.md`
- Non-deterministic idempotency keys on anything that charges, grants, or sends
- Missing tests for new behavior
- Any rule the repo's own instructions state explicitly (storage rules, framework conventions, style rules)

Categorize each finding using the same scale as the GitHub workflows (lowest → highest):

- **NONE** — no code change needed.
- **XLOW** — trivial nit not worth a fix cycle.
- **LOW** — minor issue worth fixing but not blocking merge.
- **MEDIUM** — real issue (missing error handling, missing tests, architecture problems). **Fix it.**
- **HIGH** — critical (security, data loss, broken logic, auth bypass). **Fix it.**

Set **MAXIMUM_FIX_PRIORITY** to the SINGLE HIGHEST severity across all findings (the same rule `claude-pr-review.yml` uses). Fix every HIGH and MEDIUM finding; skip LOW and XLOW unless the user explicitly asked for them.

For larger diffs, dispatch the review through the Agent tool (a general-purpose or code-review subagent) so the main session keeps context. Pass `BASE_SHA`, `HEAD_SHA`, what was implemented, and the requirements.

## Step 3 — Verify each finding

Before fixing anything, walk every HIGH and MEDIUM finding through this filter:

1. Restate the finding in your own words.
2. Open the actual file/line and confirm the issue exists in the current code.
3. YAGNI check — is the affected code reachable / used? `grep` for callers.
4. Context check — is there a reason the current implementation looks the way it does (legacy, compatibility, a documented decision)?
5. If the finding is wrong, log a short technical pushback in the report and drop it.

**No performative agreement, no blind implementation.** Drop findings that don't survive verification.

## Step 4 — Fix surviving findings on the PR branch (TDD) — REQUIRED

This step is **mandatory**. If any HIGH or MEDIUM finding survived Step 3, you fix it here. Reporting findings without fixing them is a skill failure (see the callout at the top).

For each fix:

1. Write a failing regression test first, in the repo's existing test layout.
2. Run the test and confirm it fails for the expected reason.
3. Implement the minimal fix.
4. Run the test again and confirm it passes.
5. **No mocking internal code.** Mock only at external service boundaries (third-party SDKs, `fetch` to a third-party API).
6. Honor the repo's `CLAUDE.md` / `AGENTS.md` conventions.

Make the fixes directly on the PR branch in the worktree. Do **not** create a separate fix branch unless branch protection prevents pushing (e.g. a cross-fork PR you can't push to — in that case, document and stop).

## Step 5 — Verify

Inside the worktree, in this order:

1. Targeted tests for the files you touched (a single test file or a test-runner filter).
2. Lint / type-check scoped to the files you touched, if the repo's tooling allows it. Leave whole-repo scans to the pre-commit hook and CI unless the repo's instructions say otherwise.
3. Skip a full build unless the change is build-affecting.

If dependencies are not installed in the worktree, check whether the primary checkout's install can be reused. If a real install is needed and it would write a lockfile or run install scripts, ask the user first.

If a verification step is skipped, say so explicitly in the report — don't pretend it ran.

## Step 6 — Commit and push to the PR branch

```bash
git -C "$WORKTREE" add <files>
git -C "$WORKTREE" commit -m "fix: <concise description>

<longer reasoning if useful>"
git -C "$WORKTREE" push origin "$BRANCH"
```

Rules:

- Never push to the default branch.
- Never `git rebase`, `git commit --amend`, or force-push.
- Preserve unrelated local changes — never `reset --hard` past the user's work in the primary checkout.
- Don't bypass hooks (`--no-verify`).
- If an automated review-fix bot also pushes to this PR, `git pull --no-rebase` first and build on its commits.

For a cross-fork PR you can't push to, stop and report — don't open a new PR without permission.

## Step 7 — Report

Reply with:

- **Reviewed range** — `BASE_SHA..HEAD_SHA`, file count, line count
- **MAXIMUM_FIX_PRIORITY** — single highest severity across all findings (`NONE` / `XLOW` / `LOW` / `MEDIUM` / `HIGH`)
- **Confirmed findings** — HIGH and MEDIUM that survived Step 3, with file:line and severity tag
- **Dropped findings** — what was rejected and why (YAGNI, wrong, documented decision)
- **Fixes made** — one bullet per fix, naming the test that now passes
- **Verification run** — commands actually executed, with pass/fail
- **Skipped verification** — anything not run, with the reason
- **PR URL / branch pushed** — a clickable PR link if applicable
- **Worktree path** — so the user can re-enter or clean up

## Anti-patterns (don't do these)

- **Stopping after the review with findings unfixed** — the skill is review _and_ fix
- Reviewing or fixing in the primary checkout instead of a worktree
- Mocking internal modules in new tests
- Rewriting unrelated code while "in the area"
- Adding features not requested
- Suppressing warnings, removing failing tests, or bypassing CI to make things green
- Using `git rebase`, `commit --amend`, or `push --force` anywhere
- Silently dropping a finding without recording the pushback in the report
- Claiming a verification step ran when it didn't

## Priority

This review/fix workflow takes priority over older in-flight tasks for the same PR. If a previous task in this session is still working on the same branch, interrupt it and fall through to this skill.
