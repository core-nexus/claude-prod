# E-Commerce & Payments Review

## Objective

Deep-dive audit of all billing, payments, subscriptions, credits, and payment
processor integration logic. This review covers the **money side** of the
platform — both revenue (subscriptions, purchases, contributions) and spend
(API costs, metered usage).

Errors here cost real money or silently give away free service. Treat every
finding with the gravity that financial code demands.

This review audits **transactional correctness** — "does each transaction do
the right thing?" Whether the rolled-up revenue/cost/margin numbers tell the
truth is the `billing-integrity` review's job; note such findings briefly and
defer to it.

## Review Checklist

### Webhook Integrity

- [ ] Every webhook handler verifies the payment processor's signature before processing
- [ ] Idempotency: duplicate webhook events (same event ID) are detected and
      skipped without side effects
- [ ] All expected event types are handled; unexpected types are logged, not
      silently dropped
- [ ] Webhook handlers access the correct fields from the event payload
- [ ] Out-of-order delivery is handled: the event's creation time is threaded
      through so an older event cannot overwrite newer state
- [ ] **Nothing is acked before it is recoverable.** If the edge returns 200
      before the durable event-log row exists, any failure in between (e.g. a
      failure during setup) loses the event
      for good — the provider won't retry and the recovery sweep has no row to
      re-drive. Validate everything needed to persist the row BEFORE acking,
      and fail the delivery (5xx) otherwise so the provider retries.
- [ ] **Pre-claim work stays cheap and pure.** Provenance checks that make
      network/database calls belong AFTER the event-log claim, inside the
      retryable path — a transient fault before the claim drops the event; after
      it, the row lands `failed` and is retried.
- [ ] Checkout/payment completion correctly provisions what was purchased
- [ ] Subscription lifecycle events correctly update local subscription records
- [ ] Invoice/payment events correctly grant entitlements with idempotency
- [ ] No race conditions between concurrent webhook deliveries for the same user

### Subscription Logic

- [ ] Subscription state transitions are correct:
  - New subscription → active
  - Upgrade/downgrade mid-cycle → correct tier, correct entitlement adjustment
  - Cancel at period end → still active until period end, then expires
  - Renewal → new period, entitlements granted
  - Payment failure → correct state (past_due, not prematurely canceled)
- [ ] Trial expiration detection works correctly
- [ ] Entitlement grants are idempotent (cannot double-grant for the same period)
- [ ] Mid-cycle upgrade grants calculate the correct difference
- [ ] Feature gating checks the correct subscription tier and status
- [ ] Free tier users get correct defaults and limits

### Plan Copy & Entitlement Truthfulness

What you _say_ a plan contains must match what it _actually grants_. Marketing
copy (plan taglines, "unlimited" labels) that contradicts the data-driven
credit/feature list on the same plan card is a trust and compliance issue.

- [ ] No tier advertises "unlimited", "no boundaries", or otherwise implies an
      uncapped allotment while its actual allowance is finite (credit-capped,
      seat-limited, quota-bound). This applies to the plan description AND to any
      hardcoded marketing labels on the surfaces that render it.
- [ ] Per-tier numbers (price, credits/quota, feature flags) come from a single
      source of truth; any value duplicated outside it still matches. Prefer
      deriving from the source of truth over maintaining a second copy.
- [ ] A test pins plan copy against the entitlement data (e.g. asserting no
      credit-capped tier's description contains "unlimited"), so a plan change
      cannot silently reintroduce the mismatch.

### Credit / Token System (if applicable)

- [ ] Credit/token balance can never go below the configured minimum
- [ ] Balance caps or rollover limits are correctly enforced
- [ ] Deductions are atomic — no scenario where credits are consumed but
      the operation fails, or vice versa
- [ ] Every deduction creates a matching transaction record for audit
- [ ] Balance queries return consistent results (not stale or partially updated)
- [ ] Auto top-up (if implemented) triggers correctly and doesn't loop, and
      can't fire twice for one threshold crossing
- [ ] **Charged-without-delivery is self-healing.** If a payment succeeds but
      the follow-up grant/bookkeeping throws, an idempotent retry keyed on the
      payment id is scheduled (and the failure still alerts) — the customer is
      never left charged with nothing until a human notices
- [ ] **Compensating refunds use the amount actually taken.** When a deduction
      is clamped at a balance floor (partial or zero), a later "operation failed,
      refund the user" path must refund what really left the balance, not the
      requested amount — otherwise it mints free credit
- [ ] Usage debits have a **server-derived** deterministic idempotency key when
      the client key or provider request id is optional/absent (hash stable
      operation inputs that identify the unit of work). An
      optional client key alone leaves zero dedup on a double-submit.
- [ ] Every admin/support entry point that mints credits carries a scoped
      idempotency key and a maximum-amount ceiling

### Cost Calculation

- [ ] Pricing lookups resolve the correct price for the item/service
- [ ] Currency conversions are correct (no off-by-100 or rounding errors)
- [ ] Fallback pricing doesn't silently undercharge or overcharge
- [ ] Insufficient-funds/credits checks happen BEFORE the operation, not after

### Checkout & Payment Flows

- [ ] Checkout session creation includes all required parameters
- [ ] Every money-moving write (create, charge, refund, subscription
      create/update) carries an **idempotency key**, and that key is
      **deterministic** — a pure function of stable ids (subscription id,
      pending-purchase id, payment-intent id, user id, billing period), never
      seeded with `Date.now()`, `Math.random()`, `randomUUID()`, or an attempt
      counter. A non-deterministic key can double-charge on retry.
- [ ] Price IDs match the correct product and interval
- [ ] Success/cancel URLs are correct and don't leak session data
- [ ] Rate limiting on checkout creation is correctly enforced
- [ ] **Concurrent checkouts can't double-charge.** A per-(user, item) pending
      purchase slot is reserved BEFORE the checkout session is created, the
      session's idempotency key derives from that slot, and a superseded slot is
      refused. Cleanup for one flow must not release another flow's guard.
- [ ] Price/product lookups fail loud when ambiguous (two active prices for one
      product) instead of silently picking the first
- [ ] Provider-side product/price creation uses deterministic idempotency keys
- [ ] Payment method updates propagate to the correct customer record
- [ ] Card decline and payment errors surface to the user (not swallowed)

### Refunds, Disputes & Payouts

- [ ] A single refund webhook snapshot can carry **several** refunds — iterate
      every succeeded refund, each keyed on its own refund id (replay-safe), not
      just the latest one
- [ ] Lost disputes/chargebacks reverse what the original payment granted (and
      what was booked), not only refunds — a lost dispute sends no refund event
- [ ] Reversals of funds already **paid out** to third parties are handled
      explicitly (a liability or a recovery), not silently
- [ ] Payouts to third parties are held long enough to outlast the card-dispute
      window, at least above a value threshold; a late chargeback against money
      already paid out is usually unrecoverable
- [ ] Settlement/payout queues drain: a row that can never settle (e.g. its
      recipient was deleted) is voided, not skipped forever while blocking the
      rows behind it

### Data Consistency

- [ ] Customer ID is set on the user record before any API call that requires it
- [ ] Subscription records in the database match the payment processor's state
- [ ] Credit/balance on the user record matches the sum of all transactions
      (or has a reconciliation mechanism)
- [ ] Rate limit records are cleaned up and don't accumulate unboundedly

### Currency & Math

- [ ] All monetary values use integers (cents/smallest unit), never floating-point
- [ ] No floating-point arithmetic on monetary amounts
- [ ] Rounding is explicit and consistent (platform's favor for billing,
      user's favor for credits granted)
- [ ] Currency is consistently handled (no mixed-currency assumptions)

## Known Hotspot Map (LIVING — keep this current)

> A code-grounded map of the **money-critical path** in THIS repo, with `file:line` anchors. A
> generic checklist rots; a map that points at the real webhook, ledger, and idempotency code compounds every run —
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

Seed it with: webhook ingress and dispatch, the event-log claim / idempotency
guard, the credit or entitlement ledger (and its balance floor), recurring
grant idempotency, refund and dispute handlers, auto top-up, and every
checkout-creation path.

## Severity Guide

- **CRITICAL**: User charged wrong amount, entitlements granted incorrectly,
  double billing, webhook bypass allowing free service
- **HIGH**: Subscription state machine bug, missing idempotency allowing double
  grants, auto top-up loop, checkout race condition
- **MEDIUM**: Stale subscription data displayed, rate limit bypassable,
  cost calculation off for rare cases
- **LOW**: Minor audit trail gaps, cosmetic billing display issues
