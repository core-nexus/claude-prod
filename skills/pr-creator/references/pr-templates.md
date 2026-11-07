# Pull Request Templates

Example descriptions for common kinds of change. Adapt them to the repo's own PR template when one exists. In the real PR body, keep each paragraph and each list item on ONE line — GitHub renders a hard wrap as a line break — and describe the end state, not how the work evolved.

## New Feature

```markdown
## Summary

Adds [feature] so that [user or developer] can [capability].

## What Changed

- `path/to/new/module`: [what it does]
- `path/to/schema-or-model`: new [table/field] for [purpose]
- Chose [approach A] over [approach B] because [reason]

## Test Plan

- [x] Unit tests for the new behavior
- [x] Manual check of the happy path
- [x] Edge cases: [list]
- [ ] Accessibility check (UI changes)

## Breaking Changes

None.
```

## Bug Fix

```markdown
## Summary

Fixes [symptom], caused by [root cause]. Fixes #[issue].

## What Changed

- `path/to/file:123`: [what changed and why it fixes the cause]
- `path/to/test`: regression test that fails without the fix

## Test Plan

- [x] Regression test fails before the fix, passes after
- [x] Related behavior still works: [list]

## Regression Risk

[Low/Medium/High] — [why]
```

## Refactor

```markdown
## Summary

Restructures [module] for [maintainability/performance/testability]. No behavior change.

## What Changed

- Before: [old shape]. After: [new shape].
- `old/path` moved to `new/path`; extracted [helper]

## Test Plan

- [x] Existing tests pass unchanged
- [x] [Benchmark or metric] shows no regression
```

## Documentation

```markdown
## Summary

Documents [topic] for [audience], closing the gap where [confusion].

## What Changed

- `README.md`: [section] now covers [information]
- `docs/[guide].md`: new guide for [topic]

## Review Checklist

- [x] Examples run as written
- [x] Links checked
```

## Dependency Update

```markdown
## Summary

Updates [package] from [old] to [new] to [fix a vulnerability / pick up a feature / fix a bug].

## What Changed

- [manifest + lockfile]: [package] → v[new]
- `path/to/file`: adapted to the new API ([breaking change addressed])

## Test Plan

- [x] Full test suite passes on the new version
- [x] No new deprecation warnings
- [x] [Specific feature] verified

## Rollback Plan

Revert this PR; no data or schema changes.
```

## Performance Improvement

```markdown
## Summary

Speeds up [operation] by [amount], measured with [method].

## What Changed

- `path/to/file`: [technique — caching, batching, an index, lazy loading]

## Measurements

| Metric | Before | After |
|---|---|---|
| [p95 latency] | [x] | [y] |

## Trade-offs

[Complexity, memory, staleness]
```

## Pre-PR Checklist

- [ ] On a feature branch, pushed, up to date with the base
- [ ] Targeted tests pass; new behavior and bug fixes have tests
- [ ] No debug output, no unrelated changes
- [ ] Title follows the repo's convention
- [ ] Description describes the end state, one line per paragraph
- [ ] Breaking changes and anything unverified are called out
