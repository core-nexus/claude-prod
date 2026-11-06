# Security & Authorization Review

## Objective

Deep-dive security audit of the entire codebase, focused on authentication,
authorization, injection, secrets, and attack surface reduction.

### Scope: the whole attack surface, not the recent diff

This review is NOT diff-scoped. Recent changes and the hotspot map below are
where you start, not where you stop. **The most dangerous code in a repo is the
code nobody has touched in years** — it is absent from every diff, absent from
every reviewer's memory, and still answering requests in production.

So each run must re-derive the ingress inventory from the filesystem rather than
from the map or from recent PRs. Enumerate every publicly reachable handler in
every runtime the project deploys — for example:

```bash
# Adapt to your frameworks. The point is: list them from disk, every run.
grep -rnE "app\.(get|post|put|patch|delete)\(|router\.|@app\.route|@(Get|Post)\(" src/
find . -path ./node_modules -prune -o \( -name 'route.*' -o -name '+server.*' \) -print
```

Diff every entry against the "Always re-check" map below. **An endpoint that
exists on disk but is not in the map has never been reviewed — open it and read
it before anything else.** Note in your findings how many endpoints the
inventory returned and that you reconciled them, so the next reviewer can tell
the sweep actually happened.

Git age is a risk signal, not a safety signal: `git log -1 --format=%ad -- <file>`
on an untouched handler tells you how long it has gone unexamined.

## Review Checklist

### Authentication & Session Management

- [ ] Every API endpoint or server function that accesses user data verifies
      the user's identity and handles the unauthenticated case
- [ ] Session tokens are not exposed in URLs, logs, or client-side storage
      beyond what the auth library requires
- [ ] Auth callbacks validate redirect URIs to prevent open redirect attacks
- [ ] Password/credential handling follows best practices (hashing, no plaintext)
- [ ] Token expiration and refresh logic is correctly implemented
- [ ] Dev/test-only credential paths (seed logins, magic test tokens, auth
      bypass flags) can NEVER authenticate in production — the guard is
      fail-closed (unknown environment = production)

### Authorization & Access Control

- [ ] Admin-only functions enforce admin access without exception — every
      privileged entry point calls the shared admin gate at its first line
- [ ] Ownership checks: users cannot read or modify other users' data
  - Payment sessions, billing info, subscriptions
  - Profile fields, user content, collections
  - Private content respects visibility/permission settings — including
        draft/unpublished state, which a visibility-only check can miss
- [ ] Sibling functions enforce the SAME rules: a `list` that skips the
      visibility filter its `get` sibling applies, or a mutation that checks
      permission on one record but writes to another (e.g. writing to a related
      record after checking only another), is a cross-user hole
- [ ] Queries that return user records project only public-safe fields; never
      spread a whole user row (tokens, payment-provider ids, contact details)
      into a response for another user
- [ ] Internal/server-only functions are never exposed as public endpoints
- [ ] Rate limiting exists and cannot be bypassed
- [ ] Role-based or permission-based access is consistently enforced, including
      membership status (a removed member must not be grantable a role)

### Input Validation & Injection

- [ ] All user inputs are validated and sanitized
- [ ] Numeric inputs are bounded and finite: a bare `< min || > max` check lets
      `NaN` through — reject `!Number.isFinite(x)` too, and cap counts/amounts
- [ ] No raw string interpolation into queries, commands, or HTML
- [ ] No unescaped user content rendered as HTML (XSS)
- [ ] User-authored URLs bound to `href`/`src`/`window.open` are scheme-checked
      (allow `http(s):`, reject `javascript:` / `data:`) at render —
      `target="_blank"` and `rel` do NOT block `javascript:`
- [ ] URL parameters and query strings are validated before use
- [ ] File uploads validate type, size, and content — server-side, not just in
      the UI
- [ ] SQL/NoSQL injection vectors are eliminated through parameterized queries

### Secrets & Configuration

**Committed secrets** — if the repo runs a secret scanner in CI (e.g. gitleaks),
this is the LEAST valuable thing to spend time on here:

- [ ] No API keys, tokens, or credentials committed to source
  - Check for hardcoded keys in code files
  - Check environment variable example files vs actual patterns

**Runtime secret exposure** — a secret that was never committed can still be
served to the internet by a running handler. Nothing else in CI checks this:

- [ ] No response body can contain the process/runtime environment. On many
      serverless/edge runtimes the request event or platform/context object
      carries every env var and secret as plain strings, so `JSON.stringify()`
      of anything transitively holding it dumps the lot. Grep for stringify /
      spread / return of `env`, `process.env`, request events, and context
      objects — then triage each hit (an `event` from a payment webhook is not
      the same as a request event).
- [ ] No handler echoes its own request event, context, or config object back to
      the caller — not even "just for debugging"
- [ ] Error responses and error pages do not leak env values, stack traces with
      embedded config, or upstream credentials
- [ ] Environment detection is FAIL-CLOSED: unknown environment = production
- [ ] API keys use correct prefix for the environment (test vs live)
- [ ] No logging of sensitive data (tokens, emails, PII, credentials)
- [ ] Shared-secret and signature comparisons are constant-time

**Diagnostic and debug surfaces** — the highest-yield thing to hunt in this
section, because they are written to be permissive and then forgotten:

- [ ] Enumerate anything named `debug`, `echo`, `test`, `diag`, `_status`,
      `whoami`, `env`, or `info` across every runtime's routes. For each: is it
      authenticated, and would you be content to see its full response body
      posted publicly? If the answer to either is no, it is a finding —
      regardless of how old it is or how obviously nobody uses it. A forgotten
      debug endpoint that echoes its request object is a classic way to serve
      every secret in the environment to an unauthenticated GET.
- [ ] A route gated only by obscurity (an unguessable path segment) is a LOW at
      best and must be called out as such — it is not authentication.
- [ ] Unauthenticated endpoints that write state (seeders, loggers, counters)
      cannot be looped to grow a table or exhaust a quota

### Multiple Runtimes & Ingress Points

If the project serves requests from more than one runtime (e.g. a backend
platform plus edge/serverless route handlers, or an API server plus a
frontend server with its own endpoints), **each one is a separate public
ingress with its own environment and its own auth rules.** Reviews that think
only in terms of the primary backend miss the others entirely.

- [ ] Every handler either (a) requires auth explicitly, (b) verifies a
      signature/shared secret, or (c) is deliberately, safely public. State
      which, for each, in your findings — "it looked fine" is not a review.
- [ ] Page-level login gates do NOT protect API/route handlers. A client-side
      or layout-level redirect governs pages only; a handler is reachable
      regardless.
- [ ] Handlers that read private env/config never let those values reach a
      response body
- [ ] Proxy/forwarder endpoints forward to the intended upstream only and cannot
      be steered into an open relay
- [ ] Admin-ish endpoints fail CLOSED when their gate is unconfigured (deny,
      don't expose, when the access-control layer is absent)

### OWASP Top 10 Considerations

- [ ] A01 Broken Access Control — covered by auth/authz checks above
- [ ] A02 Cryptographic Failures — proper use of crypto APIs, no weak algorithms
- [ ] A03 Injection — covered by input validation above
- [ ] A04 Insecure Design — check for security anti-patterns in architecture
- [ ] A05 Security Misconfiguration — headers, CORS, CSP, deployment config
- [ ] A06 Vulnerable Components — flag any known-vulnerable dependency versions
- [ ] A07 Authentication Failures — covered by auth section above
- [ ] A08 Software/Data Integrity — verify CI/CD integrity, dependency pinning
- [ ] A09 Logging/Monitoring Failures — ensure security events are logged
- [ ] A10 SSRF — validate any server-side URL fetching. When following
      redirects, re-validate the host on EVERY hop (or follow manually), and
      cap the response body size

### API & Webhook Security

- [ ] HTTP endpoints validate origin and authenticate requests
- [ ] Scheduled/cron functions don't have exploitable timing windows
- [ ] File storage URLs are scoped appropriately
- [ ] Webhook handlers verify signatures (with a timestamp tolerance) before
      doing any work
- [ ] Endpoints that call metered third-party APIs (LLMs, search, maps)
      have a per-user rate limit, so input jitter can't defeat a cache and burn
      the shared quota
- [ ] GraphQL/REST endpoints enforce query depth and complexity limits

## Known Hotspot Map (LIVING — keep this current)

> A code-grounded map of the enduring **security-sensitive surface** in THIS repo, with `file:line` anchors. A
> generic checklist rots; a map that points at the real auth gates and ingress points compounds every run —
> an insight not written back here is lost. Keep it reading true against the
> default branch.
>
> **Maintaining the map depends on which stage you are:**
>
> - **Review stage (read-only — you do NOT edit files or open PRs):** do not edit
>   this file. Record every new/changed/cleared hotspot in your findings issue
>   under a `Hotspot map updates` heading (with `file:line`, why it matters, and
>   the exact edit you'd make) so the fixer can apply it verbatim.
> - **Fix stage / manual PRs (you DO edit files):** apply those edits here in the
>   same PR — add new spots (`STATUS: open`), flip resolved ones
>   (`STATUS: fixed (<PR/date>)`), clear false alarms
>   (`STATUS: cleared (<reason>)`), and re-anchor drifted line numbers. Stale
>   `file:line` anchors are worse than none.

_Empty until the first review seeds it. One entry per hotspot:_

```markdown
- **`path/to/file.ext:123` `functionName` — what it is and why it matters.**
  What to re-check on every run. STATUS: open | fixed (<PR/date>) | cleared (<reason>)
```

Seed it with: the shared auth/admin gate functions (and every privileged entry
point that must call them), the full ingress inventory per runtime with each
handler's intended posture, webhook signature verification, the
"scrub-before-return" projection used for user records, and any dev-only auth
path with its production guard.

## Severity Guide

- **CRITICAL**: Auth bypass, data exposure, secret leak, injection vulnerability
- **HIGH**: Missing ownership check, unvalidated admin action, SSRF vector
- **MEDIUM**: Missing rate limit, overly permissive CORS, weak input validation
- **LOW**: Informational logging of non-sensitive data, minor config hardening
