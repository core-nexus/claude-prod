# Backend Scalability Review (Orders-of-Magnitude Growth)

## Objective

Audit the codebase — **principally the backend** — for the patterns that break
when the product grows by orders of magnitude in _concurrent_ users and in
_stored data_. This is a deliberately narrow, deep lens. We are not hunting for
slow render frames or bundle weight (that is `performance-client`) or today's
per-request efficiency (`performance-server`). We are hunting for the handful of
backend patterns that turn a healthy app at today's scale into an unavailable
one at 10x, and an unaffordable or impossible one at 1,000x.

### The north star

> **Survive 10x the concurrent users you can serve right now with zero
> architectural changes — and leave a clear, code-grounded path to millions.**

Judge every pattern against three horizons:

| Horizon               | Concurrent users       | What must be true                                                                |
| --------------------- | ---------------------- | -------------------------------------------------------------------------------- |
| **Now → 10x**         | thousands              | No code change needed. Indexes, bounds, and batching already hold.               |
| **100x**              | tens of thousands      | Architecture holds. Hot rows are sharded, lists paginate, fan-out is bounded.    |
| **1,000x → millions** | hundreds of thousands+ | No single record, query, or cron is a global bottleneck. Growth is horizontal.   |

For every pattern, ask out loud: _"What is the worst case at 10x? At 1,000x?"_
If the honest answer is "it falls over," that is a finding — flag it with the
severity it earns at the scale it breaks, **not** the (invisible) severity it has
today.

## Working without production telemetry

You will usually not have production logs, query traces, slow-query reports, or
hotspot dashboards in this environment. Do not pretend to. Instead, derive scale
risk **statically from the code and schema**, which is more than enough to find
the patterns that matter:

1. **Reason from table growth, not row counts.** You cannot see how many rows a
   table has. You _can_ read the schema and reason about how a table grows:
   per-user (linear), per-content (faster), per-message (fast), or per
   relationship/interaction (can be quadratic). Rank tables by growth class,
   then audit the hottest first.
2. **Count the work per request, symbolically.** For a given query/mutation,
   express its cost as a function of input size: `O(1)`, `O(participants)`,
   `O(items)`, `O(users)`. Anything that scales with a growing table — inside a
   single request — is a candidate finding.
3. **Find the global serialization points.** A single record every active user
   reads-modifies-writes is a future outage. Search for shared counters,
   aggregate rows, and "the one row that tracks X for everyone."
4. **Model external-service cost at scale.** Multiply per-user external calls
   (LLM tokens, image generation, email, payments) by the horizon user counts. A
   call that is fine per-user can be a five-figure monthly bill — or a
   rate-limit wall — at 100x.
5. **Trace fan-out.** A write on a popular record wakes every live subscriber.
   Follow what a single write touches and who is notified.

Where you genuinely cannot decide without runtime data, say so explicitly and
state the _cheapest experiment or instrumentation_ that would settle it — that
recommendation is itself a valuable finding.

## Review methodology

Work the backend in this order; it is sorted by blast radius.

### 1. Schema & table growth — START HERE

- [ ] Classify **every** table by growth: per-user, per-content, per-message,
      per-relationship (quadratic), or bounded. Write the list down.
- [ ] For each fast-growing table, list its indexes. Does **every** query path
      against it hit an index, or will some do a full scan at scale?
- [ ] Identify tables that grow **without bound and are never pruned** (logs,
      events, extracts, ledger rows, rate-limit rows). Is there a cleanup job or
      archival path? Unbounded growth is a cost and latency time bomb.
- [ ] Identify **quadratic** tables (relationship / many-to-many graphs). These
      are the first to become infeasible; confirm they are capped or paginated.

### 2. Query patterns (the scan / collect-all audit)

- [ ] **Unindexed filter on a full table = full scan.** Distinguish a filter
      applied _after_ an index range (fine — it filters the already-narrowed
      range) from a filter over the whole table (a scan that is invisible at
      small scale and fatal at large scale). Flag the latter.
- [ ] **Collect-all reads** on a table that grows with users/content. If the
      result set grows without a limit or pagination, it is a finding — the
      query gets slower forever and can blow the read limit.
- [ ] **N+1 reads.** Any loop that does a lookup per item. The fix is almost
      always a batched/parallel read, or denormalizing the needed field. At 10x
      list size this is 10x the round-trips inside one request.
- [ ] **Over-fetching.** Returning whole records when the client needs three
      fields multiplies bandwidth and the live-update payload at scale.

### 3. Write hot spots & contention

- [ ] **Global / shared rows.** Any record many users update concurrently
      (counters, aggregates, "stats", leaderboards, a single config row). Most
      databases serialize conflicting writes — this becomes a throughput
      ceiling. Look for sharded counters or an aggregate structure; flag
      unsharded hot rows.
- [ ] **Read-modify-write on growing data.** A write that reads a growing set to
      compute a count/sum first (e.g. capacity checks) gets slower as that set
      grows _and_ widens the transaction's conflict window.
- [ ] **Cascading writes.** One write that triggers N downstream writes; at 10x
      the cascade is 10x wider and more conflict-prone.

### 4. Crons & scheduled fan-out

- [ ] Does any cron iterate **all** users / all entities and schedule work per
      item? That is fine at thousands and a thundering herd at millions. Confirm
      it paginates/batches, staggers, and self-limits (per-tick cap + cursor).
- [ ] Does any cron make an LLM/external call **per** entity or per active user?
      Model the cost and the wall-clock at 100x.
- [ ] Are fan-out crons guarded by a flag and a hard cap so an accidental enable
      cannot stampede the backend?

### 5. Real-time subscription fan-out

- [ ] Which queries do many clients hold open simultaneously? A live query on a
      large, frequently-written table re-runs for every subscriber on every
      relevant write. Are public feeds/listings paginated and is their
      invalidation surface bounded?
- [ ] Could a single popular write (a comment on viral content, a new public
      post) fan out to every connected client? Bound it.

### 6. External-service cost & rate limits at scale

- [ ] Per-user LLM/image/email/payment call volume × horizon user counts. Where
      are the per-user/day caps? Can limits be bypassed with multiple accounts?
- [ ] Are provider rate limits reachable during a peak at 10x–100x? Are calls
      batched, queued, or backed off?

## Known Hotspot Map (LIVING — keep this current)

> A code-grounded map of the backend's real **scalability** hotspots (with growth class and the horizon at which each breaks) in THIS repo, with `file:line` anchors. A
> generic checklist rots; a map that points at _this codebase's actual_ hot paths compounds every run —
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

Legend — growth class: `per-user` · `per-content` · `per-message` ·
`quadratic` · `bounded`. Record the horizon where each entry bites (10x /
100x / 1,000x) and the suggested fix. Severity is the level at that horizon.

## Severity guide (judged at the horizon where the pattern breaks)

- **CRITICAL** — Will fail or become unavailable within the 10x horizon: full
  table scan on a fast-growing table, unbounded collect-all on per-message or
  quadratic data, an O(n) graph traversal per request, a global write hot spot
  every active user contends on.
- **HIGH** — Breaks by ~100x: N+1 on a per-content/per-participant list,
  read-modify-write that materializes a growing set, a cron that fans out per
  user/entity with no batching, missing per-user caps on a paid external call.
- **MEDIUM** — Degrades toward the upper horizons: missing pagination on a list
  that grows, counting by collecting all rows, over-fetching whole records,
  unbounded live-subscription surface on a busy table.
- **LOW** — Real but not yet load-bearing: micro-batching opportunities,
  defensive caps that are generous today, instrumentation to add so the next
  review has runtime data.

## Output discipline

- Tie **every** finding to a concrete `file:line` and the **horizon** at which it
  breaks (10x / 100x / 1,000x). "Could be slow" is not a finding; "scans
  `<table>` per request, breaks ~100x, fix: add an index on `<field>`" is.
- Prefer a small number of true, high-blast-radius findings over a long list of
  speculative ones.
- **Persist every hotspot to the Known Hotspot Map — by the route your stage
  allows.** The read-only review stage records the map edits in its findings
  issue (in a `Hotspot map updates` section); the fix stage and manual PRs apply
  them to this file in the same PR. A review that finds a hotspot but does not
  record it for the map has done half the job.
