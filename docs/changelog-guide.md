# Changelog Guide

A ready-made writing guide for a user-facing changelog. The `changelog.yml`
workflow reads this file (its `CHANGELOG_GUIDE` knob, default
`docs/changelog-guide.md`) when it exists, and Claude follows it on top of the
rules built into the workflow prompt. Copy it into your repo and edit it to
match your product's voice.

## Format

One Markdown file, newest-first. Each day with user-facing changes gets a dated
H2 heading (ISO 8601, `YYYY-MM-DD`, UTC) with categorized H3 sub-sections:

```markdown
## 2026-03-25

### New

- Shared links now show a preview card

### Improved

- Search results load noticeably faster

### Fixed

- Fixed an issue where notifications could appear twice
```

| Heading      | When to use                        |
| ------------ | ---------------------------------- |
| **New**      | Brand-new features or capabilities |
| **Improved** | Enhancements to existing features  |
| **Fixed**    | Bug fixes                          |

Skip any heading that has no entries for the day.

## Writing style

1. **Write for non-technical users.** No PR numbers, no code references, no
   component or file names. Describe what changed from the user's point of view.
2. **Be concise.** One line per change. Start with a verb or noun, not "We" or
   "The team".
3. **Skip non-user-facing work.** Refactors, dependency bumps, CI changes, test
   additions and internal tooling do not belong here.
4. **Present tense** for new features ("Shared links show..."), **past tense**
   for fixes ("Fixed an issue where...").
5. **Group related changes** into one bullet rather than listing every
   micro-change.

## What never goes in

A public changelog is read by users and by anyone looking for a way in. It talks
about features users can see and bugs they would have noticed, never about how
the system works inside or where it was weak. Leave an entry out (or rewrite it
so only the user-visible change remains) when it touches any of:

- **Security.** Vulnerabilities closed, access-control or permission fixes, data
  that was visible to the wrong people, authentication or session internals
  (token handling, session lifetimes, sign-out behavior), login or password
  behavior that hints whether an account exists, rate limits and their numbers,
  admin-only surfaces, redirect handling, content security policy, and anything
  that names an exploit path.
- **Billing and money integrity.** Double charges, wrong amounts charged or
  credited, credits granted before payment or never granted, refunds or
  disputes mishandled, plans that did not deliver what was advertised, and any
  fraud or manual-review controls.
- **Compliance and legal.** Privacy fixes; consent, terms, opt-in or disclosure
  changes made to meet a legal requirement; tax and reporting thresholds; data
  retention or third-party data handling; wording changed because earlier copy
  overpromised.
- **Infrastructure and vendors.** Environments (production, previews), which
  provider does what, failover behavior, configuration, and moderation or
  safety-filter mechanics.
- **Admissions.** Nothing that implies the project did something wrong, such as
  wording that says a number, a promise, or a limit used to be misleading. An
  ordinary bug fix ("Fixed a page not loading on some phones") is fine; a fix
  whose description reveals one of the categories above is not.

When in doubt, leave it out. A missing changelog line costs nothing.

## How the workflow uses this

`changelog.yml` creates a `changelog/auto-YYYY-MM-DD` branch, lists PRs merged
since the newest dated heading in the changelog, asks Claude to write entries
following the rules above, and opens a PR. Because each run starts from the
newest heading on the base branch, merge (or close) each changelog PR before
the next run, or set `CHANGELOG_AUTO_MERGE: 'true'` to have it land itself once
CI is green.
