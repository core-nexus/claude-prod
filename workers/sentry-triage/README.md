# sentry-triage

Cloudflare Worker that receives Sentry webhooks, verifies them, and fires a
GitHub `repository_dispatch` against the configured target repo. The target
repo's `sentry-triage.yml` workflow then invokes Claude Code to open a fix PR.

The Worker is a thin bridge. It does not run Claude itself.

## What it does

1. Validates the incoming request (method, content-type, size, headers, HMAC
   signature, timestamp freshness).
2. Normalizes Sentry's two main webhook shapes (`event_alert`, `issue`) into a
   single `Normalized` payload. It forwards as much context as fits: exception,
   stack frames, breadcrumbs, all non-secret tags, request/user/contexts/SDK,
   fingerprint, and `extra` — plus aggregate stats (`count`, `userCount`,
   `firstSeen`) whenever Sentry includes them. Aggregate counts are absent from
   `event_alert` webhooks, so a `sentryApiIssueUrl` is always included for the
   downstream workflow to fetch exact frequency/affected-user numbers.
3. Filters out noise: unknown projects, non-error levels (unless opted in),
   assigned/archived/ignored lifecycle events, recently-seen issues.
4. Fires `POST /repos/{owner}/{repo}/dispatches` with the normalized payload as
   `client_payload` (progressively shrunk to fit GitHub's 10 KB limit).
5. Records the dispatch in KV so a flapping alert rule cannot double-dispatch
   within 24 h. Regressions bypass dedup.

## Reporting its own failures

A 502 back to Sentry is not an error to Cloudflare, so a broken dispatch is
otherwise silent: an expired `GITHUB_PAT` makes every dispatch fail
without anyone noticing. The Worker therefore posts an error event to
`SENTRY_DSN` (via `ctx.waitUntil`, so the response is not delayed) when:

- GitHub answers the dispatch with a non-2xx (`github_dispatch_failed`, with the
  GitHub status and the first 500 chars of its body — never the token);
- `GITHUB_PAT` is missing (`no_github_credentials`);
- `PROJECT_MAP` does not parse (`bad_project_map`);
- anything throws out of the handler (`unhandled_exception`).

Without `SENTRY_DSN` these are only `level: "error"` log lines, plus a
`sentry_dsn_unset` line saying the failure was not reported.

The report lands in the same Sentry project whose alert rule calls this Worker,
so it comes straight back as a webhook. Every self-report is a message starting
with `[sentry-triage]` and tagged `sentry_triage.self_report=true`; the filter
drops anything carrying either (`reason: "self_report"`), so an echo is never
dispatched and can never fail into another report. A fixed fingerprint
(`sentry-triage` + reason [+ GitHub status]) groups repeats into one issue.

## HTTP surface

| Method | Path              | Purpose                                        |
| ------ | ----------------- | ---------------------------------------------- |
| `POST` | `/sentry/webhook` | Receive a Sentry Internal Integration webhook. |
| `GET`  | `/health`         | Liveness probe.                                |

Response body on `/sentry/webhook` is always a small JSON object:
`{ dispatchId, status, reason? }` where `status` is one of `dispatched`,
`filtered`, `deduped`, or `rejected`.

## Configuration

Secrets (`wrangler secret put <NAME>`):

- `SENTRY_CLIENT_SECRET` — from the Sentry Internal Integration.
- `PROJECT_MAP` — JSON string, Sentry project slug → `{ repo, eventType, minEventCount?, allowWarnings? }`.
- `GITHUB_PAT` — fine-grained PAT with `contents:write` + `actions:write` on all target repos.
- `SENTRY_DSN` — **strongly recommended.** Where the Worker reports its own
  failures (see above). Use the DSN of the Sentry project whose alert rule calls
  this Worker. A DSN is a public ingest key, not a secret; storing it as a Worker
  secret just keeps it alongside the rest of the config.

Vars (in `wrangler.toml` under `[vars]`):

- `LOG_LEVEL` — `debug`/`info`/`warn`/`error`. Default `info`.
- `REDACT_PII` — `true`/`false`. Default `true`. Strips `user.email` etc.
- `ALLOW_WARNINGS_GLOBAL` — `true`/`false`. Default `false`.

Bindings:

- `SENTRY_SEEN` (KV namespace) — dedup store with 24 h TTL. Create with
  `wrangler kv namespace create SENTRY_SEEN` and paste the id into `wrangler.toml`.
- `ANALYTICS` (Analytics Engine, optional) — counters.

Example `PROJECT_MAP`:

```json
{
  "frontend": {
    "repo": "acme/web",
    "eventType": "sentry-triage",
    "minEventCount": 1,
    "allowWarnings": false
  },
  "api": {
    "repo": "acme/api",
    "eventType": "sentry-triage"
  }
}
```

The keys are Sentry project slugs; the `repo` value is the GitHub
`owner/repo` to dispatch to. `eventType` defaults to `"sentry-triage"` and
must match the `repository_dispatch.types` entry in the target repo's
`.github/workflows/sentry-triage.yml`.

## Development

```
cd workers/sentry-triage
npm install
npm test            # unit tests, no internal mocks
npm run deploy:dry-run  # bundle + validate wrangler.toml without publishing
npm run typecheck
npm run dev         # wrangler dev
```

Tests wire the real modules together and only stub `fetch` (the external
GitHub and Sentry boundaries) and the KV namespace (`FakeKV` in tests implements the same
contract the real binding exposes).

The worker keeps its own isolated dependency tree. `vitest.config.ts`
pins an inline PostCSS config so Vite does not walk upward and load a parent
project's `postcss.config.*`. `.github/workflows/sentry-triage-worker-test.yml`
runs these tests in CI on any change under `workers/sentry-triage/`.

## Onboarding a new project

1. Add a new entry to `PROJECT_MAP` (Sentry project slug → target repo).
2. Deploy the Worker (`npm run deploy`).
3. In the target GitHub repo: drop in `.github/workflows/sentry-triage.yml`
   and set secrets (`CLAUDE_CODE_OAUTH_TOKEN`, `SENTRY_AUTH_TOKEN`).
4. In Sentry: create the Issue Alert rule pointing at the Worker URL
   (`https://<worker>.workers.dev/sentry/webhook`).
5. Fire a test event from Sentry's "Send test notification" button. Confirm
   the log line in the Worker, the dispatch on GitHub, and the resulting
   Actions run on the target repo.
