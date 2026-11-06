# AI Agent Instructions

<!--
  This file is the canonical AI-agent instruction document. If your tools expect
  other filenames (e.g. CLAUDE.md, GEMINI.md), make those symlinks to this file so
  each vendor finds its expected name — edit this file and the others follow. Do
  NOT replace the symlinks with copies.
-->

## Working Principles

Behavioral guidelines that apply to every coding task, designed to reduce common
LLM coding mistakes. They bias toward caution over speed — for trivial tasks, use
judgment.

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.
- **Don't assume who you're working with.** A repo may have several contributors.
  Don't guess at the author of a spec or the person giving you direction — if a
  task involves crediting or addressing someone and you don't know who, ask.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios (see "Fail Fast, Fail Loud").
- If you write 200 lines and it could be 50, rewrite it.

Ask: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it — don't delete it.
- Remove imports/variables/functions that YOUR changes made unused; leave
  pre-existing dead code unless asked.

The test: every changed line should trace directly to the request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:

- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan (each step paired with a verification
check). Strong success criteria let you loop independently; weak criteria ("make
it work") require constant clarification.

### 5. Review Before Building

**Never assume — verify what already exists, then extend it rather than
duplicating it.**

Before building in an area, read what is already there:

- **Data / schema** — read the schema first. Extend existing tables/models; never
  add a parallel structure for something already modelled.
- **Styling / design tokens** — reuse existing variables and utility classes;
  maintain design-system consistency. When given explicit design instructions,
  follow them exactly.
- **Components** — check whether a component already exists before building a new
  one. If a component is named in the request, find it first.
- **Anything** — read the relevant docs for core principles and patterns.

When a change upgrades a shared/universal element, update it in the shared
location, document the change, and verify every instance still renders correctly.

### 6. Working the To-Do List

**Capture every to-do into the list, order it with judgment, then work it to the
end without stopping.**

When the person you're working with hands you new to-dos mid-task:

- **Don't interrupt what you're doing** to act on them, unless they explicitly say
  so. Finish the thing in front of you first.
- **Add each item to the to-do list** (your task-tracking tool) as it arrives —
  never drop it, never hold it only in your head.
- **Place it in a smart order.** The top of the list is the next thing to do. If
  they say "top" or "bottom", honor that; otherwise decide where it belongs — a
  quick unblock or something that informs later work goes high; a nice-to-have
  goes low. Ordering is a decision you make, not a queue you append to.

When you finish the item in front of you:

- **Start the next one and keep going.** Work all the way through the list.
- **Don't stop in the middle to report "a few things left" and wait.** Deliver
  answers the person explicitly asked for as you reach them, and surface a genuine
  blocker (a decision only they can make, an irreversible action needing
  confirmation) — but absent that, keep moving until the list is done.

This is the working default, not a mode to switch on.

## Code Quality Guardrails

Adopt objective, enforced code-quality metrics rather than relying on review taste
alone. Recommended maxima (ecosystem-standard):

- Cyclomatic complexity ≤ 10
- Cognitive complexity ≤ 15
- Function length ≤ 50 lines
- Nesting depth ≤ 4
- Parameters ≤ 4
- Nested callbacks ≤ 4

**No grandfather list and no per-file suppression.** Refactor under the threshold
(extract helpers, early returns, options objects) rather than disabling the rule
for a file — never add an inline lint-disable comment for a metric rule. A linter
set to fail on any warning keeps this honest. These metric rules often run only in
the pre-commit hook on changed files, which is one more reason never to skip the
hook (see "Don't bypass the pre-commit hook").

## Prefer Required Parameters

Advice, not a hard rule — weigh it against everything else here.

A default parameter (`rows: Row[] = []`) buys callers the right to stay silent.
Occasionally that is genuinely useful; more often it is flexibility nobody asked
for, and it carries a failure mode: the caller who *should* have passed something
forgets, compiles clean, and silently gets the default instead of an error.
Defaults standing in for real data are the risky kind — an empty array means
"there was none of it", which reads downstream as a legitimate zero rather than a
missing argument.

So start required, and add a default only when some caller genuinely lacks the
value and the fallback is genuinely right for it. The same thinking applies to
optional object fields (`foo?:`) that every real caller sets.

The motivating case: a revenue total computed from two sources, where the second
source defaulted to an empty list. Every caller passed both, so the default bought
nothing — it just stood ready to let a future caller total revenue from half its
sources and report a plausible wrong number.

## Business Logic Belongs in Services, Not View Components

**Don't put calculation pipelines, data-transformation chains, or multi-step
business logic inline in UI components.** Components are for rendering and user
interaction.

If you find yourself writing parsing, orchestration, or computation logic inside a
view:

1. **Extract it** into a service/module (or a server-side function if it can run
   server-side).
2. **Have the component call a single function** that returns what it needs.
3. **Never duplicate logic** — if two code paths need the same calculation, they
   must share one implementation. Duplicated logic is how one path gets fixed while
   its copy stays broken.

## Idempotency Keys Must Be Deterministic

**Every idempotency key MUST be a pure function of the operation's identity —
never of the moment it runs.** An idempotency key only prevents duplicates if two
independent attempts at the *same* logical operation produce the *same* key. A key
seeded with `Date.now()`, `Math.random()`, a UUID, a request counter, or any
per-attempt value defeats its own purpose: the retry mints a fresh key, the
downstream system sees a brand-new operation, and the user gets double-charged or
double-granted. The classic incident: a payment handoff with two independent
triggers (a scheduled job and a daily fallback sweep) and no key, so both runs
created a recurring subscription. The fix was a key built only from the record
handed off — `subscription_handoff_${subscriptionId}`.

Rules:

- **Derive the key only from stable identifiers** of what the operation acts on
  (a record id, payment-intent id, user id, billing period, invoice id) plus a
  constant prefix that names the operation — e.g. `customer_create_${userId}`.
- **Never mix in time, randomness, or attempt count.** To distinguish two
  *genuinely different* operations, add another stable identifier, not a nonce.
- **When inputs are variable-length or numerous, hash them deterministically**
  (stable, order-independent — sort before hashing) rather than truncating. Respect
  any length limit the downstream API imposes.
- If a caller *supplies* a key, that caller is responsible for making it stable
  across retries — the same real-world action must reuse the same key.

## Error Handling: Fail Fast, Fail Loud

Follow the Pragmatic Programmers' principle: **"Crash early, crash often."**

**Do NOT silently swallow errors.** Every caught exception must either:

1. Re-throw (if it can't be handled meaningfully at this level), or
2. Report the error (to your error-tracking service and logs) AND inform the user, or
3. Return an explicit error result that the caller must handle.

### Backend

- **Prefer throwing over catching.** Let unhandled errors reach your error-tracking
  integration and be reported automatically.
- **Never use empty `catch` blocks.** If you catch, log with context and either
  re-throw or return an explicit error result.
- **A warning log is not error handling.** If something failed, report it and throw
  or return a failure result. Warnings are for non-error conditions only.
- **Use structured/typed errors** for conditions the client needs to distinguish
  (e.g. `INSUFFICIENT_CREDITS`, `RATE_LIMITED`).

### Frontend

- **Graceful degradation is acceptable** — browsers are flaky, networks fail,
  extensions interfere. A fallback UI beats a crash.
- **BUT always report the error** to your error-tracking service, even when
  recovering gracefully.
- **Always inform the user** when something fails.
- **Never `.catch(() => {})` on network calls.** Failed backend calls must surface
  to the user and to error tracking.

### The Rule of Thumb

> If you're writing `catch (_e) {}` or `.catch(() => {})`, you are hiding a bug.
> If you're logging `"failed to X"` without throwing or reporting, you are hiding a bug.
> Ask: "If this fails in production, will I find out?" If no, fix it.

### What Warrants an Alert — and What Doesn't

"Fail loud" is about alerting on the right things, not muting the signal. The
default posture is **fail-fast: when in doubt, let it alert.** A missed alert can
hide a broken system for weeks; one extra alert costs seconds of triage. Bias hard
toward alerting.

**Alert when the error is genuine and actionable, or fatal and non-retriable:**

- **Misconfiguration / missing environment variable → ALWAYS alert.** "It's just
  not configured here" is the reason to alert, not to hide it.
- **A user hit a fatal, non-retriable error** that cannot recover on its own.
- **Retries exhausted** — an operation failed, was retried, and the final attempt
  still failed.

**Don't alert when the failure was transient and the system recovered, or the
outcome is expected normal flow:**

- **Retried and then succeeded** — a transient blip the user never saw. Log it as a
  distinct "retry" class if you want the signal, but don't page.
- **Expected, benign, per-user outcomes** — "insufficient credits", "rate limited",
  "nothing to sync", "code already redeemed". Keep these in a single, documented
  allow-list that your error reporter suppresses.
- **Genuine third-party noise** — browser-extension frames and causes entirely
  outside your code.

**Suppressing an alert is the rare exception.** Reaching for an error-reporter
filter, a new entry in the expected-errors allow-list, or a "return a sentinel
instead of throwing" refactor *to make an issue disappear* is only correct when the
underlying condition is genuinely benign and non-actionable. If a condition is
something you (or an admin) could fix, fix it and keep the alert. When triaging, the default is *fix
the root cause loudly*, not silence the report. If unsure whether a condition is
benign, treat it as a real bug and keep it loud.

## Testing Philosophy: Test-Drive Everything, No Mocks

### The Core Principle: Test-Driven Development

**Every feature, every bug fix, every change starts with a test.** The Iron Law:
no production code without a failing test first.

- **New feature?** Write the test first. Watch it fail. Make it pass.
- **Bug report?** Write a test that reproduces the bug first, then fix it. The test
  proves the fix and prevents regression.
- **Refactoring?** Tests are your safety net. If they don't exist for the code
  you're changing, write them first, then refactor.

If you find yourself writing production code without a failing test, stop, delete
it, and restart.

### Anti-Mock Philosophy: Exercise Real Code

**DO NOT STUB OR MOCK YOUR OWN CODE. ONLY MOCK EXTERNAL SERVICES AT THE MINIMAL
BOUNDARY.**

Mocking your own code creates tests that verify your *assumptions* about how modules
interact — not whether they actually work together. A test that mocks half the call
stack can pass while the real code is broken. That's worse than no test, because it
gives false confidence.

**What we want instead:** tests that exercise as much real, interconnected code as
possible. In-process tests run fast — there's no reason to mock internal modules
when you can just run them.

**The only acceptable mocks are at external service boundaries:**

- Third-party API SDKs (mock the package that talks to an external HTTP API).
- External HTTP calls (stub `fetch` at the boundary).
- External asset/CDN URLs (replace with test constants).

Follow Jose Valim's ["Mocks and explicit contracts"](https://dashbit.co/blog/mocks-and-explicit-contracts):
mock at the HTTP boundary, not internal modules; use fakes with the same interface
as the real service. Wanting to mock an internal module is a design smell — fix the
design, don't add the mock. `mock('../internal/module')` in a PR is a red flag; the
only mock targets should be third-party packages or global boundaries like `fetch`.

### What "Fast" Means

Tests run fast because they're in-process, not because things are mocked out. There
is **no excuse** for mocking internal code "for speed" — the real code IS fast.

### Test Levels

- **Unit / integration tests** — run real backend functions against the real
  schema (an in-memory database or test backend where your stack offers one) and
  exercise full call chains. Don't distinguish rigidly between "unit" and
  "integration": a test that calls an endpoint which triggers an internal job is
  not a slow integration test, it's just a test that runs real code. Mirror the
  source structure in the test directory.
- **Component tests** — mount the real UI component in a DOM (e.g. jsdom), drive it
  with clicks and typing, and assert on the DOM. This exercises the template,
  state, bindings, and handlers together. Prefer it over reading a component's
  source text and regex-matching it: a source check passes while the component is
  broken. Logic that can live in a service still goes in the service with its own
  tests; component tests cover the wiring between the DOM and that logic.
- **End-to-end tests** — browser smoke tests, one or two per area of the app, with
  external services faked at the boundary. Keep the total small (tens, not
  hundreds) and fail aggressively on any uncaught JavaScript error or console
  error.
- **Live third-party integration tests** (optional) — hit a provider's real test
  mode (e.g. a payment provider's sandbox) with no mocks at all. These are slow and
  flaky by nature, so rate-limit them, retry once in CI, and run them on a
  schedule rather than on every PR.

### The Checklist

When writing or reviewing tests, ask:

1. **Does this test exercise real code?** If it mocks an internal module, rewrite it.
2. **Would this test catch a real bug?** If it would still pass with broken code
   (because everything is mocked), it's useless.
3. **Is there a regression test for this bug fix?** Every bug fix must include one.
4. **Is there a test for this new feature?** Every new feature must verify its behavior.
5. **Are mocks limited to external boundaries?** Third-party SDKs and `fetch` only —
   nothing internal.

## Environment Variables

- **Use positive names.** Don't embed negation in the variable name (`*_DISABLED`).
  Use the affirmative form and put the negation in the value:
  `FEATURE_ENABLED=false`, not `FEATURE_DISABLED=true`. This avoids double-negative
  logic in conditionals.
- **Local env files hold development credentials only.** No production credential
  belongs on a developer's machine — not in an env file, a shell profile, or your
  exported environment. Production secrets live in CI secrets, the production
  deployment's own environment, and your password manager. When you need to *read*
  production locally, fetch a scoped, read-only key just-in-time rather than
  keeping one on disk.

## Git, PR & CI Workflow

### Never push directly to main

**All changes go through pull requests.** No commits to `main`, however small —
pushing to main bypasses review and CI.

```bash
git checkout -b feat/your-feature-name
git add <files>
git commit -m "feat: description"
git push -u origin feat/your-feature-name
gh pr create --title "feat: description" --body "..."
```

If you're about to `git push` while on `main`, stop. Branch first, move your
commits, then push the branch.

### Never rewrite published history

- Do NOT use `git rebase`.
- Pull with `git pull --no-rebase` (or `git fetch` + `git merge`), never a bare
  `git pull`. Developer machines may set `pull.rebase=true` globally, which
  silently turns a bare pull into a rebase that replays the default branch's
  commits onto your PR branch.
- Do NOT force-push.
- Do NOT use `git commit --amend`.

Preserve history so changes can be rolled back. (A local `git reset --hard` on a
branch you haven't pushed is fine — the rule is about rewriting *published* history.)

### Don't run full-repo lint/type/build scans during routine work

Whole-repo lint, type-check, and build scan the entire codebase and take minutes.
You don't need them mid-task: **the pre-commit hook checks the staged files, and CI
runs the full suite.**

- ✅ Run the **smallest targeted test** for the code you changed, then commit.
- ✅ To lint/format a specific file, scope the tool to that one file.
- ❌ Don't run whole-project lint / type-check / build as a routine gate.
- The only exceptions: the user explicitly asks, or you're diagnosing a specific CI
  failure a targeted run can't reproduce.

### Don't bypass the pre-commit hook

Do **not** `git commit --no-verify`. The pre-commit hook runs the fast, targeted
checks (lint/format/type-check on *changed files only*) — exactly the checks you
want. Skipping it lets errors that only run there sail through to CI and turn it red.
Let the hook do its job; just `git commit` normally.

### Never silently skip a file

When uncommitted edits, untracked files, or new assets appear in the working tree
that aren't obviously in scope, **ask before excluding them** from the commit or PR.
Surface every change explicitly and let the developer decide what's in scope. Keep
commits clean: meaningful messages, logical chunks.

### Work in a git worktree

Several agents and developers may share a repo. Always work in a worktree, never the
primary checkout. Create worktrees inside the repo at a gitignored path so they
survive temp cleanup and don't clutter sibling directories:

```bash
git worktree add .claude/worktrees/<short-name> <branch>
```

When done, remove it (`git worktree remove <path>`) and prune
(`git worktree prune`). If you start a dev server, confirm the port is free first
and kill the server when you're done. If no port is free, push the branch and test
against the PR's preview deployment instead.

### Never merge or auto-merge a PR unless explicitly told to

Opening a PR, pushing to it, watching CI, retriggering flakes, and applying review
fixes are all yours to do autonomously. **Merging is not.** Don't run
`gh pr merge` — with or without `--auto` — unless the human has explicitly said to
merge (or auto-merge, or land) *that* PR. Finish to green CI, report the PR link
and status, and stop. A general "just do it" or autonomous-maintenance instruction
does not authorize merging; merge authorization is always explicit and per-PR. If
several PRs are ready, list them and wait.

### PR descriptions describe the end state

A PR description describes **what the PR does now and why**, for a reviewer who
never saw it evolve. It is not a changelog of how it got there. Don't write "the
prior commit only moved the file", "reversed an earlier decision", or "first we
tried X, then switched to Y" — that history belongs in commit messages, if
anywhere. When the PR changes, **rewrite** the description (and title) to match the
new state rather than appending a note.

### PR descriptions and comments: one line per paragraph

GitHub renders a **single newline inside a paragraph as a hard line break** in PR
descriptions, issue and PR comments, and review comments. A hard-wrapped paragraph
(the ~76-column wrapping editors and heredocs produce) renders as a shredded stack
of short lines. So for any `gh pr create` / `gh pr edit` body and any
`gh pr comment` / `gh pr review` text: **a paragraph is one line.** Put a blank line
between paragraphs and only there; each list item is a single line. This applies
only to GitHub-rendered PR/issue/comment text — not to commit messages (wrap those
normally), Markdown files committed to the repo, or code.

### Chat replies: give PR links, not bare numbers

When you mention a PR in a chat reply to the user, give its full URL
(`https://github.com/<owner>/<repo>/pull/<n>`), never a bare `#<n>` — in a terminal
or chat UI a bare number is plain text the user can't click. (Inside commit
messages and PR/issue bodies, keep `#<n>`; GitHub links it there.)

## Working With the Automated Review & Auto-Fix Loop

When you push a branch and open/update a PR, this repo runs **automated AI
reviewers** plus a **QA review** against a per-PR preview build. A bot then
**automatically pushes commits to your PR branch** to fix review findings at or
above a configured severity threshold (e.g. `MAXIMUM_FIX_PRIORITY`, default
`MEDIUM`).

When you are the agent that owns a PR:

- **Don't immediately push your own fixes for review/QA findings.** The autofix bot
  handles findings at/above the threshold. Two agents pushing to the same branch
  causes non-fast-forward rejections, merge churn, and conflicting commits.
- **Wait a few minutes** for the bot's pass. It posts a checklist comment, then
  pushes a fix commit. Then `git pull --no-rebase` and build on top of its work —
  don't redo it.
- **Only step in when the bot can't.** It cannot modify CI workflow files (its app
  typically lacks `workflows: write`), and it skips findings below the threshold.
  Those are yours. If you must touch a file the bot is also editing,
  `git pull --no-rebase` first and expect to reconcile — better to let the bot land, then layer your change.
- A failing check on a commit that a newer push has superseded is usually a
  **cancelled** run (finishes in seconds), not a real failure — verify against the
  PR's latest commit before reacting.

### Severity / Priority Convention

Findings are ranked by severity (e.g. `XLOW` / `LOW` / `MEDIUM` / `HIGH`). A single
threshold (`MAXIMUM_FIX_PRIORITY`) governs which findings the autofix bot addresses
automatically: findings at or above the threshold are auto-fixed; those below it are
left for a human or the owning agent to judge.

### Re-trigger flaky CI with an empty commit — don't wait on a human

When a **required** check is red because of a **flake or a cancelled/superseded run**
— not a real defect — re-run it. Tells that a failure is *not the code*:

- an infra 5xx during a deploy/preview step ("Internal Server Error", "Try again
  later");
- a check whose log ends with a "cancelled" suffix because a newer push superseded
  the in-flight run;
- a failure that also appears on an **unrelated docs-only PR at the same time** —
  a shared-CI-environment problem, not your diff.

An agent's token often lacks `actions: write`, so the re-run API returns
`403 Resource not accessible by integration`. Don't stop and ask a human to click
"Re-run failed jobs" — push a trivial empty commit to start a fresh run:

```bash
git commit --allow-empty -m "chore: retrigger CI (flaky infra / cancelled run)"
git push
```

This is safe when **every PR is squash-merged** — throwaway retrigger commits never
reach `main`. Always diagnose first: retrigger only genuine flakes / superseded
runs; fix real failures for real.

## CI & Deployment Discipline

### Never deploy to production from your local machine

**All production deployments happen exclusively through CI**, after a PR is merged.
Don't run deploy/publish commands locally for either backend or frontend. To get
code to prod, open a PR and let CI handle it.

### Background jobs must notify on failure

**Every CI workflow that runs outside of a PR must push failures to a chat channel**
(scheduled/cron jobs, push-to-main workflows, non-PR manual dispatch runs). These
jobs are invisible unless someone checks the Actions tab, so a failing scheduled job
can go unnoticed for weeks. Add a notify-on-failure step restricted to the main
branch (e.g. `if: failure() && github.ref == 'refs/heads/main'`). PR checks are
visible in the PR UI; everything else needs an active notification.

## Landing the Plane (Session Completion)

When ending a work session, complete ALL steps. **Never push to main — all work
goes through pull requests.**

1. **File issues for remaining work** — anything needing follow-up.
2. **Run targeted local checks** (if code changed) — focused behavior tests only.
   Don't run whole-repo lint/type/build as a routine gate; CI and hooks own those.
3. **Update issue status** — close finished work, update in-progress items.
4. **Push your BRANCH and open a PR:**
   ```bash
   git branch --show-current   # MUST NOT say "main"
   git fetch
   git merge --no-edit origin/main
   git push -u origin HEAD
   gh pr create --title "feat: description" --body "..."
   ```
5. **Watch CI** — monitor checks until green. If one fails: read the logs, fix
   locally, commit a **new** commit (don't amend), push, and wait for a green re-run.
6. **Verify** — all changes committed, pushed to a branch, PR open, CI green.
7. **Hand off** — provide context for the next session and link the PR URL.

**Critical rules:**
- Work is NOT complete until a PR is open and CI is green.
- Never push to main — always a feature branch.
- Never stop before pushing — that strands work locally.
- Never say "ready to push when you are" — YOU push the branch and open the PR.
- If CI fails, diagnose, fix, and push again — don't leave a red CI for the reviewer.

> The behavioral rules above are one layer; the enforcement layer is your host's
> branch-protection rules for `main`. If direct pushes to main are still possible,
> enable branch protection.
