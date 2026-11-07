# Sentry triage — operator setup

End-to-end setup for one project (Sentry org + Cloudflare Worker + GitHub
repo). Repeat the per-project parts for each new Sentry project you
onboard.

## Prereqs

- Cloudflare account with Workers + KV enabled.
- Sentry org admin access (to create an Internal Integration and alert
  rules).
- GitHub admin on the target repo (to add secrets and, if using a GitHub
  App, install it).
- The `sentry-triage` Worker deployed (see `worker-spec.md` and the README
  in `workers/sentry-triage/`).

## 1. One-time Sentry Internal Integration

A single Internal Integration per Sentry org gives us the webhook-signing
secret and the scopes needed to post comments back on issues.

1. Sentry → **Settings → Developer Settings → Custom Integrations →
   Create New Integration → Internal Integration**.
2. Name: e.g. `Sentry Triage Bridge`.
3. Webhook URL: the deployed Worker URL, e.g.
   `https://sentry-triage.<your-account>.workers.dev/sentry/webhook`.
4. Redirect URL: (leave blank).
5. Verify SSL: on.
6. Alert rule action: **enabled** (this is what makes the integration
   available in alert rule dropdowns alongside Slack).
7. Scopes:
   - **Issue & Event:** Read (required), Write (optional — only if you
     later want to comment on issues from the Worker).
   - **Project:** Read.
   - Organisation: (none needed).
8. Webhooks: tick **Issue** (for created / regressed / resolved) and leave
   **Event** unticked (too noisy; alert rules are the better filter).
9. Save. Copy:
   - **Client Secret** → Worker env var `SENTRY_CLIENT_SECRET` (via
     `wrangler secret put`).
   - **Auth Token** → GitHub repo secret `SENTRY_AUTH_TOKEN` (Claude uses
     this via MCP to fetch full event data and to comment on the issue).
     Use this integration token, not a CI-only org token for release /
     source-map uploads: that kind gets 403 on every issue read.

> **Why an Internal Integration and not a plain webhook?** Internal
> Integrations sign their webhooks (HMAC in `Sentry-Hook-Signature`), so
> we can verify authenticity. Plain project-level webhooks don't sign.

## 2. Per-project Sentry alert rules

Create **two** Issue Alert rules per project. The two rules let you treat
"new" and "escalating" traffic with different thresholds and different
re-fire intervals.

### Rule A — "New high-signal issues"

- **When:** `A new issue is created`.
- **If (all):**
  - `The issue's level is equal to error` _(add a second clause for
    `fatal` if you want both)_.
  - `The event's environment equals production`.
  - `The issue is assigned to No one` _(skip if someone already owns it)_.
- **Perform these actions:**
  - `Send a notification via Sentry Triage Bridge` (the Internal
    Integration).
- **Rate limit (action interval):** `Perform these actions at most once
  every 30 days for an issue`.

### Rule B — "Escalating / regressed issues"

- **When (any):**
  - `An issue changes state from resolved to unresolved`.
  - `An issue changes state from ignored to unresolved`.
  - `The issue affects more than 50 users in one hour`.
  - `Number of events in an issue is more than 500 in one hour`.
- **If (all):**
  - `The issue's level is equal to error` (or `fatal`).
  - `The event's environment equals production`.
- **Perform these actions:**
  - `Send a notification via Sentry Triage Bridge`.
- **Rate limit (action interval):** `Perform these actions at most once
  every 7 days for an issue`.

Tune the "X users in Y" and "N events in M" thresholds to your project's
traffic. Good starting points for a small-to-medium app: 50 users/hour,
500 events/hour. For a quiet backend: 10 users/hour, 100 events/hour.

Why two rules and not one:

- Rule A is the "fix the bug before users complain" path. Long interval
  because there should only be one fix attempt per new bug.
- Rule B is the "something we thought was fixed is back" / "something
  previously minor is now a big deal" path. Shorter interval because the
  situation is changing.

## 3. Worker configuration

In the Worker's `wrangler.toml` (and via `wrangler secret put` for
secrets):

- `SENTRY_CLIENT_SECRET` — from step 1 (via `wrangler secret put`).
- `SENTRY_DSN` — where the Worker reports its own failures (expired
  `GITHUB_PAT`, unparseable `PROJECT_MAP`, non-2xx from GitHub, unhandled
  exceptions). Set via `wrangler secret put`. Strongly recommended: without
  it a broken dispatch is only a log line, because a 502 back to Sentry is
  not an error as far as Cloudflare is concerned. Any project's DSN works,
  including the one whose alert rule calls the Worker: self-reports are
  tagged `sentry_triage.self_report=true` and titled `[sentry-triage] ...`,
  and the Worker filters those echoes out, so there is no feedback loop.
- `PROJECT_MAP` — JSON mapping Sentry project slugs → target GitHub
  repos. Example:

  ```jsonc
  {
    "frontend": { "repo": "acme/web", "eventType": "sentry-triage" },
    "api": { "repo": "acme/api", "eventType": "sentry-triage" },
  }
  ```

- GitHub dispatch credential:
  - `GITHUB_PAT` (secret) — fine-grained PAT with `contents:write` +
    `actions:write` on every target repo.
  - (A GitHub App-based auth path is sketched in `worker-spec.md` but
    not implemented in the reference Worker — PAT is the supported
    mode today.)
- `SENTRY_SEEN` — KV namespace binding (create with
  `wrangler kv namespace create SENTRY_SEEN` and paste the id into
  `wrangler.toml`).

See `worker-spec.md` for the full env var reference.

## 4. Per-repo GitHub setup

In each target repo:

### Secrets (Settings → Secrets and variables → Actions)

- `CLAUDE_CODE_OAUTH_TOKEN` — same OAuth token used by other Claude Code
  workflows.
- `CLAUDE_PAT` — (optional) PAT used to dispatch follow-up CI workflows
  after the fix PR is opened. Falls back to `GITHUB_TOKEN` if absent.
- `SENTRY_AUTH_TOKEN` — **new.** The Internal Integration Auth Token from
  step 1. This lets the Claude Code run fetch full Sentry event data via
  the Sentry MCP. The workflow sends it as `Authorization: Sentry-Bearer
  <token>`: the hosted Sentry MCP keeps plain `Bearer` for its own OAuth
  tokens and answers 401 to an API token sent that way.

### Files

- `.github/workflows/sentry-triage.yml` — copy from this repo into the
  target repo (or vendor it into your shared workflows). Adjust
  project-specific bits in the prompt (lint/test commands, branch naming
  conventions, etc.).

## 5. Verify end-to-end

1. In Sentry, open the alert rule you just created and click **Send test
   notification**.
2. In the Cloudflare Workers dashboard (or `wrangler tail`), confirm the
   Worker logged a line with `decision: "dispatched"`.
3. In the target GitHub repo, open the **Actions** tab. A `Sentry Triage`
   run should be in progress.
4. Watch the run. Expected outcomes:
   - A PR appears on branch `sentry-fix/<SHORT_ID>` with a fix (or a
     reasoned no-op comment on the Sentry issue and no PR — both are
     acceptable).
   - If the run fails at **Verify Sentry MCP connected**, Claude ran
     without Sentry access: check `SENTRY_AUTH_TOKEN` and its scopes. The
     run's `claude-transcript-<SHORT_ID>` artifact (kept 7 days) shows what
     Claude saw.
6. Optional: revoke or mistype `GITHUB_PAT` on a staging Worker and send a
   test notification. The Worker should answer 502 and a
   `[sentry-triage] github_dispatch_failed: GitHub 401` issue should appear
   in the `SENTRY_DSN` project, without a second dispatch.
7. Trigger a **real** error in staging. Confirm Rule A fires, and confirm
   a second identical error within 30 days does NOT re-trigger (action
   interval doing its job).

## 6. Cost guardrails

Monitor for the first two weeks:

- **GitHub Actions minutes** — `Sentry Triage` runs cap at 90 min; track
  p95.
- **Claude Code credits** — each run uses plan credits (the workflow uses
  the same `CLAUDE_CODE_OAUTH_TOKEN` as other workflows). If runs start
  eating into the budget, tighten Sentry filters before switching models.
- **Worker invocations** — should roughly match the combined "dispatched +
  filtered" count. A sudden spike means either the alert rules are too
  loose or Sentry is retrying (check Worker 5xx responses).

If cost becomes an issue, in priority order:

1. Raise the event-count / user-count thresholds on Rule B.
2. Restrict Rule A to `level:fatal` only.
3. Switch the triage workflow to `--model sonnet`.
4. Remove lower-value projects from `PROJECT_MAP`.

## 7. Rollback

Fastest to slowest, depending on severity:

- **Disable an alert rule** in Sentry → stops new dispatches for that
  project immediately.
- **Remove a project from `PROJECT_MAP`** and redeploy the Worker → Worker
  drops any further webhooks for that project with a `filtered` log line.
- **Disable the workflow** in the target repo (Actions → `Sentry Triage`
  → ⋯ → Disable workflow) → stops existing dispatches from running, but
  Worker still spends KV/GitHub quota on the POST.
- **Revoke `SENTRY_CLIENT_SECRET`** in Sentry → kills the pipeline at the
  source. Nuclear option; use if something is very wrong.
