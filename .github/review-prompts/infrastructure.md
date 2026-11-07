# Infrastructure & Tooling Review

## Objective

Audit the project's developer infrastructure: version-control configuration,
CI/CD workflows, pre-commit hooks, the linting/formatting toolchain, AI/agent
configuration, and the shell scripts that glue the system together. The goal is
to ensure the infrastructure is correct, consistent, maintainable, and not
silently broken.

This review covers everything that is NOT application code but that application
code depends on to be built, tested, deployed, and reviewed:

- Version-control configuration (`.gitignore`, `.gitattributes`, branch
  protection)
- CI/CD workflow definitions and their helper scripts
- Automated dependency-update configuration
- Pre-commit hooks and staged-file linters
- Linting and formatting configuration
- Type-checker / compiler configuration
- AI/agent configuration and instruction files
- Build and dev scripts
- Environment-variable setup and examples
- Runtime version requirements

## Review Checklist

### 1. Version-Control Configuration

- [ ] The ignore file covers all generated/transient artifacts (build output,
      caches, OS files, editor files, secrets)
- [ ] The ignore file does NOT exclude files that must be checked in (generated
      code the build depends on, lockfiles)
- [ ] No secrets, API keys, or local-only environment files are committed
      (search history with `git log --diff-filter=A --name-only` for sensitive
      filenames)
- [ ] Line-ending and attribute configuration is set appropriately (line
      endings, binary detection, diff drivers for lockfiles)
- [ ] No stale or contradictory ignore entries (duplicates, patterns that
      cancel each other out)
- [ ] The repo has no oversized tracked files (binaries, media, data dumps)
      that should use large-file storage or be stored externally

### 2. CI/CD Workflows

- [ ] All workflow actions/steps use pinned versions — not floating tags like
      `@main` or `@latest`
- [ ] Workflows have appropriate timeouts to prevent runaway jobs
- [ ] Workflow permissions follow least-privilege (only what each job needs)
- [ ] Concurrency controls are set where appropriate to prevent duplicate runs
- [ ] Scheduled (cron) workflows notify the team on failure — a background job
      that fails silently is a liability
- [ ] No workflow pushes directly to the default branch — all changes go
      through pull requests
- [ ] Secrets are referenced through the CI secret store, never hardcoded
- [ ] Manually dispatchable workflows have described, correctly typed inputs
      with sensible defaults
- [ ] Matrix strategies avoid cancelling independent jobs when one fails
- [ ] Checkout steps request the right history depth (full history only when a
      task actually needs it)
- [ ] No deprecated actions or versions with known vulnerabilities

### 3. CI Helper Scripts

- [ ] All scripts are executable
- [ ] Scripts use strict error handling (e.g. `set -euo pipefail`)
- [ ] Scripts validate required environment variables before using them
- [ ] No hardcoded repository names, branch names, or paths that should be
      parameterized
- [ ] Scripts handle edge cases (empty inputs, missing files, API failures)
- [ ] A shell linter passes on all scripts without warnings
- [ ] Any lists duplicated between a script and a workflow (e.g. the set of
      selectable options) stay in sync
- [ ] No script silently swallows errors (empty catch, `|| true` without
      justification)

### 4. Pre-commit Hooks & Staged-File Linters

- [ ] A pre-commit hook exists and is executable
- [ ] The staged-file linter runs the correct tools for each file pattern
      (formatter, linter, type check, shell lint) with fail-on-warning settings
      where appropriate
- [ ] Staged-file patterns do not have overlapping or conflicting rules
- [ ] Hooks are wired so they resolve in every checkout/worktree, not just the
      original clone
- [ ] The pre-commit hook does not take excessively long (a multi-second-plus
      hook usually signals misconfiguration)
- [ ] Every tool referenced by the hooks is present in the project's
      dev dependencies

### 5. Linting Configuration

- [ ] The lint config extends the appropriate recommended base configs for the
      languages in use
- [ ] Type-aware rules (e.g. no-floating-promises equivalents) are enabled for
      all relevant source directories
- [ ] Parser/project settings point at the correct config for each file group
- [ ] Excluded paths correctly skip only code that genuinely should not be
      linted (vendored code, generated output)
- [ ] Project-standard rules are enforced consistently
- [ ] No rule is disabled without a comment explaining why
- [ ] Ignore patterns do not accidentally skip files that should be linted

### 6. Formatting Configuration

- [ ] The formatter config matches the project's documented style standards
- [ ] Any language-specific formatter plugins are configured
- [ ] The formatter ignore file does not skip files that should be formatted
- [ ] Formatter and linter configs do not conflict (formatting rules should be
      the last layer applied)

### 7. Type-Checker / Compiler Configuration

- [ ] Strict mode is enabled
- [ ] Path aliases are configured correctly and consistently
- [ ] Include/exclude patterns match the project structure
- [ ] Sub-project configs are consistent with the root config where appropriate
- [ ] No conflicting compiler options between root and sub-project configs
- [ ] Module-resolution and target settings are appropriate for the runtime

### 8. AI / Agent Configuration

- [ ] Project instruction files are up to date with current conventions and do
      not reference deprecated patterns or removed files
- [ ] Agent/tool settings contain only necessary configuration
- [ ] Local, user-specific settings are ignored (not committed)
- [ ] No stale or orphaned files (old plans, temporary files) are left behind
- [ ] Agent definitions are coherent and non-overlapping in scope
- [ ] Reusable agent instructions/skills have clear, current guidance
- [ ] No secrets, API keys, or user-specific absolute paths are hardcoded in
      any agent-configuration file

### 9. Review-Prompt Files (if this review system is in use)

- [ ] Every area referenced by the scheduler has a corresponding prompt file
- [ ] Every prompt file is referenced by the scheduler
- [ ] All prompt files follow a consistent structure (Objective, Checklist,
      Severity Guide)
- [ ] Prompt files use a consistent severity scale
- [ ] No prompt file contains stale references to removed files, renamed
      directories, or deprecated APIs
- [ ] The selectable-area list in the workflow matches the scheduler's area list
      (and the scheduler's own tests pass)
- [ ] The superseded-review cleanup closes only older items of the same area
      carrying the review label — never a human's issue or PR

### 10. Build & Dev Scripts

- [ ] Package scripts are correctly defined and functional (dev server, build,
      lint, format, test)
- [ ] No script references a tool that is not installed or not declared as a
      dependency
- [ ] No script uses deprecated flags or APIs for its tools
- [ ] Build configuration matches the intended deployment target
- [ ] Dev-server / bundler configuration is correct (aliases, plugins, ports)

### 11. Environment-Variable Hygiene

- [ ] Committed env files contain only non-secret values
- [ ] Local-only / secret env files are ignored and NOT committed
- [ ] An example env file documents every required variable with a description
- [ ] Variable names follow a positive naming convention (prefer
      `FEATURE_ENABLED=false` over `FEATURE_DISABLED=true`)
- [ ] Every variable referenced in code appears in the example env file
- [ ] No environment values are hardcoded in source instead of read from config

### 12. Consistency Cross-Checks

These cross-cutting checks ensure different parts of the infrastructure agree
with each other:

- [ ] The declared runtime version matches the version CI sets up
- [ ] The package-manager version used locally matches CI
- [ ] Linter and formatter configs do not conflict
- [ ] Staged-file-linter tool versions match the installed dependency versions
- [ ] Scheduled-workflow cron expressions are valid and fire when intended
- [ ] Project instruction files match the actual toolchain configuration
- [ ] Severity scales are consistent across all review-prompt files
- [ ] Workflow, job, and step names are descriptive and consistent

## What to Fix

In priority order, the fix stage should:

1. **Security fixes** — remove committed secrets, tighten overly permissive
   workflow permissions, pin unpinned actions
2. **Correctness fixes** — repair broken scripts and configs, add missing
   failure notifications on scheduled workflows
3. **Consistency fixes** — align mismatched configs, sync duplicated lists,
   fix stale instruction-file references
4. **Hygiene fixes** — remove stale files, add missing ignore entries, improve
   script error handling

Do NOT make sweeping reformats or style changes to infrastructure files unless
they are actually broken. Configuration churn creates unnecessary review burden.

## Severity Guide

- **CRITICAL** — Committed secrets; workflows that can push to the default
  branch without review; broken deployment pipelines; missing branch protection
- **HIGH** — Scheduled workflows with no failure notification; broken
  pre-commit hooks; unpinned CI actions; scripts that silently swallow errors;
  lint configs that let known-bad patterns through
- **MEDIUM** — Stale configuration; lists that have drifted out of sync between
  files; instruction files out of date with the actual toolchain; missing
  environment-variable documentation; inconsistent CI settings
- **LOW** — Minor script improvements, config tidying, better error messages,
  documentation gaps in infrastructure files
- **XLOW** — Cosmetic nits in config files, comment improvements, naming
  preferences
