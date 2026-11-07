# Dependency Health & Supply Chain Review

## Objective

Audit the project's dependency tree for security vulnerabilities, outdated
packages, license compliance, unused dependencies, and supply chain risks.

## Scope: Focus on What Automation Can't Fix

If the project runs automated dependency updates (Dependabot, Renovate),
**don't report "a newer version exists"** — the bot already opens those PRs on
its own schedule (grouping ecosystems, honoring cooldowns, ignoring risky
majors). "Package X is at 2.1 and 2.3 is out" is noise it will handle.

Focus this review on problems automation **can't** fix on its own:

1. **Unpatched vulnerabilities** — especially in transitive deps where the
   parent hasn't released a fix (requires an `overrides` pin or removal).
2. **Unused / extraneous dependencies** that should be deleted.
3. **License risks**, supply-chain red flags, and lock-file integrity issues.
4. **Bundle bloat** from heavy or duplicated dependencies.

(If the project has **no** update automation, the "Outdated Dependencies"
section below still applies — flag security patches and stale critical deps.)

## Prerequisites

Before running any dependency commands, install dependencies first:

```bash
npm install  # or yarn install, pnpm install — use the project's package manager
```

## Review Checklist

### Vulnerability Scanning

- [ ] **Actually run** `npm audit` (or the project's equivalent) and read every
      finding — don't rely on memory; the tree changes every week. If it reports
      zero high/critical findings, **say so explicitly** — a clean audit is a
      valid and valuable result, not something to stay silent about.
- [ ] Categorize vulnerabilities by severity (critical, high, moderate, low)
- [ ] For each HIGH/CRITICAL advisory, record: package + version path, advisory
      id, whether it's **direct** or **transitive**, and whether it's reachable
      in **production** runtime, **dev-only**, or **build-only**
- [ ] Check if any dependencies have known supply chain attacks
- [ ] Verify no `postinstall` scripts do anything suspicious. If the package
      manager blocks dependency install scripts by default and keeps an
      allowlist (e.g. pnpm's allowed-builds setting), audit that list
      specifically — every entry runs arbitrary code on install

#### Remediation Strategy (decision tree)

Most real findings are in **transitive** dependencies that automation can't fix
because the direct parent hasn't published a release pulling in the patch. Work
in this order:

1. **Direct dep, patched release available** → let the update bot open the PR;
   just note it's in flight.
2. **Transitive dep, patch available in a child package** → add an entry to your
   package manager's override mechanism (npm/pnpm `overrides`, yarn
   `resolutions`) pinning the transitive dep to a patched version. Comment which
   advisory each override addresses so the pin can be removed once the parent
   upstream catches up.
3. **Dev-only / build-only vuln with no patch path** → document the exposure
   (who can exploit it, under what conditions) rather than papering over it with
   an override that breaks the build.
4. **Parent pinned to a major you've deliberately not bumped** → flag the
   trade-off for a human to decide.
5. **Vulnerable package is type-only or otherwise removable** (`@types/*` that
   ships its own stale copy, abandoned helpers) → remove it (see Unused
   Dependencies). Cleanest fix.

When adding overrides, verify install still succeeds, the advisory no longer
appears, and the lint/test suite still passes.

### Outdated Dependencies

- [ ] Run `npm outdated` (or equivalent) and review the results
- [ ] **Critical updates** (security patches): update immediately
- [ ] **Minor/patch updates**: assess changelog for breaking changes
- [ ] **Major updates**: document what's needed for migration
- [ ] If Dependabot/Renovate is configured:
  - Are all dependency groups still valid?
  - Are any important packages missing from automation?

### Key Dependency Status

Review the health of the project's most critical dependencies:

- [ ] **Framework** (React, Vue, Svelte, Next.js, etc.) — version, known issues
- [ ] **Backend** (Express, Fastify, database clients, etc.) — version, deprecations
- [ ] **Auth** — security patches, version alignment
- [ ] **Payment** (Stripe, etc.) — API version, SDK version, deprecated endpoints
- [ ] **Build tools** (Vite, Webpack, etc.) — version, plugin compatibility
- [ ] **Language** (TypeScript, etc.) — version, new features to leverage

### Unused Dependencies

- [ ] Identify packages in `package.json` that are not imported anywhere
  - Check both `dependencies` and `devDependencies`
  - Some packages may be used via CLI (not imported) — verify before removing
- [ ] Be careful with packages that never appear in an `import`: linter/
      formatter/bundler plugins loaded by config, CLI-only tools invoked from
      package scripts, and peer dependencies required by other packages
- [ ] Look for **duplicate functionality**: two packages that do the same thing
      (two date libraries, two UUID libraries). Pick one, remove the other.
- [ ] Look for `@types/*` packages whose runtime counterpart has been removed —
      they linger and often pull in stale code
- [ ] Identify packages that could be replaced with:
  - Built-in Node.js/runtime APIs
  - Smaller alternatives
  - Code already in the project

### Bundle Impact

- [ ] Identify the heaviest dependencies by bundle size contribution
- [ ] Check if large dependencies are tree-shaken properly
- [ ] Verify lazy loading for route-specific heavy dependencies
- [ ] Flag any dependency that adds >100KB to the client bundle
- [ ] Check for duplicate packages (same package at different versions)

### License Compliance

- [ ] All dependencies use compatible open-source licenses
  - MIT, Apache 2.0, BSD — generally safe
  - GPL, AGPL — check compatibility with project license
  - Custom/proprietary — flag for review
- [ ] No dependency has changed its license recently to something incompatible
- [ ] Transitive dependencies don't introduce license conflicts

### Lock File Integrity

- [ ] Lock file is committed and up to date
- [ ] No unexpected changes in lock file (integrity hash mismatches)
- [ ] Lock file doesn't reference private registries unexpectedly
- [ ] Package resolution is consistent (no conflicting versions)
- [ ] Declared runtime/engine constraints (`engines.node`, etc.) match what CI
      and production actually run

### Supply Chain Security

- [ ] Dependencies come from expected registries (npmjs.com, etc.)
- [ ] No typosquat package names (names similar to popular packages)
- [ ] GitHub Actions use pinned versions (`@v4` not `@main`)
- [ ] Docker images (if any) use specific tags, not `latest`
- [ ] No server-only dependency is accidentally bundled into the client
- [ ] No `eval()` or dynamic code execution from dependency content

## What to Fix

In priority order:

1. **Add overrides** for transitive vulnerabilities with a patch path, per the
   decision tree above, and list each override with the advisory it closes in
   the PR body.
2. **Remove** unused dependencies (and regenerate the lockfile).
3. **Remove or replace** duplicate-functionality dependencies.
4. **Update** packages with known vulnerabilities to patched versions — only
   where no update bot will (if one runs, don't open version-bump-only PRs;
   that's its job).
5. **Document** any vulnerability that cannot be fixed, with the risk
   assessment and why it is accepted.
6. **Flag** license concerns for human review — never silently change the
   project's licensing posture.
7. **Update** dependency automation config if new groups are needed

## Severity Guide

- **CRITICAL**: Known exploited vulnerability, compromised package, license violation
- **HIGH**: Unpatched security vulnerability, severely outdated critical dependency
- **MEDIUM**: Outdated dependencies with available updates, unused dependencies
- **LOW**: Minor version updates, bundle optimization opportunities, dev-only
  vulnerabilities with no remediation path that are knowingly accepted
- **XLOW**: Nits not worth an automated fix cycle
