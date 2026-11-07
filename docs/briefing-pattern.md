# The briefing pattern: deterministic facts, LLM narrative

A scheduled job posts a daily (and weekly) briefing to a team chat channel that
answers "what happened yesterday / last week?". The pattern that makes it
trustworthy: **code computes every number; the LLM only writes the prose around
them, and the numbers are always rendered by code.** If the LLM is down,
misconfigured, or returns garbage, the briefing still posts, with the facts.

This is a design write-up, not a drop-in component. It is stack-agnostic: the job
can be a cron'd serverless function, a scheduled backend action, or a CI workflow.

## Why this shape

Asking an LLM "summarise yesterday's metrics" fails in predictable ways: it
rounds, transposes, or invents numbers; it calls a number "a spike" with nothing to
compare it to; it reads a zero as an outage; and its output can't be tested. Split
the job so each part does what it is good at:

| Part | Who does it | Testable? |
|---|---|---|
| Reporting window | Code | Yes, pure function of `now` |
| Facts (counts, totals, top-N lists) | Code, from your own data and analytics | Yes, pure aggregation over rows |
| Narrative (headline bullets, summary, good / bad / surprising) | LLM, from the facts JSON | Prompt rules are asserted in tests |
| Detail sections with the numbers | Code, rendered from the facts | Yes, snapshot the message |
| Delivery | Code, to a chat webhook | Yes, stub the webhook at the HTTP boundary |

## The pipeline

1. **Window.** A pure function maps `(period, now)` to `[start, end)` and a human
   label: daily is the previous full UTC day; weekly is the previous full
   Monday-to-Monday UTC week (so a run on Monday reports the week that just
   ended). Accept `now` as an optional argument so tests and manual re-runs can
   pin it.
2. **Gather rows.** Page through the source-of-truth tables for the window (for
   example payments and usage ledgers). Page explicitly rather than loading
   everything; a briefing must not hit a query-size limit on a busy week.
3. **Aggregate facts.** Pure functions turn rows into a facts object. Two rules
   matter here:
   - **One implementation of every metric.** If an admin dashboard already
     computes "revenue", the briefing calls the same function. Pin it with a test
     that asserts the briefing's total equals the dashboard's for the same rows;
     two copies of the arithmetic will drift.
   - **Encode the accounting rules once** — which event types count as cash, how
     refunds net out, how to avoid double-counting a refund that appears under two
     event types, whether zero-amount rows count.
4. **Optional secondary facts.** Product-analytics queries (errors users hit,
   rage clicks, top pages, top events, active users) through a **read-only** query
   key. If this source is unconfigured or fails, report the gap and continue with
   the primary facts; mark the section "unavailable" in the message rather than
   showing zeros.
5. **Narrative.** Send the facts as JSON to an LLM with a strict JSON output schema
   (for example `tldr: string[]`, `summary: string`, `good: string[]`,
   `bad: string[]`, `surprising: string[]`). Parse defensively: keep only strings,
   default a missing field to empty.
6. **Render.** Build the message deterministically: headline bullets, then the
   summary, then the good / bad / surprising highlights, then **detail sections
   rendered by code straight from the facts**. Empty lists render as "none".
7. **Post** to a per-period chat webhook (one for daily, one for weekly). Treat a
   non-2xx response as a failure and throw.

## The narrative prompt: rules that keep it honest

These are the rules worth stating in the system prompt, and worth asserting in
tests (a test that the prompt contains each rule is cheap and stops a later edit
from quietly dropping one):

- **Ground every claim in the facts. Never invent or extrapolate a number.**
- **No trends without a baseline.** The facts describe one window with no earlier
  period, so the model can't know whether anything rose or fell. Ban comparative
  and trend words (up, down, spike, surge, record, decline) and "high"/"low"
  judgements. Report the level; let the reader judge. (If you later add the prior
  period to the facts, relax this rule deliberately.)
- **An absence is not a defect.** A zero means nothing of that kind was recorded —
  usually a quiet period. Never infer a bug, outage, or broken tracking from it.
- **Different sources disagree by design.** Your ledger and client-side telemetry
  measure different things. Where two numbers look inconsistent, say what each
  shows and stop; don't declare either wrong.
- **No urgency vocabulary** (critical, urgent, alarming, red flag). The team reads
  this every period; anything genuinely urgent is legible from the numbers.
- **One observation, one section.** Don't restate a bad item as a surprising one
  for emphasis.
- **But don't be bland.** Errors users hit and failed operations are real; put them
  in "bad", plainly, with their numbers. Understating a real problem fails the
  reader as badly as inflating one. Empty arrays are a normal outcome, not a gap to
  fill.

The headline bullets may quote a key number (bolded) so the post is scannable,
but the authoritative figures are always the code-rendered detail sections below
them. For a stricter variant, have the narrative refer to facts by key and
substitute the values in code, or check that every number in the narrative appears
in the facts and fall back if one doesn't.

## Failure handling

Follow the fail-loud-but-keep-posting rule (see "What Warrants an Alert" in
`AGENTS.md`):

| Condition | Behavior |
|---|---|
| Chat webhook not configured, production | Report to error tracking (misconfiguration), skip the run |
| Chat webhook not configured, dev / preview | Skip quietly; briefings simply aren't set up there |
| Analytics source unconfigured or failing | Report the gap, post primary facts only, mark the section unavailable |
| LLM key missing, call failed, or output unparseable | Report the gap, post the facts with a fallback headline ("AI summary unavailable — raw numbers below") |
| Webhook returns non-2xx | Throw, after a bounded retry; the scheduler's failure reporting alerts |

Book the LLM call's cost — including failed or garbled attempts — to an internal
budget line, so the briefing's own spend is visible.

## Sketch

```text
runBriefing(period, now = clock()):
  webhook = config.webhookFor(period)
  if not webhook:
    if isProduction(): reportError("briefing webhook not configured", period)
    return skipped
  window    = briefingWindow(period, now)
  facts     = { billing: aggregateBilling(pageRows(window)),
                usage:   aggregateUsage(pageRows(window)),
                analytics: tryGatherAnalytics(window) or null }
  narrative = tryComposeNarrative(period, window, facts) or fallbackNarrative(reason)
  post(webhook, renderMessage(period, window, facts, narrative))
```

## Tests worth having

- Window: daily covers the previous UTC day; weekly covers the previous
  Monday-to-Monday week, including a run on a Monday.
- Aggregation: each accounting rule (cash event types, refund netting, zero rows,
  every revenue source counted) and equality with the dashboard's total.
- Prompt: each honesty rule above is present.
- Rendering: section order; one bullet per headline point; "none" for empty
  lists; "unavailable" when a source failed; the fallback headline when the
  narrative failed.
- End to end with the LLM and webhook stubbed at the HTTP boundary: posts to the
  right webhook per period; still posts when the LLM keeps returning unparseable
  output; still posts primary facts when analytics is unconfigured; skips quietly
  when no webhook is configured outside production.
