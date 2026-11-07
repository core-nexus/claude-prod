# Code Quality & Style Review

## Objective

Deep audit of code quality, type safety, adherence to project conventions,
and maintainability across the codebase.

## Mechanically Enforced Metrics (Read First)

If the project enforces complexity/size limits in its linter (e.g. ESLint
`complexity`, `sonarjs/cognitive-complexity`, `max-lines-per-function`,
`max-depth`, `max-params`, `max-nested-callbacks`, or equivalents) at the
ecosystem-recommended maxima — with no grandfather list and no per-file
suppression — that changes what this review should focus on:

1. **Don't re-report what the linter already blocks.** Over-threshold code
   can't merge, so flagging "this function is too long/complex" is redundant.
   Spend attention on what the linter can't see: duplicated logic, poor names,
   wrong abstraction layer, business logic in components.
2. **Watch for metric-gaming.** A function refactored to slip just under a
   threshold via dense one-liners, or an `eslint-disable` comment dodging a
   metric rule, is a finding — the goal is readability, not a green number.
   Flag any `eslint-disable` of `complexity`, `cognitive-complexity`,
   `max-lines-per-function`, `max-depth`, or `max-params`.
3. Beyond cyclomatic complexity, reason about **cognitive complexity** (deeply
   nested control flow that is hard for the next reader — human or model — to
   follow) even when a function is under the cyclomatic limit.

## Review Checklist

### Type Safety

- [ ] No `any` types — every variable, parameter, and return value has a proper type
- [ ] Type-only imports use the appropriate syntax (`import type`)
- [ ] No `@ts-ignore` or `@ts-expect-error` without a comment explaining WHY
- [ ] No type assertions (`as`) that hide real type mismatches
- [ ] Generic types used appropriately (not over-engineered, not avoided)
- [ ] Union types preferred over `any` when multiple types are valid
- [ ] Null/undefined handled with optional chaining (`?.`) and nullish coalescing (`??`)

### Style Conventions

Verify the code follows the project's configured style rules (Prettier, ESLint, etc.):

- [ ] Consistent formatting (indentation, quotes, semicolons per project config)
- [ ] Consistent naming conventions (camelCase, PascalCase, snake_case per project norms)
- [ ] Unused variables/arguments handled per project convention (e.g., underscore prefix)
- [ ] Strict equality used everywhere (`===` not `==`)
- [ ] Curly braces used consistently on control flow blocks

### No Debug Logging in Production

- [ ] Search for `console.log` — none should exist in committed code
- [ ] `console.warn` used for non-error warnings only
- [ ] `console.error` used for actual errors (with proper error reporting too)
- [ ] No leftover debug statements, `debugger`, or test scaffolding

### Component Architecture

- [ ] Components are focused and single-purpose
- [ ] No complex business logic inline in view/template files
  - Business logic belongs in services, utilities, or server-side functions
  - Components should call functions, not implement pipelines
- [ ] Props/inputs are typed for non-trivial components
- [ ] Event handlers are properly typed

### Code Organization

- [ ] File naming follows project conventions
- [ ] Import paths use configured aliases (not deep relative paths)
- [ ] No circular dependencies between modules
- [ ] Dead code removed (unused exports, unreachable branches, commented-out code)
- [ ] No duplicate implementations of the same logic
  - If two code paths do the same calculation, they share one implementation

### Function Quality

If length, param-count, complexity, and nesting are linter-enforced (see above),
focus here on what the linter can't judge:

- [ ] Functions do one thing well (Single Responsibility) — a function _under_
      the limits can still be doing three unrelated things
- [ ] Function names clearly describe what they do
- [ ] Extracted helpers (created to satisfy the metric rules) are themselves
      well-named and cohesive, not arbitrary "part 2" splits
- [ ] If metrics are NOT enforced: no overly long functions (>50 lines should be
      scrutinized) and parameters are reasonable in number (>4 suggests an
      options object)
- [ ] Return types are clear and consistent
- [ ] Side effects are documented or obvious from the function name

### Constants & Magic Values

- [ ] No magic numbers or strings — use named constants
- [ ] Constants are defined in appropriate locations (not scattered)
- [ ] Enums or union types used for fixed sets of values
- [ ] Configuration values are centralized, not duplicated

### Code Smells

- [ ] No God objects or classes that do too much
- [ ] No deep nesting — prefer early returns / guard clauses well before any
      enforced depth limit (>3 levels of indentation suggests refactoring)
- [ ] No boolean parameters that change function behavior (use separate functions)
- [ ] No premature abstractions (three similar lines > a premature helper)
- [ ] No feature flags or backwards-compatibility shims for removed features

## Severity Guide

- **CRITICAL**: `any` types hiding real bugs, duplicate logic causing inconsistencies
- **HIGH**: Business logic in view layer, missing type safety, dead code
- **MEDIUM**: Style violations not caught by linter, naming inconsistencies
- **LOW**: Minor readability improvements, optional refactoring opportunities
