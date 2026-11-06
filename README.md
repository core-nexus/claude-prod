# claude-prod

Production-grade Claude Code automation for GitHub repositories. A toolkit of
GitHub Actions workflows, a Cloudflare Worker, and reusable agent skills that put
Claude to work on a real codebase — reviewing code, QA-ing previews, fixing red
CI, triaging Sentry errors, writing changelogs, and shepherding PRs to merge.

**Everything here is modular.** Copy the pieces you want into your own repo and
skip the rest; the components share conventions but have no hard dependencies on
one another. Almost every workflow authenticates with a single
`CLAUDE_CODE_OAUTH_TOKEN` secret, which bills to Claude Code **plan** credits
rather than API credits.

## Repository map

| Component | Path | What it does |
|---|---|---|
| **Codebase Review** | `.github/workflows/codebase-review.yml` + `.github/review-prompts/` | Adaptively scheduled deep-dive audits across 18 focus areas → issues → auto-fix PRs |
| **PR Review** | `.github/workflows/claude-pr-review.yml` | Reviews every PR and auto-fixes findings; `/claude-review`, `/claude-fix`, manual `workflow_dispatch` |
| **QA Review** | `.github/workflows/ai-qa-review.yml` | Opens a PR's preview deploy in a real browser and verifies it end-to-end; `/qa-review [extra instructions]` |
| **CI Auto-Fix** | `.github/workflows/claude-auto-fix-ci.yml` | On CI failure, feeds logs to Claude to push a fix commit (ships **disabled**, opt-in) |
| **Changelog** | `.github/workflows/changelog.yml` | AI-written changelog entries, opened as a PR on a schedule |
| **@claude assistant** | `.github/workflows/claude.yml` | Mention `@claude` on any issue/PR and the agent responds |
| **Sentry Triage** | `.github/workflows/sentry-triage.yml` + `workers/sentry-triage/` (+ `sentry-triage-worker-test.yml`) | Cloudflare Worker bridges Sentry alerts → Claude opens a fix PR; both halves report their own failures |
| **Secret Scan** | `.github/workflows/secret-scan.yml` | gitleaks (pinned, checksum-verified CLI, no license key) on every PR and push to main |
| **Supply-chain Scan** | `.github/workflows/shai-hulud-scan.yml` | Daily and per-PR scan for Shai-Hulud-style npm/PyPI compromises with a pinned detector |
| **Nightly Uncached Lint** | `.github/workflows/lint-nightly.yml` | Template: a daily cold lint that catches what a lint cache hides; alerts on failure or timeout |
| **Script tests** | `.github/workflows/{qa-review,codebase-review}-scripts-test.yml` | Runs the bash tests for the review/QA helper scripts |
| **Skills** | `skills/` | Reusable Claude Code skills for the PR lifecycle, repo sweeps, and TDD |
| **Agent instructions** | `AGENTS.md` (`CLAUDE.md`, `GEMINI.md` symlinks) | Portable coding guidelines any agent can drop into a repo |
| **Patterns & templates** | `docs/nightly-qa-prompt.md`, `docs/briefing-pattern.md`, `docs/changelog-guide.md` | Nightly wandering-QA prompt template; facts-in-code, narrative-by-LLM briefing design; changelog writing guide |

## Copying a piece into your repo

Each workflow file opens with a header comment documenting its triggers, required
secrets, and every knob worth turning — **read that header first; it is the
source of truth for setup.** The general recipe:

1. Copy the workflow YAML — plus any scripts it references from
   `.github/workflows/scripts/`, and `.github/review-prompts/` for codebase
   review — into your repo's `.github/`.
2. `chmod +x` any copied `*.sh` scripts.
3. Add the secrets the header names — at minimum `CLAUDE_CODE_OAUTH_TOKEN`
   ([how to mint one](https://docs.anthropic.com/en/docs/claude-code/github-actions)).
4. Adjust the header's config knobs (branch names, cron, CI workflow names,
   review areas) for your project, then commit on a branch and open a PR.

**Installing with an AI agent?** Paste this and let it work:

```
Install a component from https://github.com/core-nexus/claude-prod into this
repository:
1. Fetch the component's files: its workflow YAML, any scripts it references
   under .github/workflows/scripts/, and .github/review-prompts/ if you're
   installing the codebase review.
2. Read the header comment at the top of each copied workflow file — it lists the
   required secrets and the values to customize. Apply them for THIS repo.
3. chmod +x any copied .sh scripts.
4. Ensure CLAUDE_CODE_OAUTH_TOKEN (and any other secret the header names) is set
   under Settings → Secrets and variables → Actions.
5. Commit on a feature branch and open a PR — never push straight to main.
```

## Components

### Codebase Review — `codebase-review.yml`

A two-stage pipeline: **review → fix**, run on an adaptive schedule.

1. **Review** — Claude audits the entire codebase against one focus area's
   checklist and opens a GitHub issue with findings grouped by severity.
2. **Fix** — when a finding is MEDIUM or higher, Claude edits code, runs your
   quality gates, and opens a PR.

Eighteen focus areas ship in `.github/review-prompts/`:

| Area | What it checks |
|---|---|
| **security** | Auth, authorization, injection, secrets, OWASP Top 10 |
| **code-quality** | Type safety, style, component architecture, dead code |
| **performance-client** | Bundle size, Core Web Vitals, rendering, long-session memory |
| **performance-server** | Backend query/write efficiency, indexes, N+1, crons, per-request cost |
| **scalability** | Growth at 10x / 100x / 1,000x: hot rows, fan-out, unbounded tables |
| **testing** | Coverage gaps, mock discipline, test quality, E2E |
| **error-handling** | Silent catches, error reporting, resilience patterns |
| **correctness** | Logic bugs, off-by-one errors, race conditions, wrong references |
| **privacy** | PII in logs, data minimization, consent, third-party data flows |
| **compliance** | GDPR, CCPA, cookie consent, data subject rights |
| **ai-compliance** | EU AI Act, transparency, bias, automated decision-making |
| **documentation** | Stale docs, missing API docs, CLAUDE.md accuracy |
| **dependency-health** | Vulnerabilities, outdated packages, license compliance, supply chain |
| **e-commerce** | Payments, subscriptions, webhooks, credits, refunds/disputes/payouts, billing math |
| **billing-integrity** | Unit economics: do rolled-up revenue/cost/margin numbers tell the truth, markup held on every path, reconciliation with the processor |
| **infrastructure** | CI/CD, pre-commit hooks, linting/formatting, build scripts, env hygiene |
| **architecture** | Schema/data-model changes, module boundaries, scalability of recent changes |
| **resilience** | Rate limits, timeouts, retries, idempotency, graceful degradation, blast radius |

Ships runnable via `workflow_dispatch` (pick one area or `all`). The daily cron is
commented out in the workflow — uncomment it to schedule. Each scheduled run asks
`resolve-review-area.sh` which areas are **due**: an area whose last review PR you
merged comes back fast (weekly), one you're engaged with but haven't merged comes
back monthly, and one nobody has acted on backs off to quarterly. `e-commerce` and
`billing-integrity` run on a tighter cadence. When nothing is due the run is a
no-op. Older review issues/PRs for an area are closed by
`close-superseded-reviews.sh` when a fresh one lands. Note that a newly enabled
schedule reviews every area on its first run.

Add a new area by dropping a `.md` in `review-prompts/` (Objective → Checklist →
Severity Guide) and registering it in the `workflow_dispatch` options and the area
lists in `resolve-review-area.sh`; `resolve-review-area.test.sh` fails if the
three get out of sync. Several prompts end with an empty **Living Hotspot Map**
that the reviews fill in for your repo over time.

<details>
<summary><b>Copy-paste install block for an AI agent</b></summary>

```
Install the codebase-review system from https://github.com/core-nexus/claude-prod
into this repository:

1. Copy these into this repo (merge with existing .github/ if present):
   - .github/review-prompts/                       (all 18 .md files)
   - .github/workflows/codebase-review.yml
   - .github/workflows/scripts/resolve-review-area.sh
   - .github/workflows/scripts/resolve-review-area.test.sh
   - .github/workflows/scripts/close-superseded-reviews.sh
   - .github/workflows/scripts/extract-review-priority.sh
   - .github/workflows/scripts/trigger-ci-workflows.sh
   - .github/workflows/codebase-review-scripts-test.yml  (optional: tests the resolver)

2. chmod +x .github/workflows/scripts/*.sh

3. Adjust codebase-review.yml for this project:
   - Uncomment the `schedule:` cron to run daily (only due areas run), or
     leave it manual (workflow_dispatch only).
   - Remove review areas that don't apply (e.g. e-commerce.md and
     billing-integrity.md with no payments, ai-compliance.md with no AI
     features) and drop them from the workflow_dispatch options and the area
     lists in resolve-review-area.sh (run resolve-review-area.test.sh to check).
   - In trigger-ci-workflows.sh set WORKFLOWS to this project's CI workflow
     filenames, e.g. "ci.yml test.yml checks.yml".

4. Set the CLAUDE_CODE_OAUTH_TOKEN secret
   (Settings → Secrets and variables → Actions).

5. Create the auto-review label:
   gh label create auto-review --description "Automated codebase review" --color "0E8A16"

6. Commit on a feature branch and open a PR.
```

</details>

### PR Review — `claude-pr-review.yml`

Reviews every PR on open / ready-for-review, then auto-fixes findings at or above
`MAXIMUM_FIX_PRIORITY` (default `MEDIUM`). Comment `/claude-review` to re-review or
`/claude-fix` to force a fix pass, or run either stage for a PR number from
`workflow_dispatch`. The fix stage treats red CI and in-scope findings as two
required objectives, pushes commits to the PR branch, and monitors CI until green.
Draft PRs and docs/text-only PRs are skipped; a failed run leaves a diagnostic
banner on its tracking comment.

### QA Review — `ai-qa-review.yml`

Opens a PR's preview deployment in a real browser and verifies the change works
end-to-end — the behavioral complement to the code-level PR review, and safe to
run in parallel with it. Runs on open / ready-for-review; comment `/qa-review` to
re-run against new commits, with optional extra focus instructions after the
command. The pass scales to the number of areas the PR touches and plans against a
deadline (`QA_BUDGET_MINUTES`). A run that could not check anything reports
`UNKNOWN` and blocks rather than passing. Point `wait-for-preview-url.sh` at
wherever your deploy bot posts the preview URL. `qa-review-scripts-test.yml` runs
the helper scripts' tests.

### CI Auto-Fix — `claude-auto-fix-ci.yml`

When a CI run fails on a PR, feeds the failing job logs to Claude, which pushes a
fix commit and lets CI re-run until green. **Ships disabled** — it self-pushes
commits, so it does nothing until you set the repo variable
`ENABLE_AUTO_FIX_CI=true` and list your CI workflow's `name:` under
`on.workflow_run`. A `[auto-fix-ci]` commit marker caps it at 5 attempts per
branch; it only ever adds new commits and refuses to touch the default branch.

### Changelog — `changelog.yml`

On a schedule (default Mon/Thu 15:00 UTC) collects PRs merged since the last
entry and asks Claude to write user-facing `CHANGELOG.md` entries
(Keep-a-Changelog style, newest-first). Keeps security, billing, compliance and
infrastructure detail out of public entries, and follows
[`docs/changelog-guide.md`](docs/changelog-guide.md) when present. Always opened
as a reviewable PR — never pushed to the base branch (set `CHANGELOG_AUTO_MERGE`
to arm auto-merge on it).

### @claude assistant — `claude.yml`

Mention `@claude` in an issue, PR, or review comment and the agent reads context,
makes changes, and pushes commits or opens PRs. Gated to OWNER / MEMBER /
COLLABORATOR so fork PRs can't run it with your secrets.

### Sentry Triage — `sentry-triage.yml` + `workers/sentry-triage/`

A Cloudflare Worker (`workers/sentry-triage/`) receives Sentry webhooks, verifies
and normalizes them, deduplicates aggressively (four stacked layers), and fires a
GitHub `repository_dispatch`. The `sentry-triage.yml` workflow then runs Claude to
investigate and, if the bug is worth fixing, opens a PR with a regression test
plus the fix. The Worker reports its own failures (failed dispatch, missing PAT,
bad `PROJECT_MAP`) to `SENTRY_DSN`, guarded so they can't loop back into triage,
and the workflow fails if the Sentry MCP didn't connect.
`sentry-triage-worker-test.yml` typechecks, tests and dry-run-bundles the Worker.
Full architecture and operator guide:
[`docs/sentry-triage/`](docs/sentry-triage/README.md).

### Secret Scan — `secret-scan.yml`

Runs [gitleaks](https://github.com/gitleaks/gitleaks) over the commits of every PR
and every push to main, with redacted output. Uses the pinned, checksum-verified
CLI rather than the action, so organization-owned repos need no license key. The
header explains `.gitleaksignore` / `.gitleaks.toml` for false positives.

### Supply-chain Scan — `shai-hulud-scan.yml`

Scans for Shai-Hulud-style npm/PyPI worm compromises on PRs, pushes to main and
daily, using a pinned commit of an open-source detector. Fails closed if the
detector can't be fetched, fails the build only on high-risk findings, and uploads
the report.

### Nightly Uncached Lint — `lint-nightly.yml`

A template for a daily lint run with every cache off, which catches type-aware
violations an incremental or cached lint hides. Set `INSTALL_COMMAND` and
`LINT_COMMAND` in the header; alerts on failure or timeout. Ships manual-only.

### Skills — `skills/`

Reusable [Claude Code skills](https://docs.anthropic.com/en/docs/claude-code):

- **`babysit`** — scans your open PRs (updated in the last 24 hours) and takes one
  action each: resolve merge conflicts, retrigger stuck CI or a flaky QA run, and
  nudge the review/fix/QA pipeline forward. Built to run inside a `/loop`.
- **`pr-merge-main`** — merges the default branch into a working branch,
  resolving conflicts thoughtfully.
- **`pr-reset`** / **`pr-restart`** — collapse a messy PR into one clean commit on
  the latest default branch and reopen it as a fresh PR.
- **`pr-fix`** — fix every LOW-or-above review/QA finding on a PR, then loop until
  CI is green.
- **`pr-review`** — review a PR in an isolated worktree, verify each finding, then
  fix HIGH/MEDIUM findings test-first on the PR branch.
- **`pr-creator`** — open a PR whose description renders well on GitHub: the end
  state, one line per paragraph, the repo's template filled in.
- **`adversarial`** — try to break a PR in a real browser, fix what breaks, then
  read the whole diff adversarially, all in the same PR.
- **`bulk-merge`** — take a labelled or queried batch of PRs through triage,
  parallel agents, a strict merge-safe bar and a local pass; hand back only
  genuine blockers.
- **`sweep`** — runs `sweep-local` then `sweep-github`.
- **`sweep-local`** — finds loose ends in recent local Claude Code sessions
  (unpushed commits, work with no PR, promised follow-ups) and lands the clear ones.
- **`sweep-github`** — closes dead PRs and issues with evidence, ranks the live ones
  into one `Priority-1..10` label each, and bulk-merges the top ones. Configure with
  `REPO` and `SWEEP_SKIP_AUTHORS`.
- **`test-driven-development`** — enforces write-the-test-first discipline.

### Agent instructions — `AGENTS.md`

Portable engineering guidelines for AI coding agents: simplicity, surgical
changes, working a to-do list to the end, fail-loud error handling and alert
policy, deterministic idempotency keys, required parameters over defaults, no-mocks
testing and test levels, and the Git/PR/CI workflow (including never merging
unless explicitly told, and PR descriptions that describe the end state).
`CLAUDE.md` and `GEMINI.md` symlink to it, so Claude Code, Gemini, and any
`AGENTS.md`-aware tool pick up the same rules. Drop it into any repo root.

### Patterns & templates — `docs/`

- [`docs/nightly-qa-prompt.md`](docs/nightly-qa-prompt.md) — a fill-in template for
  an unattended nightly agent that roams your live app like a user and opens
  before/after fix PRs.
- [`docs/briefing-pattern.md`](docs/briefing-pattern.md) — how to build daily/weekly
  briefings where code computes every fact and an LLM writes only the narrative.
- [`docs/ci-docs-only-skip.md`](docs/ci-docs-only-skip.md) — skip heavy CI on
  docs-only PRs without breaking required checks.

## Conventions

### Severity & priority

Findings are ranked, and one threshold — `MAXIMUM_FIX_PRIORITY` — decides what
gets auto-fixed versus left for a human:

| Priority | Meaning | Auto-fixed? |
|---|---|---|
| NONE | Clean, no issues | No |
| XLOW | Trivial nits | No |
| LOW | Minor issues | No |
| MEDIUM | Real issues | Yes |
| HIGH | Critical issues | Yes |

### Bring your own CLAUDE.md

Any workflow that reviews or edits code reads your repo's root `CLAUDE.md` (or
`AGENTS.md`) and follows it — the cleanest way to steer Claude's behavior without
editing the prompts.

## Cost

Each Claude run uses Claude Code plan credits (Opus by default). The codebase
review is the heaviest piece — with every area enabled, the first scheduled run
reviews all 18 areas, after which only due areas run (roughly weekly per area you
actively merge, less for the rest). To trim cost: delete review areas you
don't need, run less often, or switch a workflow to `--model sonnet` for a
~3–5× reduction at some quality tradeoff.

## License

MIT © Superluminal Systems. See [LICENSE](LICENSE).
