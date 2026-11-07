# Correctness & Logic Review

## Objective

Deep-dive audit of the codebase for **logical correctness errors** — places where
the code does not do what it appears to intend. This is NOT a style review, NOT a
performance review, NOT a security review. Focus exclusively on logic bugs,
off-by-one errors, incorrect conditions, wrong variable references, broken
control flow, and similar correctness issues.

## IMPORTANT: Conservative Approach

This review must be **extremely conservative**. Only flag issues where the code
is **clearly wrong** — not where it's merely unusual, suboptimal, or could
theoretically fail in an edge case you're speculating about.

Classify every finding into one of two categories:

### FIX-REQUIRED
The code is **definitely wrong**. There is a clear, demonstrable logic error.
You can explain exactly what input or scenario produces incorrect behavior and
what the correct behavior should be. These are the ONLY findings that should
drive the fix priority (MEDIUM or HIGH).

### WARN-ONLY
The code **looks suspicious** but you are not 100% certain it's wrong. Maybe
the intent is ambiguous, maybe there's context you can't see, maybe the edge
case is unlikely. Document these for human review but do NOT count them toward
fix priority.

**When in doubt, classify as WARN-ONLY.** False positives that trigger automated
code changes are worse than missed bugs.

## Review Checklist

### Conditional Logic

- [ ] Boolean conditions match their intent (no inverted checks, no `&&` where
      `||` was meant, no missing `!` operators)
- [ ] Null/undefined checks are in the correct order and cover the right cases
- [ ] Ternary expressions return the correct value for each branch
- [ ] `if/else` chains and `switch` statements handle all cases correctly
- [ ] Short-circuit evaluation doesn't skip necessary side effects
- [ ] Equality comparisons use the correct operator and compare the right values

### Variable & Reference Errors

- [ ] Variables reference the correct data (no copy-paste errors where `a` should
      be `b`)
- [ ] Loop variables are not shadowed or reused incorrectly
- [ ] Destructured properties match the actual object shape
- [ ] Function arguments are passed in the correct order
- [ ] Return values are used correctly (not silently discarded when they matter)
- [ ] Assignments target the correct variable (no accidental overwrites)

### Array & Collection Operations

- [ ] Array indices are correct (no off-by-one errors)
- [ ] `.map()`, `.filter()`, `.reduce()` callbacks return the correct values
- [ ] `.find()` results are checked for `undefined` before use
- [ ] Array mutations vs. immutable operations are used correctly
- [ ] Spread operators don't silently drop or duplicate data
- [ ] Sort comparators return correct values for all cases

### Async & Timing

- [ ] `await` is not missing on promises that need to be resolved
- [ ] Async operations that should be sequential are not accidentally parallel
- [ ] Race conditions between concurrent operations
- [ ] Error handling in async chains doesn't swallow failures that matter
- [ ] Promises are not fire-and-forget when their result or error matters

### Data Flow & Transformation

- [ ] Data transformations preserve all required fields
- [ ] Type coercions produce correct results (string-to-number, date parsing, etc.)
- [ ] Default values are correct and applied at the right time
- [ ] Merge/spread operations don't silently override important values
- [ ] Calculations use correct formulas and units

### Data-Layer Logic

- [ ] Query filters match the intended records (correct field, correct operator)
- [ ] Index usage matches the actual index definitions in the schema
- [ ] Writes update the correct fields and don't clobber unrelated data
- [ ] Pagination logic handles edge cases (empty results, last page)
- [ ] Validator/schema definitions match the data actually being passed

### UI Framework Logic

- [ ] Reactive/derived values have correct dependencies and update when expected
- [ ] Store/state subscriptions read the correct store
- [ ] Component props are passed with correct names and types
- [ ] Event handlers reference the correct handler function
- [ ] Conditional rendering uses the correct condition
- [ ] List rendering uses stable keys to avoid rendering bugs

### Control Flow

- [ ] Early returns don't skip necessary cleanup or state updates
- [ ] Loop `break`/`continue` statements are in the correct loop
- [ ] Exception handling catches the right exceptions and re-throws correctly
- [ ] Recursive functions have correct base cases and termination conditions
- [ ] Fallthrough in switch statements is intentional

## Severity Guide

**Only FIX-REQUIRED items contribute to severity. WARN-ONLY items are always
informational regardless of potential impact.**

- **CRITICAL** (FIX-REQUIRED): Logic error that **definitely causes data
  corruption, data loss, or completely broken functionality** in normal usage
- **HIGH** (FIX-REQUIRED): Logic error that **definitely produces wrong results**
  but the impact is contained (wrong display, incorrect calculation, broken
  feature edge case)
- **MEDIUM** (FIX-REQUIRED): Logic error that **definitely exists** but only
  triggers in uncommon scenarios
- **LOW** (WARN-ONLY): Suspicious code that **might** be wrong — document for
  human review
- **XLOW** (WARN-ONLY): Mildly suspicious patterns — not worth automated action

## Output Format

Structure your findings as:

```
## FIX-REQUIRED Findings

### [CRITICAL/HIGH/MEDIUM] Finding title
- **File**: path/to/file.ts:123
- **What's wrong**: [Exact description of the bug]
- **Evidence**: [The specific code and why it's wrong]
- **Correct behavior**: [What the code should do instead]
- **Suggested fix**: [Concrete fix]

## WARN-ONLY Findings (for human review)

### [Suspicious] Finding title
- **File**: path/to/file.ts:456
- **Concern**: [What looks off]
- **Why uncertain**: [Why you can't confirm it's a bug]
- **Recommendation**: [What a human reviewer should check]
```

## Instructions for the Fix Stage

When the fix stage runs for correctness findings:
- **ONLY fix FIX-REQUIRED items.** Do not touch WARN-ONLY items.
- In the PR description, include a **"Warnings for Human Review"** section that
  lists all WARN-ONLY items so a reviewer can investigate them manually.
- For each fix, add a brief code comment only if the fix is non-obvious.
- Write a regression test for each FIX-REQUIRED finding when feasible.
