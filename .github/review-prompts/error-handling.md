# Error Handling & Resilience Review

## Objective

Audit the codebase for proper error handling. Every error must be reported,
every failure must be visible, and no bug should hide in a silent catch block.

The core principle: **"If this fails in production, will we find out?"**

## Review Checklist

### Silent Error Suppression (The Cardinal Sin)

Search the ENTIRE codebase for these anti-patterns and flag every instance:

- [ ] `catch (_e) { }` or `catch (e) { }` with empty body
- [ ] `.catch(() => {})` or `.catch(() => undefined)`
- [ ] `catch` blocks that only `console.warn` without throwing or reporting
- [ ] `catch` blocks that return `null`/`undefined` without reporting the error
- [ ] `try/catch` around code that should be allowed to throw

### Over-Suppression of Legitimate Alerts (The Mirror Sin)

The opposite failure of the Cardinal Sin: muting a **real** signal instead of
fixing it. "Fail loud" is about alerting on the right things — the default is
fail-fast, so bias toward alerting. Flag any change that hides an actionable
error from your error-reporting service:

- [ ] A **misconfiguration / missing environment variable / unconfigured admin
      surface** routed to a silent path (a `beforeSend`-style filter, a new
      expected-error-code allowlist entry, a "return a sentinel instead of
      throwing" refactor). These MUST alert — that is how you learn the system is
      broken and fix it. This is a finding regardless of severity.
- [ ] A new entry added to the expected/ignored-error allowlist that is **not** a
      benign, per-user business outcome. Only expected outcomes already shown to
      the user (limit reached, insufficient credits, rate limited, nothing to do)
      belong there — never anything an engineer or admin could fix.
- [ ] An error path that alerts on a **transient failure the system already
      recovered from** (e.g. a retry that then succeeded). That is noise the other
      direction — log it as a distinct "retry" class, don't page. But a failure
      that persists **after** retries are exhausted MUST alert.
- [ ] A `beforeSend` / ignore-list / sentinel added "to make a noisy alert go
      away" without evidence the underlying condition is genuinely benign and
      non-actionable. Suppression is the rare exception, not the default fix.

### Backend Error Handling

- [ ] Prefer throwing over catching — let the framework's error reporting catch
      unhandled errors automatically
- [ ] When catching is necessary:
  - Log the error with context (function name, parameters, user ID)
  - Either re-throw OR return an explicit error result
- [ ] Structured error types for client-distinguishable errors
  (e.g., `INSUFFICIENT_CREDITS`, `RATE_LIMITED`, `NOT_FOUND`)
- [ ] No `console.log` for errors — use proper error reporting
- [ ] `console.warn` is ONLY for non-error conditions (disabled features, etc.)
- [ ] Scheduled functions and cron jobs have proper error reporting
- [ ] Server actions that call external APIs report failures clearly

### Frontend Error Handling

- [ ] Error reporting service (Sentry, etc.) is called for all caught errors
  - Even when recovering gracefully, report to the error service
- [ ] User-facing errors show appropriate feedback (toast, error boundary, etc.)
- [ ] Failed API calls are NEVER silently swallowed
- [ ] Error boundaries exist for critical UI sections
- [ ] Network failures show appropriate user feedback
- [ ] Loading states handle the error → loaded → error cycle correctly

### Promise Handling

- [ ] No floating promises (every Promise is awaited, returned, or explicitly voided)
- [ ] No misused promises (an async function passed where a sync callback is
      expected, e.g. as an event handler or `forEach` callback, so its rejection
      goes nowhere)
- [ ] `Promise.all` / `Promise.allSettled` usage handles individual rejections
- [ ] Async event handlers properly catch and report errors
- [ ] Reactive/computed values with async operations handle errors

### Error Context & Debugging

- [ ] Error messages include enough context to diagnose the issue:
  - What operation was attempted
  - What input was provided (without PII)
  - What the expected outcome was
- [ ] Stack traces are preserved when re-throwing
- [ ] Error boundaries don't lose error context by catching too broadly
- [ ] Error tracking tags/context are set for important error categories

### Resilience Patterns

- [ ] External API calls have:
  - Appropriate timeout configuration
  - Retry logic where idempotent
  - Circuit breaker or backoff patterns where appropriate
- [ ] Webhook handlers are idempotent (safe to retry)
- [ ] Rate limiting returns clear error responses, not silent drops
- [ ] Graceful degradation: if a non-critical feature fails, the rest works

### Error Monitoring Completeness

- [ ] The error-reporting service is configured and receiving errors in production
- [ ] Critical code paths have explicit error tracking
- [ ] Error grouping is meaningful (not everything lumped into one issue)
- [ ] Alerts exist for critical error types or error-rate spikes

### CI/CD Failure Visibility

- [ ] All scheduled (cron) CI workflows notify the team on failure
- [ ] Push-to-main workflows notify on failure (not just PR checks)
- [ ] Manually dispatched (non-PR) workflows notify on failure too
- [ ] Matrix workflows notify from one dedicated job (`needs:` the matrix), not
      a per-matrix-entry step, so one bad run doesn't send N duplicate alerts
- [ ] Background jobs that can fail without anyone noticing have alerting

## Anti-Patterns to Fix

1. **The Silencer**: `catch () {}` — Fix: report + rethrow or return error
2. **The Logger**: `catch (e) { console.warn(e) }` — Fix: use error reporting + rethrow
3. **The Swallower**: `.catch(() => null)` — Fix: report + handle explicitly
4. **The Hider**: `try { ... } catch { return defaultValue }` — Fix: at minimum report
5. **The Optimist**: No error handling at all on external calls — Fix: add proper handling
6. **The Muffler**: suppressing a legitimate alert (misconfig / missing env var routed to
   a `beforeSend` filter, an expected-error allowlist, or a sentinel) — Fix: keep it loud, fix the root cause

## Severity Guide

- **CRITICAL**: Silent catch hiding security or data-loss errors
- **HIGH**: Backend functions without error reporting, user-facing failures with no feedback; a misconfiguration / missing-env-var alert suppressed instead of surfaced
- **MEDIUM**: Missing error context, incomplete error messages, missing retries; an unjustified allowlist/`beforeSend` suppression of a plausibly-actionable error
- **LOW**: Verbose error handling that could be simplified, minor context improvements; alerting on transient failures the system already recovered from
