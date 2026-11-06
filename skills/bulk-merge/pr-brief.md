# Bulk-merge brief: one PR, end to end

This is the brief each per-PR agent follows when it is spawned by `skills/bulk-merge`. The coordinator adds the PR number, its branch and PR-specific notes from triage. The examples say `main`; substitute the repo's default branch.

You own **one** open pull request. A coordinating agent makes the final merge or close decision from your report, so **do not merge the PR, do not close it, and do not enable auto-merge.** Everything else is yours.

Never edit or commit in the primary checkout. Project rules are in `CLAUDE.md` / `AGENTS.md`, so read them. These are the ones that bite here:

- **Work only in a git worktree.** Fetch the branch, then run `git worktree add .claude/worktrees/bm-<N> <branch>` from the repo root, and install dependencies inside it so the tests run.
- **Never rewrite history or skip hooks.** No rebase, amend or force-push, and no push to the default branch. Never use `--no-verify` on a code commit. The only sanctioned exception is the default-branch merge commit (see the `pr-merge-main` skill).
- **Test first** for every code change (the `test-driven-development` skill). Don't mock your own code.
- **No whole-project checks.** Run the narrowest tests for the files you touched and let the pre-commit hook lint them.
- **PR comments put each paragraph on one line.** GitHub renders a single newline as a line break.
- **No local dev server.** Many agents run at once, so ports and shared dev backends would collide. Verify behaviour on the PR's preview deploy instead: push, then wait for the redeploy.

## Steps

### 1. Orient

- `gh pr view <N> --json title,body,headRefName,commits,statusCheckRollup,comments,reviews`
- Inline review comments: `gh api repos/{owner}/{repo}/pulls/<N>/comments --paginate`
- Read the bot comments: the code review (findings tagged by severity, ending in `MAXIMUM_FIX_PRIORITY:`), the `<!-- ai-qa-review -->` QA comment, and any autofix-bot checklist or fix commits.
- Read any human comments too.

### 2. Relevance: is this still a real, unfixed problem on the current default branch?

`git fetch origin main`, then read the code on `origin/main` for the surface. Check:

- Did the default branch change the touched file or area since the branch point? `git log <merge-base>..origin/main -- <file>`
- Did another PR already fix the problem or remove the surface? `gh pr list --state merged --search ...`, and `git log -S '<selector or identifier>' origin/main` finds the commit that removed what the PR edits.
- Is the bug real in a normal browser? Automated screenshot tooling produces false positives. One example: a "seam" or cut-off `position: fixed` background in a full-page screenshot is a capture artifact, because Chromium paints fixed layers once, at the first viewport. Reproduce with ordinary viewport screenshots before trusting the PR body.

If the bug is already fixed, the surface is gone, or the change no longer makes sense: **stop here** and push nothing. Report `VERDICT: CLOSE` with concrete evidence — the commit or PR that fixed it, or what replaced the surface.

### 3. Merge the latest default branch

1. In the worktree, `git merge origin/main --no-edit` (with `--no-verify` on this merge commit only).
2. Resolve conflicts thoughtfully. Keep the default branch's newer work and re-apply the PR's intent on top of it. If the surface moved, re-derive the fix for the current code rather than replaying old numbers. If a fingerprint or snapshot test conflicts, recompute it from the merged file, then confirm the only difference from the default branch's value is this PR's.
3. Re-install dependencies — the default branch may have added some.
4. `git push`.

### 4. Address unaddressed review comments

List every finding from the code-review bot, the AI QA review, inline comments and humans. Decide for each one:

- it is already addressed, by an autofix commit or a later change
- it is worth fixing now
- it is not worth fixing, and you say why

Fix the ones you agree with, writing the test first. Use judgement: verify each finding against the actual code, and don't blindly apply XLOW nits that make the code worse.

### 5. Get CI green and re-run QA

Watch the checks on your latest head with `gh pr checks <N> --watch`, including any e2e and preview-deploy checks.

- **A check is red:** read the log with `gh run view <id> --log-failed`, fix the cause, and push a new commit.
- **A genuine flake, a run cancelled by a newer push, or an infra 5xx:** `git commit --allow-empty -m "chore: retrigger CI"` and push.
- **The PR shows no checks at all:** its head was probably pushed by a bot, and the `pull_request` runs are waiting at `action_required` (GitHub's approval gate). Your own push of the merge triggers normal runs.
- **You changed app code in step 4** (not just merged the default branch): comment `/qa-review` on the PR if QA does not re-run on push. Wait for the preview to redeploy your head before you comment, or it checks the stale build. Then address the real findings. QA usually checks the one configuration named in the PR, so an all-clear is not evidence for other themes or viewports.
- **The autofix bot may push.** `git pull --no-rebase` before every push and build on top of its work. Never race it.

### 6. Adversarial review

Follow the `adversarial` skill: behaviour first, then code.

**Browser QA on the preview deploy.** Find the preview URL where the deploy bot posts it. Before judging anything, make sure the preview is serving your head: a deploy bot's "updated for <sha>" is often GitHub's `refs/pull/<N>/merge` commit, not your head SHA. Check it with `git fetch origin refs/pull/<N>/merge` and confirm one of its parents is your head — or evaluate something only your new code produces, such as a computed style or a string in the served HTML.

Drive the browser with whatever the environment offers (a browser MCP, or a small Playwright script kept in your scratch directory, never in the repo). **Look at every screenshot you take.** A screenshot you did not look at proves nothing.

Cover these:

- **The original repro:** the exact route, theme and viewport from the PR body.
- **Every other theme** the app ships, at that viewport (if the app has themes).
- **Both sizes:** desktop around 1440×900 and mobile around 390×844.
- **Logged in and logged out:** an ordinary user, plus logged out where the route allows it.
- **Shared code:** every other surface that uses the changed selector or component. Find them with grep.

**Show the "before"** by injecting the old CSS (`page.addStyleTag`), by comparing against production for logged-out routes, or by using an older preview deploy that is still live.

**Measure layout fixes** with `getBoundingClientRect` rather than eyeballing, and use `document.elementFromPoint` sweeps to prove which layer is on top.

**Try to break it:** longer strings, more items, 320px widths, larger text-size settings, other identities.

#### Field notes

- **Sweep the whole matrix, not the one viewport in the PR body.** Fixes tuned on one viewport routinely fail elsewhere: cover widths from 320px to 1440px including the step just above the PR's breakpoint (a `≤500px` fix can leave the identical bug at 501–670px), every theme, every text-size setting, and production-length strings.
- **A fixed px offset beside a rem-sized element holds only at one text size.** Measure the gap at two text sizes and derive a `calc(<px> + <rem>)` offset that tracks it.
- **A breakpoint that shrinks text must reach as far as the collision does.** Score every width × text-size point against the default branch and reject any variant that is worse anywhere.
- **Measure contrast fixes in every theme, before and after**, and report the numbers. A token swap that fixes one theme usually lowers contrast in others. To get real rendered contrast over background images, screenshot the element with its text shown, then with its text transparent, and compare the pixels. Prefer a colour pairing the repo already guarantees with a test.
- **Measure against the clipping container**, not your wrapper — an `overflow-x: auto; max-width: 100%` wrapper can be narrower than the space the content visibly had.
- **Narrow table columns.** A rem font bump can make a header break mid-word in a `table-layout: fixed` column with `overflow-wrap: break-word`. Count lines with `Range.getClientRects()` to catch it; a px floor such as `max(0.66rem, 12px)` fixes the small case without growing the larger ones.
- **Glyph-rendering claims** ("a stroke vanishes"): headless Linux Chromium may not match macOS Chromium or WebKit at either pixel ratio. Measure before accepting them.
- **Injected CSS loses to scoped selectors.** Framework-scoped rules (`.x.<hash>`) beat a plain injected rule, so add `!important` and confirm a computed style changed, or the A/B silently measures the unchanged page. When you inject state into an element, keep its scoping class.
- **Forcing a 404:** add a glob route interception before the first navigation; an exact-URL route added later can miss the browser's memory cache.
- **Polling a bot that edits its comment in place:** poll on `updated_at`, not `created_at`.
- **Canvas overlays** have no DOM text, so text probes give false negatives. Probe the structure instead.
- **Shell:** macOS has no `timeout`; zsh does not word-split unquoted `$vars`, so run matrix loops under `bash -c` or use arrays; an unmatched zsh glob aborts the whole command, which can leave a test runner with no file list and running the entire suite.

**Adversarial read of the full diff.** Read every line of `git diff origin/main...HEAD` and look for:

- regressions on other themes, viewports or surfaces that share the selector
- CSS selectors that reach further than intended
- design tokens or variables that don't exist
- JS that can now throw, such as a guarded init whose object is still used unguarded elsewhere
- tests that would still pass with the bug present
- comments that are wrong
- speculative code
- a filter or sanitiser on values that must be echoed back exactly (ids, paths, names): it breaks the round trip

Change what should change, writing the test first. Push, then re-verify on the redeployed preview.

### 7. Finish

- **CI is green on the final head**: every required check, plus e2e and the preview deploy if the repo has them.
- **Post one PR comment titled "Bulk-merge review".** Keep it concise and cover: that the default branch was merged in; each review finding and what you did about it; what you exercised on the preview (themes, viewports, identities); what you changed and why; anything left for a human. Put each paragraph or bullet on one line.
- **Clean up the worktree:** `git worktree remove .claude/worktrees/bm-<N>`, then `git worktree prune`.

## Report back

The coordinator sees only this report, so be specific and honest:

```
PR: #<N> <title>
VERDICT: MERGE_SAFE | NEEDS_HUMAN | CLOSE
HEAD: <sha>   CI: <each required check: pass/fail>, e2e: <..>, preview: <deployed sha>
RELEVANCE: <still present on the default branch? evidence>
MAIN MERGE: <clean | conflicts + how resolved>
REVIEW COMMENTS: <each finding → disposition>
QA EXERCISED: <routes × themes × viewports × identities; key measurements; screenshot paths>
CHANGES I MADE: <commits + why>
RISK: <why this is (or is not) correct, harmless, and extremely low risk to merge>
FOR THE HUMAN: <decisions that are not yours: product copy, design calls, data fixes, etc.>
SKILL LEARNINGS: <gotchas worth adding to skills/bulk-merge>
```

Report `MERGE_SAFE` only when all of these hold:

- you verified the fix works on the preview
- you found no regression on any theme or viewport
- the diff is small and obviously correct
- CI is fully green
- you would bet on it

Anything less is `NEEDS_HUMAN`, with the reason. That includes a product, copy or design judgement call, a large or behaviour-changing diff, and anything you could not verify.
