# Sentry → Claude Code auto-triage

Automated pipeline that takes a new (or escalating) Sentry issue, runs
Claude Code against it in GitHub Actions, and opens a PR with a candidate
fix.

## Why this exists

Sentry's own auto-triage products are often too coarse: you want a pipeline
you can tune yourself, that:

1. Only fires on issues worth spending tokens on (filtered at the Sentry
   alert-rule layer).
2. Runs Claude Code with enough context to actually diagnose the bug — not
   just the one-line "TypeError: undefined" that a bare stack trace often
   gives.
3. Deduplicates aggressively so a flapping issue doesn't burn tokens on
   every event, and doesn't open a second PR when one is already in flight.
4. Works across multiple Sentry projects / GitHub repos from a single
   Worker.

## Architecture

```
Sentry (per project)                 Cloudflare Worker                 GitHub (per repo)
──────────────────                   ─────────────────                 ───────────────────
Issue alert rule    ──webhook──►     sentry-triage Worker  ──dispatch──►  sentry-triage.yml
  • first seen                         • verify signature                    • dedup by branch
  • regressed                          • extract context                     • claude-code-action
  • escalating                         • look up target repo                 • opens PR on
  • filters (level,                    • KV dedup                              sentry-fix/<shortId>
    env, event count)                  • POST /dispatches
  • action interval:
    once / 30d / issue
```

Four dedup layers stacked so a firehose issue never re-triggers:

| Layer | Where                             | Behaviour                                                                                                                                                                                                      |
| ----- | --------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | Sentry alert rule action interval | Will not re-fire the webhook for the same `(issue, rule)` inside the interval (default: 30 days).                                                                                                              |
| 2     | Worker KV                         | Short-term guard (24h) keyed on `<project>:<shortId>`. Belt-and-suspenders in case Sentry dedup misbehaves or two overlapping rules fire.                                                                      |
| 3     | GitHub workflow (exact shortId)   | `gh pr list --search "sentry-fix/<shortId>"` — skip if any matching open **or** closed PR exists. A merged PR means we've already fixed it; a closed-unmerged one means we consciously gave up, do not re-try. |
| 4     | Claude prompt (semantic)          | Layers 1–3 key on the exact `shortId`, but Sentry often splits one underlying bug into several issues with *different* shortIds. The triage agent compares the current bug against every open `sentry-fix/*` PR (file paths, function names, error class, stack-frame fingerprint) at the start of the run **and again just before pushing** — if a sibling PR already addresses the same root cause, it comments and stops instead of opening a duplicate. |

Regressions bypass layer 2 (a previously-fixed issue firing again is
exactly the signal we want to re-run on).

### Failures stay loud

Each half of the pipeline reports its own silent failure modes:

- **Worker** — a non-2xx from GitHub, a missing `GITHUB_PAT`, an unparseable
  `PROJECT_MAP`, or an unhandled exception is posted to `SENTRY_DSN` as a
  `[sentry-triage] <reason>` event. Those self-reports are tagged and filtered
  on the way back in, so an echo is never dispatched and cannot loop.
- **Workflow** — if the Sentry MCP never connected (wrong token or auth
  scheme), Claude cannot read the issue and the action would still report
  success; a `Verify Sentry MCP connected` step fails the job instead. Hitting
  the job timeout counts as a failure for the Slack alert, and Claude's
  transcript is uploaded as a 7-day artifact for debugging.

### Blast-radius numbers travel in the dispatch

The dispatched payload carries the issue's blast-radius fields — `count` (total
event frequency), `userCount` (affected users), `firstSeen`, and `lastSeen` — so
the triage agent has them even when the Sentry MCP is unavailable. The payload is
the **authoritative** source for these numbers; the MCP is used only to enrich
(full stacktrace, per-day/per-release breakdowns), with graceful fallback to the
payload values. `event_alert` webhooks usually omit the aggregate counts, so the
payload also carries `sentryApiIssueUrl` for the agent to fetch them.

Beyond that, the Worker forwards as much context as fits under GitHub's ~10 KB
`client_payload` cap: all non-secret tags, the request (query string only when
PII redaction is off), user id / username / geo, a whitelisted set of contexts
(trace, runtime, os, browser, device, ...), SDK, fingerprint, and `extra`. Keys
that look like secrets (`token`, `password`, `api_key`, `cookie`, ...) are always
dropped. When the payload is too big it sheds the least decision-relevant data
first (`extra`, then breadcrumbs, contexts, frames, tags) and never drops the
aggregate counts, the exception, IDs or URLs.

## Files in this folder

- **[`worker-spec.md`](./worker-spec.md)** — full specification for the
  Cloudflare Worker. Useful as a design reference if you want to
  reimplement or extend the Worker.
- **[`setup.md`](./setup.md)** — operator guide: Sentry alert rules,
  integration setup, Worker env vars, repo secrets, how to onboard a new
  project.

## Files elsewhere in this repo

- **[`workers/sentry-triage/`](../../workers/sentry-triage/)** — the
  Cloudflare Worker implementation.
- **[`.github/workflows/sentry-triage-worker-test.yml`](../../.github/workflows/sentry-triage-worker-test.yml)** —
  CI for the Worker: typecheck, unit tests, a `wrangler deploy --dry-run`, and
  the workflow's shell-script tests. It never deploys.
- **[`.github/workflows/sentry-triage.yml`](../../.github/workflows/sentry-triage.yml)** —
  the receiving workflow. Triggered via `repository_dispatch` from the
  Worker. Runs `anthropics/claude-code-action@v1` with a triage prompt.

## Cost model (rule of thumb)

Per triggered issue: one `claude-code-action` run using Opus with a
large-ish turn budget (the workflow defaults to 250 turns to match other
Claude Code workflow examples). Real cost depends on how deep the fix is;
in practice a few dollars of Claude Code plan credits per run.

If that's still too much, two levers:

- Tighten the Sentry alert filters (higher event-count threshold,
  fatal-only, specific projects).
- Switch the workflow to `--model sonnet` for a ~3–5× cost reduction at a
  noticeable quality cost.
