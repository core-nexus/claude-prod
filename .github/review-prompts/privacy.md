# User Privacy & Data Protection Review

## Objective

Deep-dive privacy audit ensuring user data is handled with care, minimized,
and protected throughout the codebase.

## Review Checklist

### PII in Logs & Error Reports

- [ ] Production logs NEVER contain PII (emails, names, phone numbers, IPs)
- [ ] Error reporting (Sentry, etc.) does not include PII in breadcrumbs or extra data
- [ ] `console.log`, `console.warn`, `console.error` calls do not leak user data
- [ ] Stack traces sent to external services are scrubbed of PII
- [ ] If a logging utility exists with auto-redaction, it is used consistently

### Data Minimization

- [ ] Each data field collected from users has a clear, documented purpose
- [ ] No unnecessary data is stored (e.g., collecting location when not needed)
- [ ] Temporary data (OTP codes, verification tokens) has TTL/expiration
- [ ] Analytics events do not include identifying information beyond user ID

### Data Access Patterns

- [ ] Queries return only the fields the client actually needs
- [ ] **The projection boundary holds.** Identify the canonical
      "scrub before return" helper for user records (strips tokens,
      payment-provider ids, contact details) and verify EVERY query that returns
      a user row either is the caller's own profile or projects only public-safe
      fields — never spreads the whole record
- [ ] Derived or inferred fields (scores, profiles, inferences) are gated as
      strictly as the sensitive inputs they are computed from, or they
      re-expose them
- [ ] Owner-only reads (private records, contact lookups) are
      gated to the owner/admin, and lookups by email/phone can't be used to
      enumerate accounts
- [ ] User data is not leaked through:
  - Overly broad query results
  - Error messages that include other users' data
  - Debug endpoints or admin panels without proper access control
- [ ] Search results respect visibility/permission settings

### User Consent & Control

- [ ] Users can see what data is collected about them
- [ ] Data collection points have clear consent mechanisms
- [ ] Users have a path to delete their data (right to erasure)
- [ ] Third-party data sharing is explicit and requires user consent
- [ ] Users can export their data (right to portability)

### Third-Party Data Flows

- [ ] Identify every external service that receives user data:
  - Payment processors (Stripe, etc.)
  - Error reporting (Sentry, etc.)
  - Email services (Resend, SendGrid, etc.)
  - CDN/hosting (Cloudflare, AWS, etc.)
  - AI/ML services (OpenAI, Anthropic, etc.)
- [ ] Each third-party integration sends only the minimum necessary data
- [ ] Data processing agreements are in place (or flagged as needed)

### Frontend Privacy

- [ ] No PII in URL parameters or fragment identifiers
- [ ] Local storage / cookies do not contain unnecessary PII
- [ ] Third-party scripts (analytics, tracking) are identified and documented
- [ ] Meta tags and Open Graph data do not expose private user information
- [ ] Service workers and caches do not persist sensitive data unnecessarily

### Data Retention

- [ ] Identify any data that grows unboundedly without cleanup
- [ ] Soft-deleted data has a hard-delete schedule or process
- [ ] Session data, tokens, and temporary records have expiration
- [ ] Log retention policies are appropriate for the data sensitivity

## Known Hotspot Map (LIVING — keep this current)

> A code-grounded map of where **PII actually lives and leaves** the system in THIS repo, with `file:line` anchors. A
> generic checklist rots; a map that points at the real PII fields and the safe-projection boundary compounds every run —
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

Seed it with: the tables/columns that hold PII, the safe-projection helper and
the queries that must use it, owner-gated read paths, admin-only PII surfaces
(and their gate), and every third-party service PII is sent to.

## Severity Guide

- **CRITICAL**: PII in production logs, user data exposed to other users
- **HIGH**: Missing data deletion path, excessive data collection, PII in URLs
- **MEDIUM**: Missing consent mechanism, PII in error reports, overly broad queries
- **LOW**: Minor data minimization improvements, documentation gaps
