# Billing Integrity Review (Unit Economics & Revenue Truthfulness)

## Objective

Audit whether the platform's money math **tells the truth** and whether the
business, **by the code's own logic, actually makes money**. This is a
unit-economics and P&L-truthfulness review: revenue recognition, true cost of
goods sold (COGS), gross margin, the markup invariant, free-service subsidy,
outstanding prepaid liability, and reconciliation against the payment
processor.

The failure mode this review exists to catch is subtle and expensive: **every
individual transaction can be correct while the aggregate numbers lie.** For
example, a cost line that sums marked-up usage charges instead of what the
provider actually charged overstates cost by exactly the markup. Your job is to
find this class of bug: the money flows correctly but the **meaning** of the
numbers is wrong.

Skip this area if the product has no payments; trim the sections that don't
apply (e.g. no prepaid credits, no usage-based pricing, no payouts).

### How this differs from the `e-commerce` review (do NOT duplicate it)

- **`e-commerce.md`** audits _transactional correctness_ of the money
  machinery: webhook signatures, idempotency, balance floors, checkout params,
  subscription state transitions. "Does each transaction do the right thing?"
- **This review** audits _aggregate truthfulness and unit economics_: "Do our
  rolled-up revenue/cost/margin numbers mean what they claim, is the markup
  invariant preserved on every path, are we silently giving away service, and
  does booked revenue reconcile to the payment processor?"

When you find a pure transactional-correctness bug (e.g. a missing webhook
idempotency guard), note it briefly and defer to `e-commerce`. Spend your depth
on the economics.

## Step 0: Write down the invariants

Before checking anything, find and state (in your findings) the project's money
invariants, citing where each is defined in code. Typical ones:

1. **The unit conversion.** E.g. "1 unit = $X". Every currency↔unit
   conversion must use ONE named constant — never a hardcoded literal or a
   drifted rate.
2. **The markup.** E.g. "users are charged N× provider cost". Derive the implied
   steady-state gross margin on _paid_ usage (1 − 1/N).
3. **Where true COGS lives.** The real provider cost must be stored separately
   from the marked-up amount charged to the user. Any "cost", "P&L", or
   "margin" computed from the charged amount is wrong by exactly the markup.
4. **Revenue is cash in; prepaid balance is a liability.** A subscription
   payment or credit purchase is cash received now, but the granted
   credits/quota are service still owed. Revenue recognized ≠ revenue earned
   until it is consumed.
5. **Free credits have no revenue behind them.** A promotional/bonus grant that
   is consumed still costs real provider money with $0 cash to cover it. The
   markup does not protect you there — there was no sale.

If the code has no single source of truth for one of these, that is itself a
finding.

## Review Checklist

### A. P&L & Metrics Truthfulness (the highest-value section)

- [ ] Every surface that displays "cost", "COGS", "margin", "profit", or "P&L"
      derives the cost line from **real provider cost**, NOT from the sum of
      marked-up usage charges.
- [ ] "Credits/units consumed" and "provider cost" are never conflated or
      interchangeably labeled. A chart of units consumed must say so — not call
      it "cost".
- [ ] Net P&L and margin are computed from (real revenue − real COGS), not from
      (cash in − units consumed), which compares two different things.
- [ ] Revenue **nets out refunds, chargebacks, and negative adjustments** — and
      ONLY cash-backed ones. When one transaction type is reused for both
      cash-backed reversals and non-cash grants or corrections, the revenue
      classifier must tell the cash-backed rows apart (e.g. by the presence of
      a processor refund/dispute id), or non-cash rows distort revenue.
- [ ] Gross-vs-net is honest: gross processor volume is not presented as
      take-home without acknowledging processing fees.
- [ ] Time-window comparisons are cohort-honest: this period's upfront
      subscription cash is not compared against this period's consumption cost
      as if they were the same cohort, without a caveat or deferral model.

### B. Revenue Completeness

- [ ] **Every cash-in path reaches the revenue line.** One-time purchases that
      don't emit the same events as subscriptions (e.g. a one-time checkout that
      produces no invoice) are easy to leave out of every revenue surface.
      Enumerate every way money comes in and confirm each is counted once.
- [ ] Revenue is computed from **durable** records, not from a raw webhook/event
      log that a retention sweep deletes, and not by re-parsing payloads whose
      shape may differ from what the parser expects.
- [ ] Writes to the revenue-of-record table never swallow failures: a failed
      write alerts AND schedules an idempotent retry, or revenue is permanently
      under-counted.
- [ ] No double counting during a migration: legacy rows and their replacement
      rows for the same processor event cannot both be summed.
- [ ] Lost disputes/chargebacks reverse booked revenue — a lost dispute sends no
      refund event, so a refund-only reversal path misses it.

### C. Markup Invariant (margin protection)

- [ ] **Every** code path that charges for usage routes the amount through the
      single markup function. Enumerate them all — every metered feature,
      including background and scheduled jobs. A path that charges raw provider cost (1×)
      silently zeroes the margin on that surface.
- [ ] No path charges a _fixed_ amount decoupled from provider cost in a way that
      can fall below 1× real cost for expensive models/options.
- [ ] The cost-resolution fallback never charges **$0** when the real cost is
      merely _unavailable_. It must still charge a conservative estimate, or the
      platform eats the whole provider bill.
- [ ] Fallback/estimate rates are biased to slightly **over**charge (round in
      the platform's favor for billing), never to undercharge.
- [ ] Hardcoded provider pricing has a staleness guard that actually fires, and
      its "last verified" date is current. Stale low prices = silent
      undercharge as providers raise rates.
- [ ] Conversions don't introduce off-by-100 or rounding drift that compounds
      across thousands of calls.

### D. Free-Service Subsidy & Leakage (the real money leaks)

- [ ] The provider cost incurred against **free/bonus credits** (promotional grants,
      free tier) is measurable and bounded. If
      there is no way to see this number, that is a finding — it is the single
      most likely silent leak.
- [ ] The balance floor/overdraft limit is enforced on **every** debit path, not
      just the main one. An unbounded-overdraft path is unrecoverable cost.
- [ ] Any cap on carried-over balances actually bounds the outstanding
      unconsumed-balance liability.
- [ ] Free-tier throttling actually caps the subsidized spend it's meant to cap,
      and any revenue projection uses real revenue-per-unit, not the marked-up
      figure.

### E. Deferred Revenue & Liability Awareness

- [ ] There is a way to see the **total outstanding prepaid liability** (sum of
      all user balances), ideally split into paid (cash-backed) vs free
      (subsidy). This is unbilled future COGS; if nothing surfaces it, flag it.
- [ ] Subscription credit grants are recorded as a non-revenue type and are NOT
      double-counted into revenue alongside the invoice payment.
- [ ] Mid-cycle upgrade/downgrade grants don't grant more value than the cash
      collected for that period.

### F. Internal / System Usage

- [ ] Usage the platform runs for itself (background jobs, internal tools) is
      accounted **separately** from customer
      usage and is not folded into customer-facing cost/P&L — it is pure COGS
      with no matching revenue.
- [ ] Internal usage is costed at real provider cost, not at the
      customer-facing price.

### G. Processor ↔ Ledger Reconciliation

- [ ] Booked revenue for a window is reconcilable to the payment processor's
      gross volume for the same window. Large unexplained drift either way is a
      finding (dropped events → undercount; double-processed → overcount).
- [ ] The fast-path balance on the user record reconciles to the sum of that
      user's ledger rows (the audit source of truth), or a reconciliation job
      exists and runs.
- [ ] Only successfully processed events are counted, and the reprocessing path
      can't double-count an event already counted.

## ACTIVE TASK: Reproduce the unit economics from the code

Do not just check boxes — **trace the formulas and reproduce the P&L the code
would produce**, then sanity-check it against the invariants:

1. Find every formula that feeds a revenue, cost, margin, or P&L number.
2. For each, write out what it actually sums (which transaction types, marked-up
   amount vs real provider cost, gross vs net).
3. State, in your findings, the **real** gross margin the code's own logic
   implies for paid usage and whether each displayed surface matches or
   contradicts it.
4. Call out every place where a displayed cost/margin/profit number would
   mislead someone reading the dashboard — that is the headline finding class.

## Known Hotspot Map (LIVING — keep this current)

> A code-grounded map of the **revenue-truthfulness path** in THIS repo, with `file:line` anchors. A
> generic checklist rots; a map that points at the real aggregation, classification, and markup code compounds every run —
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

Seed it with: the revenue/cost aggregation functions, the revenue classifier
(which transaction types count, and how cash-backed rows are told apart), every
writer of an overloaded transaction type, the markup function and every usage
path that must call it, and the revenue-of-record writers.

## Severity Guide

- **HIGH**: A money number that actively misleads a decision-maker (cost or
  margin computed from marked-up units instead of real COGS; revenue that
  materially overstates the business); a usage path that charges 1× or $0 and
  loses margin on every call; an unbounded overdraft or free-credit leak; a
  cash-in path missing from revenue; booked revenue that can't be reconciled to
  the processor.
- **MEDIUM**: Markup invariant intact but a surface conflates units consumed
  with cost in labeling; no visibility into outstanding liability or
  free-credit subsidy; internal usage folded into customer P&L; stale provider
  pricing with a guard that isn't firing.
- **LOW**: Gross-vs-net not annotated; cohort/timing caveat missing on a P&L
  chart; minor rounding drift; reconciliation exists but is manual.
- **XLOW**: Cosmetic labeling nits, comment drift, doc-only clarifications.
