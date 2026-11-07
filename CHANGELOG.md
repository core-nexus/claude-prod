# Changelog

All notable user-facing changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com), with
dated sections newest-first and changes grouped under New / Improved / Fixed.

The `Update Changelog` GitHub Actions workflow appends new dated sections here
automatically via pull request.

## 2026-11-06

### New

- **Review areas:** `performance-client`, `performance-server` (replacing `performance`), `scalability`, and `billing-integrity`, which checks that rolled-up revenue, cost and margin numbers tell the truth. 18 areas in all.
- **Codebase review:** adaptive scheduling. A daily cron runs only the areas that are due (fast after you merge an area's review, slower when you don't), with `e-commerce` and `billing-integrity` on a tighter cadence. Superseded reviews are closed by a script, and `codebase-review-scripts-test.yml` tests the resolver.
- **Codebase review:** an empty Living Hotspot Map template in the security, privacy, e-commerce, billing-integrity and performance/scale prompts, filled in by the reviews over time.
- **PR review:** run the review or fix stage for a PR number from `workflow_dispatch`.
- **QA review:** `/qa-review` takes extra focus instructions after the command.
- **QA review:** `qa-review-scripts-test.yml` runs the helper scripts' tests.
- **Workflows:** `secret-scan.yml` runs gitleaks with a pinned, checksum-verified CLI, so no license key is needed.
- **Workflows:** `shai-hulud-scan.yml` scans for npm/PyPI supply-chain worms on PRs and daily, with a pinned detector that fails closed.
- **Workflows:** the `lint-nightly.yml` template runs a daily uncached lint and alerts on failure or timeout.
- **Sentry triage:** the Worker reports its own failures to `SENTRY_DSN`, with a guard that stops them looping back into triage.
- **Sentry triage:** `sentry-triage.yml` fails when the Sentry MCP didn't connect, and keeps the Claude transcript as an artifact.
- **Sentry triage:** `sentry-triage-worker-test.yml` typechecks, tests and dry-run-bundles the Worker.
- **Skills:** `pr-fix`, `pr-review`, `pr-creator`, `adversarial`, `bulk-merge`, `sweep`, `sweep-local` and `sweep-github`.
- **Docs:** `docs/nightly-qa-prompt.md` (nightly wandering-QA prompt template), `docs/briefing-pattern.md` (code computes the facts, an LLM writes the narrative) and `docs/changelog-guide.md`.

### Improved

- **PR review:** the fix stage treats red CI and in-scope findings as two separate required objectives and handles flaky tests explicitly.
- **PR review:** draft PRs are skipped, and failed runs leave a diagnostic banner on their tracking comment.
- **QA review:** the pass scales to the number of areas a PR touches and plans against a deadline (`QA_BUDGET_MINUTES`).
- **Review prompts:** security covers the full endpoint inventory, secrets exposed at runtime and debug endpoints. E-commerce covers webhook-ack ordering, refunds, disputes and payouts. Smaller generic additions across the other areas.
- **Codebase review:** the fixer only touches findings at or above the threshold. Permissions default to read-only, and Slack failure alerts are optional.
- **Changelog:** the prompt keeps security, billing, compliance and infrastructure detail out of public entries. New optional `CHANGELOG_GUIDE` and `CHANGELOG_AUTO_MERGE` knobs.
- **`claude.yml`:** defaults to least-privilege permissions and reads `AGENTS.md` as well as `CLAUDE.md`.
- **Sentry triage:** the Worker forwards much richer context (tags, request, user, contexts, SDK, fingerprint, extra, unhandled flag). Payload size is measured on the real serialized bytes and trimmed without dropping counts or IDs.
- **`babysit`:**
  - only touches PRs updated in the last 24 hours
  - asks Dependabot to rebase its own PRs
  - tells a real QA finding from an infra non-report and re-runs flaky QA a capped number of times
  - reconciles dueling-implementation conflicts
  - gains a `FIX_ON_CI_FAILURE` knob
- **`AGENTS.md`:** adds the to-do-list discipline, prefer required parameters, test levels including component tests, and keeping production credentials off dev machines. Also adds: never merge unless explicitly told, PR descriptions that describe the end state with one line per paragraph, and `git pull --no-rebase`.
- **`docs/ci-docs-only-skip.md`:** documents the aggregator required-check pattern and the `paths-ignore` limits.

### Fixed

- **QA review:** comments failed to post whenever a report referenced an image (a sed delimiter collision and a multi-line `awk -v`).
- **QA review:** a run that checked nothing reported a pass. It now reports `UNKNOWN` and blocks.
- **PR and QA review:** a stacked PR whose base branch is deleted mid-run no longer breaks the job.
- **QA review:** a PR that edits the QA workflow now gets an explanation instead of a confusing red check.
- **`docs/ci-docs-only-skip.md`:** the example gate skipped CI when change detection failed, and listed only the first 100 changed files.
- **`changelog.yml`:** used the `runner` context in workflow-level `env`, which stopped it from starting.
- **Codebase review:** the fix job could not dispatch CI on its branch, and `trigger-ci-workflows.sh` hid dispatch errors.
- **Sentry triage:** the Sentry MCP auth header now uses `Sentry-Bearer`, which the hosted MCP requires.
- **Sentry triage:** the Slack failure alert never fired because its `if:` read the step's own `env`. It now also fires on timeouts.
- **Sentry triage:** a fresh `npm install` of the Worker failed with ERESOLVE. A lockfile now pins working versions.
- **`babysit`:** paginates PR comments and reads the head commit by SHA, so busy PRs are classified correctly.
