# Documentation Accuracy Review

## Objective

Audit all documentation for accuracy, completeness, and alignment with the
actual codebase. Stale docs are worse than no docs — they mislead.

## Review Checklist

### Primary Documentation (CLAUDE.md / README)

If the project has a CLAUDE.md or similar AI-agent-facing doc, it is the
PRIMARY documentation for both AI agents and developers.

- [ ] **Technology versions**: Do versions listed match `package.json`?
- [ ] **Commands**: Do all listed commands (dev, lint, test, build) work?
- [ ] **Project structure**: Do listed directories and files actually exist?
- [ ] **Code conventions**: Do stated conventions match actual linter/formatter config?
- [ ] **Environment variables**: Are listed env vars still used? Any new ones missing?
- [ ] **Error handling philosophy**: Does the stated philosophy match actual patterns?
- [ ] **Testing philosophy**: Do testing guidelines match actual test patterns?

### README & Onboarding Docs

- [ ] **README.md**: Setup instructions are current and complete
- [ ] **Environment example files**: List all required environment variables
- [ ] New developers can follow the docs and get the project running
- [ ] Architecture diagrams (if any) reflect the current system

### Code Comments & JSDoc

- [ ] **Stale comments**: Comments that describe code that has changed
  - `// TODO` items that were completed but comment not removed
  - Comments describing old behavior after refactoring
  - Commented-out code that should be removed
- [ ] **Missing comments**: Complex logic without explanation
  - Regex patterns without description
  - Business rules embedded in code
  - Non-obvious algorithm choices
- [ ] **JSDoc/TSDoc accuracy**: Function documentation matches actual:
  - Parameter types and names
  - Return types
  - Side effects
  - Thrown errors

### API & Endpoint Documentation

- [ ] Public API surface is documented
  - What each endpoint/function does
  - Expected inputs and validators
  - Return types and possible errors
- [ ] HTTP endpoints are documented with methods, paths, and auth requirements
- [ ] Webhook handlers: expected payloads and behavior documented

### Schema / Data Model Documentation

- [ ] Database schema: table purposes and field meanings are clear
- [ ] Index documentation: why each index exists and what queries it serves
- [ ] Entity relationships are documented (which tables reference which)

### Configuration Documentation

- [ ] CI/CD workflows have comments explaining their purpose
- [ ] Cron schedules are documented with what they do and why that timing
- [ ] Environment-specific behavior is documented
- [ ] Feature flags or toggles are documented

### Changelog

- [ ] `CHANGELOG.md` (if it exists): recent entries match actual shipped features
- [ ] Entries are categorized correctly (New / Improved / Fixed)

## What to Fix

For each stale or inaccurate doc:

1. **Update it** to match the current code
2. **Remove it** if the feature no longer exists
3. **Add it** if documentation is missing for existing features

Do NOT add unnecessary documentation. Only document what helps developers
and AI agents understand and work with the code effectively.

## Severity Guide

- **CRITICAL**: Setup instructions that don't work, API docs for removed endpoints
- **HIGH**: Primary doc inaccuracies (AI agents and devs rely on these), misleading comments
- **MEDIUM**: Missing docs for complex logic, outdated configuration docs
- **LOW**: Minor wording improvements, optional additional documentation
