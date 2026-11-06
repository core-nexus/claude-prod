# Testing Coverage & Quality Review

## Objective

Audit test coverage, test quality, and adherence to testing best practices.
Focus on real code execution over mocking.

## Review Checklist

### Coverage Gaps

- [ ] **Backend functions without tests**: Every API endpoint, mutation, query,
      and server action should have corresponding tests
  - List all untested functions
  - Prioritize testing for functions that handle: auth, payments, data mutation
- [ ] **New features without tests**: Check recent commits/PRs for features
      that were merged without test coverage
- [ ] **Bug fixes without regression tests**: Every bug fix should have a test
      that would catch the bug if it recurred
- [ ] **Edge cases**: Happy path tested but error/edge cases missing:
  - Unauthenticated users
  - Empty/null inputs
  - Rate-limited scenarios
  - Concurrent operations
  - Boundary values

### Mock Discipline

**Prefer exercising real code over mocking. Only mock at external boundaries.**

- [ ] **No internal mocks**: Tests should not mock your own modules or functions.
      If internal code is mocked, the test verifies assumptions, not behavior.
- [ ] **Only external boundary mocks**: The ONLY acceptable mocks are:
  - Third-party API clients (Stripe, payment processors, email services)
  - `fetch` calls to external HTTP APIs
  - External CDN/storage URL constants
- [ ] **No `vi.fn()` / `jest.fn()` replacing internal functions**: If a test
      replaces a real function from your codebase with a mock, that's a red flag
- [ ] **Real database/backend testing**: Tests should exercise real data operations,
      not mocked data layers (an in-memory or test instance of the real backend)
- [ ] **Real auth testing**: Authenticated scenarios run through the real auth
      path with a test identity, not a mocked auth module

### Test Quality

- [ ] **Tests exercise real code paths**: Not just checking mocked return values
- [ ] **Assertions are meaningful**: Not just `expect(result).toBeDefined()`
  - Assert specific values, structures, and side effects
  - Check database/store state after mutations
  - Verify error types and messages
- [ ] **Test descriptions are clear**: `it('should ...')` describes the behavior
- [ ] **No flaky tests**: Tests that sometimes pass and sometimes fail
  - Timing-dependent tests (waiting on fixed sleeps rather than a condition)
  - Order-dependent tests (rely on another test having run first)
  - Tests that depend on external or shared mutable state
- [ ] **No skipped tests**: `it.skip()` or `describe.skip()` without explanation
- [ ] **Tests don't test implementation details**: Focus on behavior, not internals

### Test Organization

- [ ] Tests mirror source structure
- [ ] Shared test helpers are in appropriate utility files
- [ ] Test data setup is clear and minimal
- [ ] No test pollution: each test is independent and cleans up after itself

### E2E Tests

- [ ] Smoke test coverage for critical user journeys:
  - Sign up / sign in
  - Profile creation and editing
  - Core feature interactions
  - Payment/checkout flows
- [ ] E2E tests fail on JS errors and `console.error`
- [ ] Test count is reasonable (not excessive — think smoke tests)
- [ ] Fixtures and setup follow established patterns

### Payment / Billing Integration (if applicable)

- [ ] Subscription lifecycle is tested (create, renew, upgrade/downgrade, cancel, expire)
- [ ] One-time purchases / top-ups are tested
- [ ] Webhook handling is tested (signature verification, idempotency, each event type)
- [ ] Test artifacts (customers, subscriptions) are cleaned up after integration runs

### Missing Test Categories

Identify and flag gaps in any of these:

- [ ] Authorization tests (can user X access resource Y?)
- [ ] Input validation tests (do validators reject bad input?)
- [ ] Error handling tests (do errors propagate correctly?)
- [ ] Concurrent operation tests (race conditions?)
- [ ] Data migration/schema change tests

## Severity Guide

- **CRITICAL**: Internal code being mocked, auth functions untested
- **HIGH**: Payment/billing functions untested, core features without coverage
- **MEDIUM**: Missing edge case tests, skipped tests, flaky tests
- **LOW**: Test organization improvements, assertion quality, description clarity
