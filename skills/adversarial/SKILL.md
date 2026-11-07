---
name: adversarial
description: Hammer on an open PR in a real browser until it breaks, fix what breaks in the PR, then adversarially review every line of its diff and change what should change. Use for '/adversarial <PR>', 'QA this PR hard', 'try to break this', 'bang on this feature', or when handed a PR link and asked to review it properly.
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
argument-hint: '<PR_URL_OR_NUMBER_OR_BRANCH_NAME>'
---

# Adversarial

Take one open PR and try to break it. Then fix what broke, then read every line of its diff looking for what should change on the code side, and change that too — **all in the existing PR, never a new one.**

**Argument:** `$ARGUMENTS` — a PR URL, a PR number, or a branch name.

This is not a code review with a browser attached. The order matters: **behaviour first, code second.** Reading the diff before you have watched the feature run biases you toward what the author was thinking. Watching it run first tells you what the code actually does, and every finding you carry into the review is then anchored to something you saw.

## The loop

```
0. Read the PR + any handoff notes    → know what is supposed to work
1. QA on the PR's preview deploy      → cheap, no port contention, real deploy
2. Found something? go local          → fast iteration, fix + verify
3. Back to 1 until you are HAPPY      → not "no crashes" — happy
4. Adversarial read of the whole diff → change what should change
5. Land it in the SAME PR, CI green
```

Steps 1–3 are a loop. Do not start step 4 until you would be comfortable shipping the behaviour.

If the repo has no per-PR preview deploys, skip straight to a local stack in step 2 and run the same QA there.

---

## 0. Orient

```bash
gh pr view <N> --json title,body,headRefName,statusCheckRollup,comments
git worktree add .claude/worktrees/<short-name> <branch>
```

Always a worktree — other agents or developers may be working in the same checkout.

Read, in this order:

1. **The PR body.** Especially any "known gaps" or "not verified" section — that is the author telling you where to aim.
2. **Any handoff notes the PR added.** A handoff written by an agent with no browser is a list of things nobody has ever seen work. Every "I could not verify this" is a test case.
3. **The existing review comments** (the `claude-pr-review.yml` review, the `<!-- ai-qa-review -->` QA comment, humans). The bots have already found the easy things. Your job is what they cannot see: behaviour, and judgement about design.
4. **The diff**, once, quickly — enough to know what surfaces exist. The careful read comes in step 4.

Then list the surfaces. A PR that says "one feature" usually ships six. Write them down; you are going to exercise each one.

---

## 1. QA on the preview deploy

Find the PR's preview URL wherever your deploy bot posts it (often a PR comment). Start there — it is a real deploy, it costs nothing, and it does not fight another agent for a port.

**Make sure the preview is serving the head you are judging.** Deploy bots often build GitHub's `refs/pull/<N>/merge` commit rather than the head SHA. Check that one of that commit's parents is the head, or better, evaluate something only the new code produces (a string in the served HTML, a computed style).

### First: is the feature reachable at all?

**Check this before you conclude anything works or does not.** A feature behind a feature flag, an access check, or an environment variable can be completely invisible on a preview for reasons that have nothing to do with the code — for example, a secret the flag service needs that exists in production but not in preview, so every flagged surface is dark.

Compare what the preview deployment actually has with what production has (env var names, not values) instead of assuming. If the feature is unreachable on preview, **that is itself a finding** — preview is where QA happens, so a feature that cannot be enabled there cannot be QA'd. Fix the code or the deploy config so it can be, rather than hand-patching one deployment.

### Test as more than one identity

The interesting bugs live in the gaps between identities. Use whatever test accounts your repo provides (seeded test accounts, fixtures, a staging login) to cover at least:

- a **privileged** account (staff/admin — sees flagged or gated surfaces)
- an **ordinary user** (must see the app unchanged — this is the "safe for everyone else" story)
- a **brand-new signup** (no name, no data, no history)
- a **returning, fully-set-up user** (already has everything)
- **logged out** (the deep-link and crawler path)

For example, a fix can work for a brand-new signup while sending a returning user back to the start of a flow. Same root cause, opposite symptoms, and neither shows up if you only test as yourself.

### Try to break it

Aim at the seams, not the happy path:

- **Hand-edit the URL.** Garbage where an id goes. A well-shaped id that is not a real one. More ids than the cap allows. Percent-encoded delimiters. An empty value. Someone else's id.
- **Do it twice.** Every "fires once" claim — a notification, an attribution, a grant — deserves a second and third arrival. Then check the row count.
- **Do it as the wrong person.** Open your own share link as yourself. Call a gated action as an ordinary user.
- **Interrupt it.** Reload mid-flow. Navigate away and come back. Use the back button after a history write-back.
- **Look at what a crawler sees**, not at what the route renders (see below).

### Evidence techniques that pay for themselves

**Read the data directly** instead of inferring from the UI: query the preview's database or backend with the repo's CLI or admin tooling, and count the rows a "fires once" action produced.

**Ask the backend what the client actually saw.** When the UI does something you cannot explain, call the same API the page calls, as the logged-in user (reuse the session token from the page), and look at the raw response and any server-side log lines that come back with it. This is how you tell "the code decided wrong" from "the code was handed the wrong data", and how you catch a request that succeeds while logging an error every time.

**Fetch the real social card, not the route that feeds it.** They are different things and only one of them lands on someone's timeline:

```bash
curl -sA "facebookexternalhit/1.1" "$PREVIEW/<path>" | grep -oE '<meta property="og:[^>]*>'
curl -s -o card.png -w "%{http_code} %{content_type} %{size_download}\n" "<the og:image URL>"
```

Then **open the PNG and look at it.** A route can render perfectly while the delivered image differs from it (wrong size, cropped). Looking at the route would never show it.

**Watch the browser console and the server log.** An error logged once per page view is a finding even when nothing visibly breaks.

---

## 2. Go local when you find something

The moment you have something to fix, stop iterating against the preview — a deploy cycle per attempt is intolerable. Start a local stack in your worktree, the way the repo's `CLAUDE.md` / `AGENTS.md` / README says.

- **Check ports first, never assume** (`lsof -nP -iTCP:<port> -sTCP:LISTEN`). Start on a free one.
- **Do not share a dev backend with another agent's server.** Many dev setups push your branch's backend code to the shared dev deployment on start, replacing theirs. Use a spare dev environment if the repo provides one.
- **Capture the server log to a file** so you can grep it (e.g. wrap the command with `script`).
- **A long-idle dev environment can refuse your branch** (stale data that no longer matches a narrowed schema, a missing required env var). A scratch dev environment holds nothing precious: reset and re-seed it rather than fighting it — never do that to a shared or production environment.

### Fix it properly

Every fix goes through the `test-driven-development` skill: **failing test first**, then the change, then watch it pass. A browser repro is not a regression test — write the unit test that pins the rule, and keep the browser for confirming the whole path.

Then re-run the flow in the local browser and confirm with your eyes.

### Verify, then commit

Run the **narrowest** test suites that cover your change, plus any suite the PR body or handoff names as a regression guard. Leave whole-repo lint/type/build to the pre-commit hook and CI.

Commit and push as you go. Let the pre-commit hook run — it catches things a passing test suite does not (a lost type narrowing inside a new closure; a helper that pushes a function past a complexity limit). When it fails, fix the cause — refactor under the threshold; never disable a metric rule, never `--no-verify`.

---

## 3. Loop until you are happy

Not "until the tests pass". Until you have watched every surface the PR ships behave correctly, as each identity that matters, including the ones you had to fix.

Before moving on, re-verify **on the preview** anything you could only fix locally — especially rendered output (social cards, screenshots, themes), which depends on deploy-time configuration the local stack does not have.

---

## 4. Adversarial read of the diff

Now, and only now, read every line:

```bash
git diff origin/main...HEAD   # substitute your default branch
```

You are not looking for bugs any more — you found those with the browser. You are looking for **what should change on the code side**. The things worth changing, roughly in order of how often they turn up:

- **Speculative flexibility.** A parameter with a default that no caller passes. An option nobody selects. Tests written for a code path that exists only for those tests. Prefer required parameters and no configurability nobody asked for. Delete it, and the tests that only covered it.
- **A helper that does more than its callers use.** A wrapper that computes a value one of its three callers throws away.
- **Work repeated per interaction.** A subscription or query derived from something a new write-back now mutates on every edit — torn down and rebuilt for data nothing reads.
- **Prefix matching on a path that gates auth.** `startsWith('/admin')` also matches `/administrator`. Match exactly, or on a delimiter, the way neighbouring cases usually already do.
- **Untrusted input reaching a strict validator.** Anything off a URL that lands in a strict id/type validator should be accepted as a string and normalized (returning "not found" on a bad value). A strict validator here turns a hand-edited link into an error report per crawl.
- **Inconsistent failure posture between two surfaces doing the same thing.** One degrades gracefully, its twin throws. Pick the better one and apply it to both.
- **Local state committed before the server agrees.** Marking something complete in the client before the request resolves leaves the UI claiming something the backend rejected.
- **An error logged on a path that runs per page view.** Correct to alert, wrong to alert at that frequency. Dedupe per process — and be honest in the comment that it is best-effort.
- **Comments that assert something you just disproved.** A wrong comment is worse than none; it is what the next reader will trust.
- **A filter or sanitizer on values that must round-trip exactly** (ids, paths, names a model or client has to echo back). It silently breaks the round trip.
- **Checked-in generated files.** Regenerate and diff — but commit only the entries **this branch** causes. If the generator also wants entries that are missing on the default branch, that is a pre-existing gap; leave it and say so.

What NOT to change: anything the author argued for in a comment and pinned with a test, unless you can say concretely why it is wrong. A documented decision you merely disagree with is a note in your summary, not a commit.

Make the changes. Same TDD rule, same test-then-commit rhythm.

---

## 5. Land it

- **The same PR. Always.** Push to the existing branch; never open a second PR for the fixes.
- **Do not race the autofix bot.** After a push, the review workflows run and may push fixes for findings at or above `MAXIMUM_FIX_PRIORITY`. Wait a few minutes, `git pull --no-rebase`, and build on top of its work.
- **Re-run QA after app changes.** If the repo's QA review does not re-run on push, comment `/qa-review` once the preview has redeployed your head.
- **CI green before you call it done.** Diagnose real failures; retrigger genuine flakes with an empty commit (`git commit --allow-empty -m "chore: retrigger CI"`).
- **Clean up:** stop any dev server you started, then `git worktree remove` + `git worktree prune` when the branch is done.

Report back with: what you exercised and as whom, what broke and how you fixed it, what you changed in the code review and why, and — separately — anything you found that is **not yours to decide** (a production feature flag that needs creating, a rollout plan, a design asset, product copy). Those are the author's call. Say so plainly instead of quietly doing them or quietly skipping them.
