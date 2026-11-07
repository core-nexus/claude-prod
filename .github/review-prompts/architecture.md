# Software Architecture Review

## Objective

Deep audit of software architecture changes over the **last 30 days**. This
review is explicitly scoped to _changes_, not a full-codebase audit. The goal
is to catch architectural drift, schema mistakes, and scalability footguns
while they are still fresh and cheap to fix.

Architecture overlaps heavily with scalability — any change that alters the
shape of the data, the boundaries between modules, the flow of requests, or the
contract between services is in scope. When in doubt, ask: "Would a new
engineer need to understand this to reason about how the system is built?" If
yes, it's architecture.

## Scope: The Last 30 Days of Changes

**Do NOT audit the entire codebase.** Focus your review on what has actually
changed recently. Use git to discover the scope:

```bash
# All commits in the last 30 days on the default branch
git log --since="30 days ago" --no-merges --pretty=format:'%h %s' origin/main

# All files touched in the last 30 days
git log --since="30 days ago" --no-merges --name-only --pretty=format: origin/main \
  | sort -u | grep -v '^$'

# Aggregate diff for a specific path (may be large — sample or grep as needed)
git log --since="30 days ago" --no-merges -p origin/main -- path/to/data-model
```

From that list, prioritize files that are architecturally significant:

- The data-model / schema definition — usually the single most important file
  for this review
- Backend query/mutation/action/handler definitions and scheduled jobs
- Any generated code that should track the schema cleanly
- Cross-cutting business-logic / service modules
- Global state and store definitions
- Request/session lifecycle entry points (server hooks, layout/root loaders)
- Build and runtime configuration
- Any new top-level directories or new packages/dependencies
- Any new environment variables

Files that are obviously _not_ architecture (pure styling, copy changes,
dependency bumps with no API change, test-only edits) can be skipped.

If `git log --since="30 days ago"` produces _no_ commits (unlikely but
possible), fall back to the last 60 days. Document which window you used at the
top of your findings.

## Review Checklist

### Schema / Data-Model Changes (HIGHEST PRIORITY)

Walk every diff to the data model in the window. For each change:

- [ ] **Intent is clear** — can you explain why this field/table/index exists
      without reading the change description?
- [ ] **Backward compatibility** — field removals, type narrowing, and
      required-field additions are breaking changes. Was there a migration?
      Are existing records still readable?
- [ ] **Indexes match the queries** — every new query pattern has an index.
      Every new index has a query that uses it. No speculative indexes, no
      missing ones.
- [ ] **Validators/constraints are tight** — permissive "any" types are a
      smell; concrete shapes and unions are better. Optional vs required is
      intentional.
- [ ] **Cross-table references** use a typed reference to the target table, not
      a bare string.
- [ ] **Denormalization is justified** — if a field is duplicated from another
      table, is there a clear write path that keeps it in sync?
- [ ] **Table growth profile** — will this table grow linearly with users,
      faster, or slower? Is that OK at 10x and 100x scale (see the scaling
      context in `performance-server.md` and `scalability.md`)?
- [ ] **Privacy blast radius** — does the new shape make sensitive data easier
      or harder to leak? (Overlaps with the privacy review, but schema changes
      deserve a fresh look here.)

### New or Changed Public APIs (queries / mutations / actions / endpoints)

- [ ] Name is descriptive and consistent with neighbors
- [ ] Public vs internal is correct — internal logic is not exposed publicly
- [ ] Auth is checked where appropriate
- [ ] Arguments are validated with concrete validators
- [ ] Return shape is stable and documented by its validator/type
- [ ] Error modes use a structured error type where the client must
      distinguish them
- [ ] Rate limiting / cost controls exist for anything that calls out to paid
      APIs

### Module Boundaries & Layering

- [ ] Business logic lives in dedicated service/backend modules, not inside UI
      components
- [ ] No new cross-module dependencies that violate existing boundaries (e.g. a
      UI component reaching directly into auth internals)
- [ ] Shared logic has one owner — no duplicated calculation pipelines
- [ ] New modules have a single, obvious place to live; they aren't scattered
      with unclear ownership
- [ ] Backend code does not import UI/browser-only code

### Data Flow & Lifecycle

- [ ] Request/session lifecycle changes are minimal and well-justified
- [ ] New reactive subscriptions on the frontend are scoped appropriately —
      they unsubscribe, they don't fan out on every keystroke
- [ ] Scheduled/background functions are idempotent and report failures
- [ ] New external-service integrations have a defined failure mode (retry?
      fail loudly? degrade gracefully with a reported error?)

### Storage & Media

- [ ] New file/media paths use the project's designated object/media storage,
      not an ad-hoc or discouraged storage location
- [ ] New asset URLs use the configured delivery host/CDN
- [ ] No new large-blob storage is introduced where a dedicated media pipeline
      is expected — flag any regressions here

### Scalability Overlap

For each architectural change, answer: "Does this hold at 2,000 users? At
20,000?" Specifically:

- [ ] New queries use indexed lookups, not full-table filters, on any table
      that will exceed a few thousand rows
- [ ] No new unbounded list queries — results are limited or paginated
- [ ] No new write hot spots (global counters, shared documents updated by many
      users concurrently)
- [ ] No new N+1 patterns introduced by list views or feed code

### Configuration & Environment

- [ ] New env vars are documented in the example env file
- [ ] New env vars follow the positive-naming rule (`FEATURE_ENABLED=false`,
      not `FEATURE_DISABLED=true`)
- [ ] New config values have safe defaults and are read through one path, not
      scattered direct-env reads
- [ ] No secrets committed; no production endpoints hardcoded

### Dependencies (architectural impact only)

- [ ] New runtime dependencies are justified (can't be done with what's already
      present?)
- [ ] New dependencies don't duplicate existing ones (e.g. a second date
      library, a second validation library)
- [ ] New dependencies are tree-shakeable and don't balloon the bundle —
      cross-reference `performance-client.md`
- [ ] Deprecations or removed dependencies are clean (no dead imports)

### Tests Around Architectural Changes

- [ ] New mutations/queries have tests that exercise real code paths rather
      than mocking internals
- [ ] Schema changes that imply a migration have a test that exercises both the
      old and the new shape
- [ ] New service modules have tests that exercise them through their real
      public API

## What This Review Is NOT

- Not a style review — ignore formatting and naming nits
- Not a duplicate of the security, privacy, or performance reviews — you will
  inevitably overlap with them on schema and query concerns, but your lens is
  "did the architecture change well?" rather than "is the whole codebase
  secure/private/fast?"
- Not a full-codebase audit — if a file wasn't touched in the last 30 days, it
  is out of scope unless a recent change makes it newly problematic (e.g. an old
  query that is now unsafe because the table it reads grew)

## Output Format

When writing the findings, include at the top:

1. The git window you actually reviewed (e.g. "2026-03-12 to 2026-04-11")
2. A short list of the architecturally significant changes you looked at
3. Then the findings, grouped by severity

This makes it trivial for a reviewer to verify you reviewed the right slice of
history.

## Severity Guide

- **CRITICAL** — Breaking schema change without a migration path that will
  corrupt or orphan existing data; a new public mutation with no auth on a
  sensitive operation
- **HIGH** — New query that will full-scan a table that grows with users; new
  scheduled job with no failure reporting; new external integration with no
  defined failure mode; regression to a discouraged storage path
- **MEDIUM** — Missing index for a new query pattern; denormalization with no
  sync path; new env var without docs; new module duplicating existing logic;
  new list query without pagination
- **LOW** — Module-boundary drift that could be cleaned up; minor shape
  inconsistencies; missing tests on non-critical new code; naming/organization
  nits on new files that otherwise work
