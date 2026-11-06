# Server Performance Review (Backend Runtime & Cost)

## Objective

Deep audit of **backend runtime performance and cost** — the work the backend
does per request and the money each user action spends on external services.
The **client** half (bundle size, Core Web Vitals, render cost) lives in
`performance-client.md`, and longer-horizon **growth/architecture** projections
live in `scalability.md`. Stay in your lane: this review is about how efficient
the backend is _right now_ and at near-term scale.

For every pattern, ask: "Does this work at today's user count? At 10x? At
100x?" If the answer is "no" at any scale, flag it and fix it now.

## Scaling Context

At 10x scale:

- Database tables are 10x larger. Full table scans that took 50ms now take 500ms.
- Concurrent writes increase 10x. Hot-spot records become write bottlenecks.
- Real-time subscriptions multiply. Each connected client holds open live queries.
- Calls to payment, email, and AI providers increase proportionally.
- Server/edge invocations and bandwidth scale with traffic.

At 100x scale:

- Any O(n) scan becomes a real problem. Indexes are mandatory, not optional.
- N+1 query patterns that worked fine with 10 items now fire 1,000 queries.
- Connection counts for real-time features approach infrastructure limits.
- Cost scales linearly (or worse) with every unoptimized external API call.

## Review Checklist

### Query Performance (HIGHEST PRIORITY)

- [ ] **Index coverage audit**: For EVERY unindexed filter/scan:
  - What table is it on?
  - How many rows will that table have at 10x? At 100x?
  - If >1,000 rows possible: this MUST use an index
  - A filter applied _after_ an index range is fine; a filter over the whole
    table is a scan. Range conditions (`expiresAt < now`, `createdAt < cutoff`)
    need a compound index that includes the range field, or the query scans
    past its limit.
- [ ] **N+1 query detection**: Search for patterns where:
  - A query returns a list, then each item triggers another lookup
  - A loop contains a database query inside it
  - Multiple sequential lookups that could be batched or run in parallel
- [ ] **Unbounded result sets**: Queries without a limit or pagination:
  - "Get all items for user" — fine at 5, broken at 500
  - "Get all members" — fine at 20, broken at 2,000
  - Every list query needs a limit or pagination strategy
- [ ] **Silent truncation**: a scan cap (`take(10_000)`) that quietly drops
      older rows is a correctness bug, not a fix — use an index or a junction
      table so the lookup is a point read. Never cap a correctness-critical
      aggregation (relationship edges, ledger sums) without a cursor that drains it.
- [ ] **Over-fetching**: Queries returning entire records when the client uses
      a few fields — at scale this wastes bandwidth and memory
- [ ] **Live/reactive query cost**: each real-time subscription is a standing
      query that re-runs on every relevant write:
  - How many live queries does the average page open?
  - Are any on large, frequently-updated tables?
  - Could some be one-time fetches instead?

### Write Performance

- [ ] **Write hot spots**: records updated by many concurrent users — global
      counters, aggregate stats, "the one row that tracks X for everyone",
      a shared balance row. Fix: shard the counter, derive the number from an
      append-only ledger at read time, or accept eventual consistency.
- [ ] **Transaction size**: mutations that read/write many records stay within
      the backend's per-transaction limits at 10x data size
- [ ] **Cascading writes**: one write triggering many downstream writes
- [ ] **Unconditional backstops**: a periodic job that rewrites O(n) rows
      whether or not anything changed — gate it on a dirty flag
- [ ] **Fan-out recompute**: a user action that schedules a recompute per
      member/follower should be coalesced/debounced and paginated

### Background Jobs & Crons

- [ ] **Cleanup jobs paginate.** A cleanup that collects every stale row and
      deletes them in one transaction is a death spiral once the backlog passes
      the write limit (it fails, the backlog grows, it fails harder). Delete in
      fixed-size batches and self-reschedule until drained.
- [ ] **Cursors advance.** Incremental jobs resume from a stored cursor instead
      of re-walking from the beginning every run.
- [ ] **Bounded concurrency** for outbound calls in a loop: run in waves of N,
      not 1,000 sequential calls per tick, and not 1,000 at once.
- [ ] **Side effects are confirmed before marking done.** Mark a reminder/email
      "sent" only after the send succeeded (and check its return value), or a
      transient failure silently loses it forever.
- [ ] **Large deletes/cascades** (account deletion, merges) are paginated across
      scheduled steps rather than one transaction that can partially fail.

### Network & Payload (server side)

- [ ] **Redundant calls**: every wasted call multiplies at scale
- [ ] **Payload size**: responses that grow with user count — leaderboards,
      member lists, activity feeds — need pagination. What is the largest
      possible response at 100x?
- [ ] **Waterfall requests**: sequential calls that could be parallelized

### Rate Limiting & Cost Control (CRITICAL AT SCALE)

- [ ] **Per-user throttles**: are limits appropriate for 10x more users? Can
      they be bypassed with multiple accounts? What is the worst-case cost if
      every user hits them?
- [ ] **Rate-limit buckets are per feature/cost class.** One shared counter
      across chat, image, and voice lets a cheap feature exhaust an expensive
      one's budget (or vice versa).
- [ ] **AI/ML API costs**: token limits, request caps — calculate the monthly
      cost at 10x and 100x active users. Are there per-user daily/monthly caps?
- [ ] **Third-party rate limits**: could a peak hit a payment or AI provider's
      rate limit? Are calls batched or queued?
- [ ] **Other metered services**: email, bandwidth, function invocations —
      model costs at 10x and 100x

### Data Lifecycle

- [ ] **Index selectivity at scale**: indexes that work at 1,000 rows may be
      poorly selective at 100,000
- [ ] **Data archival**: tables that grow indefinitely (logs, events, rate-limit
      rows, notifications) have cleanup or archival
- [ ] **Pagination everywhere**: any endpoint that returns a list paginates

### Concurrency & Real-Time

- [ ] **Connection limits**: how many simultaneous live subscriptions at 100x?
- [ ] **Subscription fan-out**: a write on a popular record notifies every
      subscriber — at scale this is expensive
- [ ] **Optimistic updates** reduce perceived latency under load where the
      client supports them

## Known Hotspot Map (LIVING — keep this current)

> A code-grounded map of the heaviest **backend** hot paths in THIS repo, with `file:line` anchors. A
> generic checklist rots; a map that points at the real hot queries, counters, and crons compounds every run —
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

## Severity Guide

- **CRITICAL**: Full table scan on a table that will exceed 10K rows on a hot
  path, unbounded query with no pagination, a cleanup job that can death-spiral,
  O(n²) work on user data
- **HIGH**: N+1 pattern on growing data, missing rate limits or cost caps,
  write hot spots that will serialize under load, silent truncation of a
  correctness-critical read
- **MEDIUM**: Missing pagination on growing lists, redundant calls, unbatched
  sequential outbound calls, a backstop job doing unconditional work
- **LOW**: Minor optimization opportunities, parallelizing small bounded reads
