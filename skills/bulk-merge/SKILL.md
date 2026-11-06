---
name: bulk-merge
description: Take a whole group of open PRs (a label, a GitHub search query, a github.com pulls URL with ?q=, or explicit PR numbers) through triage, a default-branch merge, review-comment fixes, green CI and an adversarial review. Then merge the ones that are provably harmless, close the stale ones, and take the hard ones through local QA yourself and land them too. Only genuine blockers go back to the human. Use for '/bulk-merge <label|query|url>', 'go through all the PRs labelled X', 'bulk merge these', 'clear out the PRs tagged X'.
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, Skill
argument-hint: '<label | GitHub search query | github.com/.../pulls?q=... URL | PR numbers>'
---

# Bulk merge

Clear a backlog of related PRs — typically ones a scheduled bot filed (nightly QA findings, codebase-review fixes, dependency bumps) — in one pass. For **each** PR:

- **Stale:** close it.
- **Otherwise:** bring it up to date with the default branch, address its review comments, get CI green and review it adversarially. Then merge it, but only when it is correct, harmless and extremely low risk.

**Don't hand PRs back.** The ones the first pass can't clear go through a second pass: you run them locally, QA them hard, make the design call on measured evidence, fix them, and merge them (step 3). Hand back only a genuine blocker, as defined in step 3.

The examples below say `main`; substitute the repo's default branch.

**Argument:** `$ARGUMENTS` is one of:

| Form                         | Example                                                                 |
| ---------------------------- | ----------------------------------------------------------------------- |
| a label                      | `needs-merge`                                                           |
| a GitHub search query        | `label:needs-merge author:app/dependabot`                               |
| a github.com pulls URL       | `https://github.com/owner/repo/pulls?q=is%3Aopen+label%3Aneeds-merge`   |
| explicit PR numbers or a URL | `123 118 97`, `https://github.com/owner/repo/pull/123`                  |

`scripts/resolve-prs.sh "$ARGUMENTS"` turns any of these into open, non-draft PR numbers. If it returns nothing, say so and stop. If it returns far more than you expected (a query typo can match the whole repo), show the count and ask before going on.

## Merge authority — read this first

The default rule for agents is never to merge a PR unless the human explicitly authorises _that_ PR. **Invoking `/bulk-merge` is that authorisation, but only for PRs that clear the MERGE_SAFE bar below.** It does not extend to anything else:

- Squash merge only (or whatever single merge method the repo uses): `gh pr merge <N> --squash --match-head-commit <sha>`. Pin the SHA you reviewed. An autofix bot can push to a branch at any moment, and `--match-head-commit` refuses the merge if it did. Never use `--auto` or `--admin`.
- Never merge with a required check that is not SUCCESS on that exact head SHA.
- If you are unsure, you are not done. Take it through the local pass in step 3 until you are sure, and only then merge it.

**MERGE_SAFE** means all of these hold:

1. It still fixes a real bug on the current default branch (or is still wanted).
2. The default branch is merged in, and every required check is green on that head.
3. Every review comment has been addressed or deliberately declined, with a reason.
4. The adversarial pass watched it work (on the preview deploy, or locally) and found no regression on any viewport, theme, or identity it could reach.
5. The diff is small and obviously correct when you read it yourself. That means no data, schema, auth, billing or permission logic, no product copy or design call that belongs to a human, and nothing you could not verify.

Fail any one in the first pass and the PR goes to the local pass in step 3, not to the human. Design calls are yours to make once you have measured them: the human asked for the work to be done, not delegated back.

## Steps

### 0. Resolve and triage (you, the coordinator)

```bash
skills/bulk-merge/scripts/resolve-prs.sh "$ARGUMENTS" | xargs skills/bulk-merge/scripts/triage.sh
```

Pipe through `xargs` rather than `triage.sh $PRS`: zsh does not word-split an unquoted variable, so the whole list arrives as one argument.

`triage.sh` prints one line per PR: title, size, commits behind the default branch, whether it merges cleanly, the CI rollup, and which of its files the default branch has touched since it branched. Read the diffs yourself too (`gh pr diff <N> --exclude '*.png'`). They are usually small, and knowing them lets you give each agent pointed notes. Things to flag up front:

- **A conflict, or the default branch touched the same file.** The bug may already be fixed or the surface redesigned. These are the likeliest CLOSE candidates.
- **No checks at all** on the PR. This usually means a bot pushed the head and its `pull_request` runs are stuck at `action_required`. The agent's merge push triggers real runs.
- **Two PRs touching the same file.** They will conflict after the first one merges.
- **A guard that leaves its object used unguarded elsewhere.** For example, an object initialised only in development but still used unconditionally elsewhere.

#### Collapse duplicates before you fan out

Scheduled bots re-file the same fix when their last PR hasn't merged. They run against the default branch, so the gap still looks open, and one label can end up holding a dozen PRs for two findings. Fanning out one agent per PR there spends a dozen agents and CI runs, and the duplicates conflict with each other. So before step 1:

1. **Group PRs that fix the same thing.** Same finding or issue id, same route or selector, near-identical titles, or diffs that touch the same files the same way. Sorting the triage output by title and reading the PR bodies usually makes it obvious.
2. **Pick one canonical PR per group.** Take the newest, since it is closest to the default branch and was written against the current code, unless an older one is clearly better. Skim the others' diffs and review threads for anything the canonical PR lacks, and pass that on in the agent's notes.
3. **Close the rest now:** `gh pr close <N> --comment "Duplicate of #<canonical>, ..."`. First check that none has a human comment or review (`gh pr view <N> --json comments,reviews`). A human thread is a reason to read it before closing, not to keep a duplicate open.
4. **Fan out one agent per canonical PR,** not one per original PR.
5. **Fix the source.** When a bot filed the duplicates, find its workflow and find out why it re-files — usually it never checks for its own open PRs. Fix it in a separate PR: tell the bot which findings already have an open PR, have each PR name its finding in a body marker, and keep only the newest open PR per finding. Do this in the same run, or next week brings a fresh batch of duplicates.

### 1. Fan out: one agent per PR, in waves

Spawn one general-purpose agent per PR, in the background. Give each the brief at `skills/bulk-merge/pr-brief.md` (tell it to read the file) plus your PR-specific notes from triage. Run **waves of about 8**: every agent pushes and triggers a full CI run plus any preview deploy, and dozens at once starve everyone else's CI. When one agent finishes, start the next. Expect each agent to take 20–60 minutes, mostly waiting on CI and preview deploys.

Make the PR-specific notes pointed. Name:

- the exact risk you saw in the diff
- which default-branch commits moved the surface
- which sibling PR shares the file
- which identity or state is needed to reach the bug

When an agent reports a lesson the others would hit (a modal that blocks login, a banner that intercepts clicks), add it to the brief and tell the agents still running.

When two PRs fix the same kind of thing, merge the first and **message the other agent with the approach that landed**, so the two stay consistent.

Agents **never merge, never close, and never enable auto-merge**. They report a verdict (`MERGE_SAFE`, `NEEDS_HUMAN` or `CLOSE`) with evidence. The decision is yours, made in step 2.

Agents must not start local dev servers: with many running at once, ports and shared dev backends collide. They verify on each PR's preview deploy instead. (If the repo has no preview deploys, run the wave size down to what local ports and dev environments can support, and give each agent its own.)

### 2. Decide each PR as its report arrives

For every report:

1. **Re-check the facts yourself.** `gh pr view <N> --json headRefOid,statusCheckRollup,mergeable`. Confirm the head SHA matches the one the agent reported, the required checks are SUCCESS on it, and it is MERGEABLE.
2. **Read the final diff yourself:** `gh pr diff <N> --exclude '*.png'`. The agent's opinion is evidence; your own reading is the gate. Agents often rewrite the fix, and that is fine and usually better. Judge what will land, not the PR as it was filed.
3. **Look at the screenshots for anything visible.** When the report says the change is visible, open the agent's before and after images and look. Decide whether it is a plain improvement or a design call.
4. **Run an independent, read-only second reviewer** on every merge candidate, even "extremely low risk" ones — a fresh agent given only the diff, not the builder's conclusion. It routinely finds real bugs the builder's adversarial pass and the review bots both missed (e.g. a blanket filter that corrupted values a later step needed verbatim).
5. Then act:
   - **CLOSE:** `gh pr close <N> --comment "<what fixed it / what replaced the surface, with links>"`. Also look for older duplicates of the same bug that never got the label (`gh pr list --search '<surface> in:title'`), and close them when the fix merges.
   - **MERGE_SAFE, and you agree:** `gh pr merge <N> --squash --match-head-commit <sha>`. Afterwards, PRs still in flight that touch the same files need the default branch merged again before they merge.
   - **Anything else (`NEEDS_HUMAN`):** queue it for step 3 with the agent's reason.

### 3. Work the hard ones yourself, locally

Agents flag `NEEDS_HUMAN` for a design trade-off, a behaviour change on a shared component, or something they couldn't reach on the preview. Take each one through a local pass of your own, using the `adversarial` skill:

1. **Run it locally**, the way the repo's `CLAUDE.md` / `AGENTS.md` / README says. Use one stack for all of them: switch one worktree between the PR branches. Check ports are free first, and don't share a dev backend with another agent.
2. **Measure the trade-off the agent named.** For a colour or contrast question, measure every candidate in every theme the app ships, against the real rendered background, and choose the one with no theme below the bar rather than trading one theme against another. If every candidate fails in the same one or two themes, the theme's value is the bug: fix it there. For a layout question, sweep widths, text-size settings and themes. Measure every instance, not one — the same text can pass at the top of a page and fail at the bottom over a gradient.
3. **Fix the root cause when it is small.** A flash of the wrong message while data loads usually means a boolean reads `false` while it loads. Add a tri-state companion (`undefined` while loading) next to the boolean, derive the boolean from it so its consumers don't change, and switch only the surfaces that print the wrong message.
4. **Make the design call, commit test first, and push.** Then wait for green CI and merge with `--match-head-commit`.

Hand a PR back only for a genuine blocker:

- a product or strategy question (should this exist at all?)
- a data, schema, auth or billing logic change
- something irreversible
- something you still can't verify after the local pass

Say exactly which blocker it is.

Local-stack gotchas worth knowing:

- **Production-only branches.** Some code short-circuits to "allowed" in dev, so flag-off and no-access states are unreachable locally as built. Reach them by intercepting the module or request in your browser tooling, and say in the report that you did.
- **Switching branches in a shared worktree.** `git switch -c <b>` fails if a local branch `<b>` already exists, and your next merge then lands on the previous PR's branch. Check `git branch --show-current` before merging; reset an accidental local merge to `origin/<branch>` before pushing.
- **Clean up:** stop the servers and remove the worktree when you are done.

### 4. Report

Finish with lists, linking every PR:

- **Merged:** one line each, saying what it fixed. Mark the ones you reworked in the local pass and say what you decided.
- **Closed:** one line each, saying why it was stale or which PR it duplicated.
- **Source fixed:** the PR that stops a bot re-filing duplicates, if you made one.
- **Blocked (rare):** one line each, naming the blocker and the exact decision needed.

Then add a short **follow-ups** list. The adversarial passes keep turning up problems that already exist on the default branch next to the surface under review; they belong in issues rather than lost in agent transcripts. Offer to file them.

## Where the line falls

Calls like these mark where MERGE_SAFE ends.

**Merged in the first pass:**

- A layout fix the agent re-derived to hold at every width and text size, scoped to one route.
- A contrast fix that improves or holds legibility in every theme, even though the text colour visibly changes.
- A broken-image fallback that makes an intended placeholder visible.
- A dev-only debug panel gated off in production, after confirming every use of the gated object is optional-chained.

**Flagged by agents, taken through the local pass, then merged** (not handed back):

- A colour change that fixed one theme but regressed others, reworked until it held in every theme.
- A message that briefly showed the wrong state while data loaded, fixed with an explicit loading state.
- Design choices on shared components, each judged on screenshots across themes, widths and pixel ratios.

**Closed:**

- Already fixed by a later redesign: the PR's selector no longer exists on the default branch.
- Not a bug at all: the "bug" was a screenshot-tooling artifact, and the fix would have removed real content.
- A duplicate of a newer PR for the same finding: closed in triage, with a link to the canonical PR. Then the bot that filed it was fixed.

## Lessons from past runs

- **Some CI shards run long on a cold cache.** A PR whose other checks are green is usually just waiting. If a long shard is cancelled, retrigger it.
- **`--no-verify` is sanctioned on the default-branch merge commit only** (see the `pr-merge-main` skill). Never on a code commit.
- **AI QA may not re-run on push.** If `ai-qa-review.yml` fires only on PR open and ready-for-review, comment `/qa-review` after changing app code to re-run it on the new head. The PR-review autofix job can push after a QA run, so `git pull --no-rebase` before pushing again.
- **Check which commit the preview is on.** A deploy bot's "updated for <sha>" is often GitHub's `refs/pull/<N>/merge` commit, not the head. Check its parents, or evaluate something only the new code produces.
- **Bot-filed PRs often fix only the reported viewport and theme.** The same overlap still occurs one breakpoint up; a text fix fails at 320px or at larger text sizes; a contrast fix regresses the other themes. The matrix sweep in the brief is where the real fixes come from.
- **Some reported bugs are tooling artifacts.** Full-page screenshots paint `position: fixed` backgrounds only once, at the first viewport. Relevance includes "does this reproduce in a normal browser?".
- **Preview seed data is thin.** Production-shaped values (large counts, long names, broken avatars) may not exist there. Inject them through the DOM to exercise the layout, and say in the report that you did.
- **Your environment can drift under you.** Check the runtime version the repo pins against the one actually on your PATH before trusting local test results.
- **Bulk merges ripple.** Every merge moves the default branch. Re-merge it into any in-flight PR that touches the same file as one you just merged, and let CI re-run.
- **Filtering what a model or client must echo back is a bug.** Any filter or sanitiser on ids, paths or names that must be repeated exactly breaks the round trip. Warn reviewers about this class explicitly.
- **Several approved PRs on one hot file: build one integration branch.** The default branch plus all of them, opened as a "DO NOT MERGE" draft PR (CI runs on drafts). If it is green, merge each PR with `--match-head-commit` on its reviewed head, then close the integration PR. One CI cycle instead of N.
- **zsh merge loops:** `set -- $pair` doesn't word-split. Use a function with explicit args, and don't give it a one-letter name that can collide with an alias.
- **Late rounds of a sweep are mostly NEEDS_HUMAN** (billing, auth, privacy, legal), and still worth it: each comes back merged with the default branch, green and proven red/green, often with a real bug fixed along the way.
