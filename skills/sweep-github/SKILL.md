---
name: sweep-github
description: Sweep every open PR (except those by authors listed in SWEEP_SKIP_AUTHORS) and every open issue. Close the dead ones for good reasons, re-rank all the live ones into exactly one Priority-1..10 label each, run bulk-merge on the top ten PRs, and open PRs for buildable Priority-8+ issues. Use for '/sweep-github', 'sweep the PRs', 'sweep the issues', 'triage and rank all my PRs', 'close dead PRs and re-prioritise', 'run a PR sweep'.
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, Skill, SendMessage
argument-hint: '[how many top PRs to bulk-merge, default 10] [--skip-merge] [--dry-run]'
---

# Sweep GitHub

Keep the open-PR list honest. A sweep runs in three rounds over every open PR
in scope:

1. **Close** the dead ones.
2. **Rank** every live, non-draft PR into exactly one `Priority-N` label.
3. **Land** the top N (default 10) through `skills/bulk-merge`.

It also sweeps **every open issue** through the same rounds: close (for a
good reason), rank, and build a PR for each buildable issue at Priority-8+.
See "Issues" below. On most teams nobody reads issues otherwise.

## Configuration

Set these in the environment (or tell the agent their values) before running.
The bundled scripts read them.

| Variable             | Default                              | Meaning                                                                                                                                                                                                                                                                             |
| -------------------- | ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `REPO`               | the current checkout's `owner/repo`  | The repository to sweep. Every `gh` call passes `-R "$REPO"`.                                                                                                                                                                                                                       |
| `SWEEP_SKIP_AUTHORS` | empty                                | Space-separated GitHub logins whose PRs are **out of scope**: never closed, labelled or merged. Use it for teammates who manage their own PRs. Their issues are still ranked, but close only as fixed, surface-gone or duplicate, with hard evidence (enforced by `close-issues.sh`). |

**Scope.** The sweep covers every open PR whose author is not in
`SWEEP_SKIP_AUTHORS` — typically the operator's own PRs and every bot's
(`app/claude`, `app/dependabot`, …). You may still cite an out-of-scope PR as
evidence ("superseded by <login>'s #N"), but do not close an in-scope PR in
favour of an unmerged out-of-scope one. Keep it and note the dependency.

**Drafts.** Round 1 only. A draft is closed when it is definitely dead, and is
otherwise left alone: no priority label, no merge.

**Argument:** `$ARGUMENTS` may give:

- the top-N count for round 3 (default `10`)
- `--skip-merge`, to stop after round 2
- `--dry-run`, to assess and report only: close, label, merge and build
  nothing

`skills/sweep` runs this skill after `skills/sweep-local`.

## The labels

`Priority-1` … `Priority-10`. **Higher means more urgent and important.** The
names don't show the direction, so every label carries the description "PR
sweep bucket: 10 = most urgent/important, 1 = least". These are buckets: click
a label to see everything at that level. **A PR or issue carries at most one.**
`scripts/set-priority.sh <N> <priority>` removes any other `Priority-*` label
and adds the new one.

Create the labels once (or recreate any that are missing):

```bash
for n in $(seq 1 10); do
  gh label create "Priority-$n" -R "$REPO" --color ededed --force \
    --description "PR sweep bucket: 10 = most urgent/important, 1 = least"
done
```

The full rubric is in `assess-brief.md`. In short: 10 = production broken now;
9 = live security, money or legal exposure; 8 = core-flow bug, PII leak, hard
deadline; 7 = clear bug fix; 6 = typical requested UI change or minor bug; 5 =
nice-to-have; 4 = polish, tooling, docs; 3 and below = exploratory or
speculative.

## Round 0: scope and group (you, the coordinator)

```bash
SCRATCH=<your scratchpad dir, outside the repo>
skills/sweep-github/scripts/scope.sh > $SCRATCH/scope.json   # honours SWEEP_SKIP_AUTHORS
jq 'length' $SCRATCH/scope.json
jq -r '.[] | "#\(.number)\t\(.author.login)\t\(if .isDraft then "DRAFT" else "" end)\t\(.mergeable)\t+\(.additions)/-\(.deletions)\t\(.createdAt[:10])\t\([.labels[].name]|join(","))\t\(.title)"' $SCRATCH/scope.json
```

Always pass `-R "$REPO"` to `gh`. From a scratch directory outside the repo,
`gh pr list` fails with "not a git repository".

**Group the PRs by theme, not by number,** into batches of about 10–25. Grouping
puts likely duplicates in front of the same agent. Typical groups:

- drafts
- compliance and privacy
- scheduled bot PRs (e.g. `review(<area>)` PRs from the codebase review)
- docs, changelog and dependency bumps
- billing, payments and credits
- UI change requests (split if large)
- recent work
- everything else

Check that every PR lands in exactly one group:

```bash
comm -3 <(jq -r '.[].number' $SCRATCH/scope.json | sort -n) <(your group lists | sort -n)
```

Write a pointed note per group: likely duplicate pairs (same title, same size),
which main PR may have superseded a cluster, which files a cluster shares.

## Round 1 + 2 assessment: one read-only pass

Spawn one `general-purpose` agent per group, all in the background in one
message. Each reads `skills/sweep-github/assess-brief.md` and gets its PR
numbers, the value of `REPO`, the path of the cached `scope.json`, plus your
group notes. The agents are **read-only**. Each returns a verdict (`CLOSE` or
`KEEP`) with evidence, a 1–10 score, readiness, and lessons, as JSON. One pass
covers both rounds, so each PR is read once.

As each report arrives, save its JSON to `$SCRATCH/results/<group>.json`.
Append its lessons to a running notes file. Improve this skill from them at the
end (see "Improve the skill").

## Round 1: close the dead

When every group has reported:

```bash
jq -s add $SCRATCH/results/*.json > $SCRATCH/assessed.json
skills/sweep-github/scripts/close-prs.sh $SCRATCH/assessed.json          # check
```

The dry run shows, per PR, its state, any comment or review by a
`SWEEP_SKIP_AUTHORS` login, and the state of the PR it names as canonical.
Before closing:

- **Spot-check two or three claims yourself** on main (`git grep` the
  string the agent says landed, `git show origin/main:<path>`).
- **Downgrade to KEEP** anything whose evidence is "duplicate of an unmerged
  PR outside the sweep", or that has a comment from a skipped author arguing
  for it.
- **A CLOSE whose canonical is an open in-sweep PR is fine,** for example a
  changelog week covered by a newer open changelog PR. Carry over anything the
  closed PR had that the canonical lacks, in a note to the canonical's
  bulk-merge agent or as a comment.

Then close them all at once:

```bash
skills/sweep-github/scripts/close-prs.sh $SCRATCH/assessed.json --apply
```

Each close comment carries the agent's evidence and "Reopen if this still
carries something main lacks". **Write the `evidence` field to be read by a
human on the PR,** with a merged PR number or sha in it.

**Report the closes to the human straight away,** before round 2. List every
closed PR as a link, grouped by why it was dead:

- already done on main by a merged PR (name it)
- covered by a newer or better open PR
- surface changed or approach dropped
- plan carried out

This is the list the human wants first.

## Round 2: rank (calibrate, then label)

Independent agents crowd the middle: left alone, a whole category (say, every
UI change request) defaults to the same score as live money bugs. **Calibrate
across groups before you label:**

1. List every KEEP with its score and one-line reason, sorted by score.
2. Re-score against the rubric as one list:
   - live money or legal exposure moves up to 9
   - PII leaks and hard deadlines within a month go to 8
   - pure-UI change requests go to 6
   - a "fix" that is now leftover hardening goes down
3. Nothing gets 10 unless production is broken right now. Usually nothing is.

Write the final list as `$SCRATCH/final.tsv` (`<priority>\t<number>\t<title>`)
and apply it in the background. At two `gh` calls per PR, about 100 PRs takes
about 4 minutes:

```bash
while IFS=$'\t' read p n _; do skills/sweep-github/scripts/set-priority.sh $n $p; done < $SCRATCH/final.tsv
```

Then verify: no open PR carries two `Priority-*` labels, and the intended
labels match the applied ones. Diff `<pr> Priority-<n>` lines from your list
against `gh pr list -R "$REPO" --json number,labels`.

## Round 3: bulk-merge the top N

Pick the top N (default 10) by priority. **Break ties by readiness**: `ready` >
`needs-main-merge` > `needs-rework` > `blocked`. Then load `skills/bulk-merge`
with those PR numbers and follow it, with these sweep-specific points:

- **Expect most of the top ten to be billing, auth, privacy or schema.** That's
  what scores 8–9, and `bulk-merge`'s merge-safe bar excludes all of it. The
  sweep still earns its keep: each one comes back merged with main, review
  comments addressed, CI green, adversarially read, and proven by a regression
  test that fails on main and passes on the PR. Report them as **ready for
  your merge** with the agent's confidence. Merge only what genuinely clears
  the merge-safe bar (prompt copy, observability, small UI).
- **Give agents a backend addendum.** For backend PRs, tell each agent:
  - verification is a red/green test against main's source
  - read the money or auth path end to end, including idempotency keys and
    fail-loud handling
  - skip any visual/viewport QA matrix when the diff has no UI
- **Sequence PRs that share files.** Hold the second of a pair (for example two
  PRs that both edit the same route handler, or two that both touch the same
  third-party integration) for the next wave. Brief the first agent to list the
  exact functions it changes, so the second can merge cleanly.
- **If a branch is checked out in the primary checkout or another worktree,**
  `git worktree add` refuses it. Reuse that worktree if it is clean, or work
  detached and push with `git push origin HEAD:<branch>`.
- **Policy questions go to the human mid-run, then to the agent.** Relay the
  human's answer to the agent with `SendMessage`, and save durable policy to
  memory (for example, "user erasure keeps audit rows but scrubs PII").
- **"Permission logic" in the merge-safe bar means changes to who can do
  what.** A diff that only _removes_ fields from a public read model, where
  nothing reads them (verify with `git grep` on main), closes a leak and can be
  merged.
- **"XLOW, no change" from a review bot can hide a real bug.** Trace any state
  a fix leaves behind into its later readers. A flag a fix leaves set can block
  a later flow (a renewal, a retry) forever.
- **Registry-style PRs go stale against a moving schema.** For example, a
  data-erasure cascade that lists every user table. After the main merge, the
  PR's drift guard is the first thing to check: tables added since it was
  written are easy to miss.
- **Production config is the human's to change, never the agent's.** No
  production credential or secret value goes on the agent's machine. The human
  changes production secrets in the hosting dashboard or the CI secrets; the
  agent says which keys need changing and why, then verifies (anonymously, with
  `curl`, against every hostname production answers on).
- **Example (SvelteKit): a layout guard doesn't protect page data.** Page
  `load` functions run in parallel with layout loads, so a `+layout.server.ts`
  that throws 403 still lets a page's own `+page.server.ts` data ship in
  `__data.json`. Probe the data endpoint, not the page. Other frameworks have
  their own version of this: check that authorization runs where the data is
  loaded, not only where the page is rendered.

## Issues: the same three rounds

**Issues that nobody reads are the most important part of the sweep, not an
extra.** Sweep every open issue in the same run, alongside the PRs. Spawn the
issue agents while the PR bulk-merge wave is running: they are read-only.

**Scope:** every open issue, whatever its author, because nobody else will
look at them. **Author care:**

- Issues by in-scope authors and bots close freely for any good reason.
- Issues by `SWEEP_SKIP_AUTHORS` close only as fixed, surface gone or
  duplicate, with hard evidence. Otherwise they are ranked and left open.
- `scripts/close-issues.sh` enforces this rule.

**Close aggressively, but only for a good reason.** Each closing comment cites
a merged PR, a sha, the thing that replaced the surface, the canonical
duplicate, or (for "not actionable") what was checked on main. Age alone is
never a reason.

```bash
gh issue list -R "$REPO" --state open --limit 1000 \
  --json number,title,author,labels,createdAt,updatedAt > $SCRATCH/issues.json
```

1. **Group** about 25–35 issues per agent, for example:
   - `auto-review` (findings deferred by the scheduled codebase review)
   - other bot issues
   - in-scope humans' issues
   - skipped authors' issues, split by date

   Consecutive numbers usually come from one batch audit or epic, so keep them
   in the same group.
2. **Assess:** one `general-purpose` agent per group, reading
   `skills/sweep-github/assess-issues-brief.md`. Each returns CLOSE or KEEP, a
   priority, and for anything at 8+, whether an agent can just build it.
3. **Close:** run `scripts/close-issues.sh $SCRATCH/assessed-issues.json` to
   check, then again with `--apply`. Then send the human the grouped, linked
   list of closed issues, like the PR list.
4. **Rank:** calibrate across groups exactly as for PRs, then apply with
   `scripts/set-priority.sh <issue> <N>`. The labels are shared, and the script
   works for both PRs and issues.
5. **Build the high-priority ones.** For every KEEP issue at **Priority-8 or
   above** with `buildable: true` and no `open_pr`, spawn an implementation
   agent, in waves of about 6. Each agent:
   - works in its own worktree, branched from `origin/main`
   - writes the failing test first
   - opens a PR whose body says `Fixes #<issue>`
   - runs it to green CI
   - never merges

   Then give each new PR the issue's priority label, and add it to the
   bulk-merge wave if it ranks in the top N. An issue at 8+ that isn't
   buildable goes in the report under Blocked, with the exact decision needed.

## Report

Link every PR and issue with its full URL
(`https://github.com/<owner>/<repo>/pull/N`):

1. **Closed:** grouped by why (already sent after round 1; repeat the count).
2. **Ranked:** the distribution (how many at each priority), plus the top 15
   with one line each.
3. **Round 3:** bulk-merge's own report: merged, ready for your merge, blocked
   and why.
4. **Live exposures found:** anything at 9–10, with the action only a human
   can take.
5. **Follow-ups:**
   - bot workflows that re-file duplicates
   - a changelog series to stitch
   - problems on main the assessment turned up

   Offer to file them.

## Improve the skill

Every run teaches something. Before finishing, fold the run's lessons into this
file, `assess-brief.md` or the scripts, and open a PR from a worktree.

## Lessons from past runs

- **Supersession hides behind unrelated titles.** `git log -S '<string main
  now has>'` names the fixing PR far more reliably than searching titles.
- **Pairs of open "duplicates" are often both superseded** by a third, merged
  PR. Check main before picking a canonical.
- **A scheduled changelog workflow can re-file every unmerged week.** If it
  starts from main's newest dated heading and caps its PR fetch, its window
  slides and no single PR is a superset. Close the covered weeks; stitch the
  rest into one PR.
- **Superseded-review auto-close usually keys on a label** (e.g.
  `auto-review`). A PR that was reset or re-opened under a human account
  without the label never gets closed, and the reviewer re-files the same
  finding. Look for these pairs.
- **Probe every hostname production answers on.** A platform-default hostname
  (`*.workers.dev`, `*.vercel.app`, `*.herokuapp.com`, …) can bypass an access
  proxy that only fronts the custom domain. A read-only `curl` settles exposure
  faster than reading code.
- **PRs that predate a package-manager switch** (lockfile changes from the old
  tool) all need redoing.
- **Many issues are already fixed or are superseded digests.** Scheduled review
  digests in the same area supersede each other; older ones without the
  bot's label are never auto-closed.
- **Small, clear, high-priority issues often have no PR.** Those are the
  sweep's best builds. Manual credential or security checklists are
  human-only.
- **"Closes #N" in a PR merged into a stacked branch never closes the issue.**
  Search merged PRs whose base isn't main, then confirm the code reached main.
- **`--search '#N in:body'` is noise for small N.** A dated `git log --grep`
  in the few days after an issue was filed finds same-day fixes that never
  linked back.
- **A bot that syncs PRs with an external tracker can reopen a closed PR**
  while its card is still "in review". Close the card too.
- **Many parallel agents share one GitHub API rate limit.** Cache the PR and
  issue JSON once and hand it to the agents. Check `gh api rate_limit` before
  a big wave.
- **Test mergeability without a checkout.** Fetch with
  `git fetch origin pull/N/head:refs/sweep/pr-N`, then run
  `git merge-tree --write-tree origin/main refs/sweep/pr-N`. For a pair,
  `commit-tree` the first result and merge-tree the second PR against it.
  Delete the `refs/sweep/*` refs afterwards.
- **"Mentions" is not "fixes".** Count only "Closes/Fixes #N"; a PR listing the
  issue under "known gaps" doesn't fix it.
- **Issues filed from a session ledger:** read the ledger's PR lines first.
  Many say "build after #X merges", which is a blocker or `depends_on`.
- **Check new issues against older open ones.** Keep the older one canonical,
  carry the details over in a comment, then close the newer.
- **Issues that need a production check sit open by default.** Give the
  assessors read-only production access, or have them tag the issue
  `needs-prod-check` with the exact query.
- **Open bot review PRs outside the batch** often name the batch PRs they
  overlap in a "Not in this PR" section. Grep for them.

**Shell gotchas the agents kept hitting:**

- zsh `echo =====` fails, because `=word` expands to a command path.
- zsh aborts `--include=*.ts` on an unmatched glob.
- `git pull` in worktrees may rebase if `pull.rebase` is set; use `--no-rebase`.
- `gh pr checks --watch` can outlast a 10-minute tool limit; poll in the
  background.
- A loop ending in `grep FAIL` exits 1 when nothing failed.
