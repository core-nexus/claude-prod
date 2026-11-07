# Worker specification: `sentry-triage`

The reference implementation lives at
[`workers/sentry-triage/`](../../workers/sentry-triage/). This document is
the design spec — useful when reimplementing, extending, or porting the
Worker to another runtime.

## Purpose

Receive Sentry webhooks, verify and filter them, and translate each "worth
triaging" event into a GitHub `repository_dispatch` in the correct target
repo. The target repo runs its own `sentry-triage.yml` workflow which
invokes Claude Code to open a fix PR.

The Worker is a thin, stateless-ish bridge. It does NOT do the triage
itself. It does do:

- Signature + timestamp verification (drop replays and spoofed requests).
- Payload normalization across Sentry's different webhook resource types.
- Extraction of as much useful context as will fit in `client_payload`
  (10 KB limit).
- Multi-project routing via config (one Sentry project → one GitHub repo).
- Short-term dedup so a flapping rule can't double-dispatch.
- Observability: structured logs + self-reporting its own failures to
  Sentry (strongly recommended; see "Observability").

## Non-goals

- Running Claude itself. That happens in the target repo's GitHub Action.
- Long-term dedup. Use Sentry alert-rule action intervals for that.
- Fetching the full Sentry event body. Include a reference; let Claude
  fetch via the Sentry MCP.

## HTTP surface

| Method | Path              | Purpose                                        |
| ------ | ----------------- | ---------------------------------------------- |
| `POST` | `/sentry/webhook` | Receive a Sentry Internal Integration webhook. |
| `GET`  | `/health`         | 200 OK, used by uptime checks.                 |

Any other method/path → 404. No CORS required; no browsers call this.

## Request validation (in order)

Reject with the noted status if any check fails. Log the reason but do not
echo details back to the caller.

1. **Method & content-type.** `POST` + `application/json` → else
   `405` / `415`.
2. **Size.** Reject bodies over 1 MB → `413`. Sentry webhooks are well
   under this.
3. **Headers present.** `Sentry-Hook-Resource`, `Sentry-Hook-Timestamp`,
   `Sentry-Hook-Signature` all required → else `400`.
4. **Timestamp freshness.** `|now − Sentry-Hook-Timestamp| ≤ 5 min` →
   else `401`. (Protects against replay of an old capture.)
5. **Signature.** HMAC-SHA256 of the **raw body** using
   `SENTRY_CLIENT_SECRET`, compared to `Sentry-Hook-Signature` in
   constant time. Mismatch → `401`.
6. **Resource allow-list.** `Sentry-Hook-Resource` ∈ `{event_alert,
   issue, metric_alert}`. Others → `200` with
   `{status:"filtered",reason:"unsupported_resource"}`. Only the first
   two are actively triaged.
7. **JSON parse.** Malformed → `400`.

Sentry expects a 2xx within its timeout (~5s) or it will retry. Do the
heavy work (dispatch call, KV writes) after the validation passes, but
respond fast.

## Normalization

Sentry ships two shapes we care about, both under `Sentry-Hook-Resource`:

**`event_alert`** (Issue Alert rule fired — the same integration Slack
uses):

```jsonc
{
  "action": "triggered",
  "installation": { "uuid": "..." },
  "data": {
    "event": {
      /* full event: exception, stacktrace, breadcrumbs, tags, request, contexts */
    },
    "triggered_rule": "Alert rule name",
  },
}
```

**`issue`** (issue lifecycle — created / resolved / unresolved / assigned
/ archived):

```jsonc
{
  "action": "created" | "resolved" | "unresolved" | "assigned" | "archived" | "ignored",
  "installation": { "uuid": "..." },
  "data": {
    "issue": { /* issue summary: shortId, title, culprit, level, firstSeen, count, ... */ }
  }
}
```

Normalize both into a single internal shape:

```ts
type Normalized = {
  projectSlug: string // Sentry project slug
  orgSlug: string // Sentry org slug
  shortId: string // e.g. "PROJECT-4F2"
  issueId: string // numeric, stable identifier
  title: string
  culprit: string | null
  message: string | null // event message / logentry, or issue metadata value
  level: 'fatal' | 'error' | 'warning' | 'info' | 'debug'
  platform: string // "javascript", "node", etc.
  environment: string | null
  release: string | null
  transaction: string | null
  serverName: string | null
  firstSeen: string | null // ISO-8601 — blast-radius (see note below)
  lastSeen: string | null // ISO-8601 — blast-radius
  count: number | null // total event frequency — blast-radius
  userCount: number | null // affected users — blast-radius
  issueType: string | null // e.g. "error"
  issueCategory: string | null
  isUnhandled: boolean | null
  sentryIssueUrl: string // human URL for the issue
  sentryEventUrl: string | null // human URL for the specific event (only for event_alert)
  sentryApiEventUrl: string | null // API URL to fetch full event JSON
  sentryApiIssueUrl: string | null // API URL to fetch exact issue counts
  latestEventId: string | null
  triggeredRule: string | null
  trigger: 'created' | 'regressed' | 'escalated' | 'event_alert' | 'other'
  // Light context — first few frames + a few breadcrumbs, so Claude has something
  // to work with even if Sentry MCP is temporarily unavailable.
  exception: { type: string; value: string } | null
  topFrames: Array<{
    filename: string | null
    function: string | null
    lineNo: number | null
    colNo: number | null
    inApp: boolean
    contextLine: string | null
  }>
  breadcrumbs: Array<{
    category: string | null
    level: string | null
    message: string | null
    timestamp: string | null
  }>
  tags: Record<string, string> // all non-secret tags — flat key→value
  request: { url: string | null; method: string | null; queryString: string | null } | null
  user: {
    id: string | null
    username: string | null
    email: string | null // null when REDACT_PII=true
    ipAddress: string | null // null when REDACT_PII=true
    geo: Record<string, string> | null
  } | null
  contexts: Record<string, Record<string, string>> // whitelisted, flattened
  sdk: { name: string | null; version: string | null } | null
  fingerprint: string[]
  extra: Record<string, string> // stringified, truncated
  dispatchId: string // uuid we generate, for tracing end-to-end
}
```

Mapping rules:

- `trigger`: for `event_alert` → `"event_alert"`. For `issue` →
  `"created"`, `"regressed"` (on `unresolved`), or `"other"` (on
  assigned/archived/ignored; these we drop in filtering below).
- `projectSlug` / `orgSlug`: from `data.issue.project.slug` /
  `data.issue.organization.slug` for the `issue` shape, or derived from
  URLs for `event_alert`. Both should be present in practice; if neither
  is, log and skip.
- `topFrames`: take up to **10** frames from the last exception's
  stacktrace, preferring `in_app:true` frames; if fewer than 10 in-app
  frames exist, fill with non-in-app frames. Truncate `contextLine` to
  200 chars.
- `breadcrumbs`: last **10** breadcrumbs in chronological order.
  Truncate messages to 200 chars.
- `tags`: convert the `[[k, v], ...]` array (or `{key, value}` objects) to
  an object. Forward all of them (up to 50, values truncated to 200 chars) —
  tags carry a lot of triage signal (feature flags, tenant ids, custom
  dimensions) — except keys that look like secrets (`secret`, `token`,
  `password`, `api_key`, `auth`, `credential`, `cookie`, `session`,
  `private_key`), which are always dropped, and PII keys (`user.email`,
  `user.ip_address`, `ip`, ...) when `REDACT_PII=true`.
- `request`: url and method; the query string only when `REDACT_PII=false`
  (it often carries tokens).
- `contexts`: only `trace`, `runtime`, `os`, `browser`, `device`, `app`,
  `gpu`, `culture`, `response`, `profile`, `replay`, each flattened to
  scalar strings. `extra`: up to 20 keys, secret-looking keys dropped,
  values stringified and truncated to 300 chars.
- `count` / `userCount` / `firstSeen` / `lastSeen`: taken from wherever the
  payload carries them (the issue object, a nested `data.issue` on newer
  `event_alert` payloads, or event metadata). `sentryApiIssueUrl` is always
  set so downstream can fetch exact numbers when they are absent.

## Filtering (second gate after Sentry's own filters)

Drop without dispatching (respond 200 with a `filtered` status) if any of:

- The event is the Worker's own self-report (tag
  `sentry_triage.self_report=true` or a title starting `[sentry-triage]`).
  This check runs before `PROJECT_MAP` is parsed, so a broken map cannot turn
  every echo into a fresh report.
- `trigger === 'other'` (we don't triage on assigned/archived/ignored).
- `level` not in `{fatal, error}` unless config explicitly allows
  warnings for this project.
- `(count ?? 0) < projectConfig.minEventCount` (default 1 — normally
  this is already enforced Sentry-side, but the Worker gets the last
  word).
- Worker KV has a recent dispatch for `(projectSlug, shortId)` within the
  TTL AND `trigger !== 'regressed'`. Regressions always pass through.

Every drop is logged with the reason so the filters can be tuned.

> **Scope of the Worker's dedup.** The KV guard keys on the exact
> `(projectSlug, shortId)`, so it only stops the *same* Sentry issue from
> re-dispatching. When Sentry splits one underlying bug into several issues with
> *different* shortIds, each still dispatches — that's intentional. Catching those
> semantic duplicates requires comparing stack fingerprints against in-flight
> fix PRs, which is the triage agent's job downstream, not the Worker's. The
> Worker's role is to carry enough context (including the `count` / `userCount` /
> `firstSeen` / `lastSeen` blast-radius fields above) for the agent to make that
> call authoritatively even when the Sentry MCP is unavailable.

## Routing

Config env var `PROJECT_MAP` is a JSON object, validated at startup:

```jsonc
{
  "frontend": {
    // Sentry project slug
    "repo": "acme/web", // GitHub owner/repo to dispatch to
    "eventType": "sentry-triage", // repository_dispatch event_type
    "minEventCount": 1, // optional, default 1
    "allowWarnings": false, // optional, default false
  },
  "api": {
    "repo": "acme/api",
    "eventType": "sentry-triage",
  },
}
```

If `projectSlug` isn't in the map → log and `filtered`. Unknown projects
are not an error; they're just projects that haven't been onboarded.

## Dedup (Cloudflare KV)

Binding: `SENTRY_SEEN` (KV namespace).

- Key: `seen:${projectSlug}:${shortId}`
- Value: `{ dispatchId, dispatchedAt, trigger }` as JSON
- TTL: 24 hours (`expirationTtl: 86400`)

Before dispatching, `get()` the key. If present AND
`trigger !== 'regressed'`, drop. After dispatching successfully, `put()`
the key.

If KV write fails, log but don't fail the request — Sentry's alert action
interval is the authoritative dedup; KV is a belt-and-suspenders
optimization.

## Dispatch to GitHub

`POST https://api.github.com/repos/{owner}/{repo}/dispatches`

Headers:

- `Authorization: Bearer ${installationToken}` (GitHub App — recommended)
  or `Authorization: Bearer ${GITHUB_PAT}` (fine-grained PAT — simpler).
- `Accept: application/vnd.github+json`
- `X-GitHub-Api-Version: 2022-11-28`
- `User-Agent: sentry-triage-worker/1.0`

Body:

```jsonc
{
  "event_type": "sentry-triage",
  "client_payload": {
    "shortId": "PROJECT-4F2",
    "data": "<stringified Normalized>", // see size note below
  },
}
```

GitHub's `client_payload` has two limits we juggle:

- 10 top-level properties — so the Normalized object is wrapped under a
  single `data` string (with `shortId` lifted to top level so the
  workflow can reference it from `github.event.client_payload.shortId`
  expressions).
- ~10 KB total (GitHub answers 422 "client_payload is too large") — the
  payload module measures the *actual* serialized `client_payload`
  (post-escaping, budget 9500 bytes) and shrinks the Normalized data
  progressively when it overflows. Order of things to drop: `extra` →
  breadcrumbs → contexts beyond trace/runtime/os/browser → topFrames beyond
  5 → tags beyond a core whitelist → topFrames beyond 3 → remaining contexts
  and fingerprint → contextLine on frames → truncate long strings. The
  aggregate counts, the exception, URLs and IDs are never dropped.

GitHub responds `204 No Content` on success. Any non-2xx → log and return
`502` to Sentry so it retries (Sentry retries failed webhooks with
exponential backoff).

### GitHub auth: recommended vs. pragmatic

- **Recommended — GitHub App.** Install one app on every target repo.
  Env vars: `GITHUB_APP_ID`, `GITHUB_APP_PRIVATE_KEY` (PEM). The Worker
  mints a JWT → exchanges for an installation token per target repo.
  Tokens are per-repo and expire in 1h, so the blast radius of a leaked
  token is small.
- **Pragmatic — fine-grained PAT.** One env var `GITHUB_PAT` with
  "contents:write" + "actions:write" on every target repo. Simpler to
  set up, one-secret-per-worker, but the token is long-lived and covers
  every repo in the map. **This is the mode the reference Worker
  implements today.**

A GitHub App path is straightforward to add (mint JWT → exchange for
installation token → swap into the Authorization header) but isn't in the
reference Worker yet.

## Response semantics

The Worker must respond to Sentry quickly (under its ~5s timeout). Two
patterns are fine:

- **Synchronous dispatch.** Do KV read, GitHub dispatch, KV write,
  respond `202 Accepted`. Almost always fast enough in Workers; the
  reference implementation uses this for simplicity.
- **`ctx.waitUntil()` deferred.** Validate, respond `202` immediately,
  finish the dispatch after. Only switch to this if timeouts start.

Always return a small JSON body
`{ dispatchId, status: "dispatched" | "filtered" | "deduped" | "rejected", reason? }`
so curl-debug sessions are sane.

## Observability

- **Logs.** One structured log line per request:
  `{ level, requestId, resource, action, projectSlug, shortId, decision, reason?, dispatchId?, durationMs }`.
  `decision` ∈ `{dispatched, filtered, deduped, rejected}`. Use
  `console.log` with JSON; rely on Workers Logpush to ship to a log
  sink.
- **Error reporting.** A 502 back to Sentry is not an error to Cloudflare,
  so the Worker reports its own failures with a dependency-free envelope POST
  to `SENTRY_DSN` (via `ctx.waitUntil`, so responses are not delayed):
  `github_dispatch_failed` (GitHub status + first 500 chars of its body, never
  the token), `no_github_credentials`, `bad_project_map`, and
  `unhandled_exception`. Each report is a message prefixed `[sentry-triage]`,
  tagged `sentry_triage.self_report=true`, with a fixed fingerprint
  (`sentry-triage` + reason [+ GitHub status]) so repeats group into one issue.
  The filter drops echoes of these, so the DSN may point at the same project
  the Worker triages without creating a loop. With no DSN set, failures are
  `level: "error"` log lines plus a `sentry_dsn_unset` line.
- **Metrics (nice-to-have).** Counter increments via Analytics Engine:
  `dispatched{project}`, `filtered{project, reason}`, `deduped{project}`,
  `rejected{reason}`, `dispatch_latency_ms{project}`.

## Configuration reference

| Env var                  | Type                          | Required     | Notes                                                       |
| ------------------------ | ----------------------------- | ------------ | ----------------------------------------------------------- |
| `SENTRY_CLIENT_SECRET`   | secret                        | yes          | From Sentry Internal Integration.                           |
| `PROJECT_MAP`            | JSON string                   | yes          | Sentry project slug → target repo config (see above).       |
| `GITHUB_APP_ID`          | string                        | if using app | Numeric GitHub App ID.                                      |
| `GITHUB_APP_PRIVATE_KEY` | secret                        | if using app | PEM-encoded private key.                                    |
| `GITHUB_PAT`             | secret                        | if using PAT | Fine-grained PAT with contents+actions write on targets.    |
| `SENTRY_DSN`             | string                        | recommended  | Where the Worker reports its own failures (see above).      |
| `REDACT_PII`             | string `true`/`false`         | no           | Default `true`. Strips user.email etc. from client_payload. |
| `ALLOW_WARNINGS_GLOBAL`  | string `true`/`false`         | no           | Default `false`.                                            |
| `LOG_LEVEL`              | `debug`/`info`/`warn`/`error` | no           | Default `info`.                                             |

| Binding       | Type             | Notes                           |
| ------------- | ---------------- | ------------------------------- |
| `SENTRY_SEEN` | KV namespace     | Dedup store. 24h TTL on values. |
| `ANALYTICS`   | Analytics Engine | Optional, for counters.         |

## Testing

The reference Worker follows TDD with no internal mocks. Real tests:

1. **Signature verification.** Known-good HMAC of a fixture body →
   passes. Off-by-one bodies / wrong secrets → 401. Stale timestamps →
   401.
2. **Normalization.** Feed recorded `event_alert` and `issue` payload
   fixtures (capture real ones from a test Sentry project; strip PII);
   assert the normalized shape matches.
3. **Routing.** With a fake `PROJECT_MAP` and a stubbed global `fetch`
   (this is an external service boundary — stubbing `fetch` is fine),
   assert GitHub receives the expected POST body on dispatch and no POST
   on drop.
4. **Dedup.** Simulate two requests in a row; second returns `deduped`.
   Simulate the same shortId with `trigger:regressed`; bypass takes
   effect.
5. **End-to-end smoke.** `wrangler dev` + `curl` with a real signed
   fixture body → look at the log line and the GitHub API interaction in
   the stub.

No mocking of internal modules (the normalizer, the filter, the config
loader, the KV helper). Wire them together for real; only external HTTP
(`fetch` to `api.github.com`) gets stubbed.

## Onboarding a new project

1. Add a new entry to `PROJECT_MAP` (Sentry project slug → GitHub
   owner/repo).
2. Deploy the Worker.
3. In the target GitHub repo: drop in a
   `.github/workflows/sentry-triage.yml`, set repo secrets
   (`CLAUDE_CODE_OAUTH_TOKEN`, `SENTRY_AUTH_TOKEN`).
4. In Sentry: create the Issue Alert rule in that project pointing at the
   Worker URL (see `setup.md` for the exact rule).
5. Fire a test event from Sentry's "Send test notification" button.
   Confirm the Worker log line, the dispatch, and the GitHub Actions
   run.

## Out of scope (possible v2)

- **Auto-closing PRs when Sentry issue resolves.** If Claude's fix
  merged, the issue naturally stops firing. If it's a no-op PR, a human
  can close it. Automation can come later.
- **Posting PR URL back as a Sentry comment.** Nice touch; needs a
  Sentry user token.
- **Batching bursty issues.** If 50 different errors all drop in one
  deploy, you might want to queue and coalesce. Not worth building until
  the failure mode actually appears.
