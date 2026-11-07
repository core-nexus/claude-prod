---
name: babysit
description: Babysit open PRs — resolve merge conflicts, retrigger stuck CI and flaky QA runs, and nudge the AI review/fix/QA pipeline forward
allowed-tools: Bash(gh *),Bash(git *),Agent
argument-hint: '[--dry-run]'
---

Scan the open PRs you can act on that were **updated in the last 24 hours** and take one automated action per PR based on their state. Designed to run inside a `/loop` — each invocation processes every PR that needs attention and exits; the next iteration catches follow-up work.

**⏱️ The 24-hour window is a hard scope limit.** PRs untouched for more than 24h are out of scope for every priority — see "The 24-hour freshness window" in Step 1.

This skill assumes the repo has the [claude-prod](https://github.com/core-nexus/claude-prod) review/fix workflows installed (or equivalents that respond to `/claude-review`, `/claude-fix`, and optionally `/qa-review`). If your repo doesn't have a workflow for one of these slash commands, the corresponding priority is harmless — the comment is posted and nothing happens.

**🧹 Every invocation is a fresh start.** Re-derive every PR's state from fresh `gh` output. Don't reuse classifications, don't assume prior actions landed, and don't trust rules remembered from earlier in the session — treat THIS SKILL.md as the only source of truth. The only durable state between runs is the lock file and on-GitHub state.

**One action per PR, all PRs in parallel.** Git work (merge, empty commit) runs in isolated worktrees; review/fix dispatches comment `/claude-review`, `/claude-fix`, or `/qa-review` on the PR. Nothing conflicts, so nothing defers.

**Dry-run:** if `$ARGUMENTS` contains `--dry-run`, report what each PR needs but don't push, merge, comment, or re-run anything.

## Step 0 — Acquire lock

Only one instance may run at a time. Use `/tmp/babysit.lock`:

- **Exists and less than 2 hours old** — another instance is running. Print `Another babysit instance is already running (lock acquired at <ts>). Exiting.` and STOP.
- **Otherwise** — delete if stale, then `date +%s > /tmp/babysit.lock`.
- **On exit (success or error)** — `rm -f /tmp/babysit.lock`.

## Step 1 — Gather PR data

```
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
ME="$(gh api user --jq .login)"
gh pr list --state open --search 'sort:updated-desc' --limit 100 \
  --json number,title,headRefName,mergeable,mergeStateStatus,statusCheckRollup,author,isDraft,updatedAt > /tmp/prs-recent.json
```

One query + local filter guarantees we see the most recently-touched PRs across both "me" and "bots" without two queries racing each other's `--limit` cutoffs. We babysit our own PRs always, and bot PRs as well (so reviews fire on Dependabot/Sentry/etc. without manual nudging). Using `author.is_bot` (rather than a hardcoded list) auto-picks-up new bots.

```
CUTOFF="$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
jq --arg me "$ME" --arg cutoff "$CUTOFF" \
  '[.[] | select(.isDraft == false) | select(.updatedAt >= $cutoff) | select(.author.login == $me or .author.is_bot == true)] | .[:25]' \
  /tmp/prs-recent.json
```

Drafts are always skipped. If the filtered set is empty, report `No open non-draft PRs updated in the last 24h — nothing to do.` and STOP.

> If multiple humans run this skill against the same repo, they'll race on bot PRs. The actions are idempotent (the loop caps in Step 2a stop runaway comments), but it's noisy. If that's an issue, restrict bot handling to a single allowlisted user via a local edit (e.g. only add `or .author.is_bot == true` to the filter when `$ME` is that user).

### The 24-hour freshness window

**Only PRs updated in the last 24 hours are in scope.** A PR whose `updatedAt` is older than the cutoff is invisible to this skill: no merge, no empty commit, no `/claude-review`, no `/claude-fix`, no `/qa-review`, no QA re-run — it is never even classified in Step 3.

Why: babysitting is for PRs in active flight. A PR nothing has touched in a day is parked — waiting on a human decision, superseded, or abandoned — and poking it wastes CI minutes and API budget on work nobody is watching. Worse, the retry caps in Step 2a are scoped to the **head commit**, so a stale PR that can never go green re-qualifies for its 3 `/claude-fix` posts on every push forever; the window is what stops the skill from grinding on those indefinitely.

Two properties worth knowing:

- **`updatedAt` counts our own actions.** Any comment or push the skill makes bumps it, so a PR the skill is actively working stays inside the window on its own. The window closes only after a full 24h of genuine silence.
- **A stale PR revives for free.** Any human push, comment, or review bumps `updatedAt` and pulls it straight back into scope on the next tick. Nothing needs un-parking by hand.

`updatedAt` is ISO-8601 UTC (`2026-07-30T19:26:04Z`), so a lexicographic `>=` against the cutoff is a correct time comparison. The `date` fallback covers GNU coreutils where BSD's `-v` flag is unavailable.

## Step 2 — Early exit per PR

Before deeper inspection, mark a PR "skip" if it matches either row:

| Condition                                                                                                          | Report as                  |
| ------------------------------------------------------------------------------------------------------------------ | -------------------------- |
| NOT bot-authored AND all checks `SUCCESS` AND `mergeable != "CONFLICTING"` AND `reviewNeedsFix == false` (Step 2a) | "Healthy — skipped"        |
| ANY check is `IN_PROGRESS` or `QUEUED`                                                                             | "CI in progress — skipped" |

**Don't touch healthy BLOCKED PRs.** `mergeStateStatus == "BLOCKED"` with all-green checks just means branch protection is waiting for the author to click "Update branch" — that's not our job. Bot PRs with green checks still flow to Priority 2 (review), but must wait for CI to finish like everyone else. A PR with green CI but a pending MEDIUM/HIGH review finding is NOT healthy — see Step 2a.

If every PR was skipped, report the summary and STOP.

For PRs that survive early exit, also fetch the last commit author:

```
gh api repos/${REPO}/commits/{head_sha} --jq '.author.login'
```

### Step 2a — Review state and loop caps

A review comment ending in `MAXIMUM_FIX_PRIORITY: MEDIUM` / `HIGH` is unfinished work — even with green CI — until a `/claude-fix` has been posted in response. MEDIUM is the threshold because the fix workflow itself treats MEDIUM and above as in-scope; LOW is left for human follow-up. If the repo runs review and QA in parallel and fix should wait on BOTH, only trigger `/claude-fix` once QA has also posted — otherwise fix kicks off before QA evidence is available. (If the repo doesn't run QA at all, set `QA_ENABLED=false` below; the QA gates are skipped.)

Also compute loop-safety counters so we don't post `/claude-fix` or `/claude-review` endlessly when nothing is changing (e.g. a self-referential workflow-file PR where the review check fails for a reason no fix can clear until merge).

```
gh api --paginate "repos/${REPO}/issues/{PR#}/comments?per_page=100" --jq '.[] | {created_at, user: .user.login, body}' \
  | jq -s . > /tmp/comments-{PR#}.json
HEAD_AT="$(gh api repos/${REPO}/commits/{head_sha} --jq '.commit.committer.date')"
```

Paginate, and read the head commit by SHA. Both list endpoints return 30 items a page, oldest first: unpaginated, a busy PR's comment list stops before its newest comments, and `pulls/{PR#}/commits | .[-1]` names the 30th commit, not the head.

**Telling a review-finding comment apart from a `/claude-fix` response.** Both are authored by `claude[bot]` (both post via `anthropics/claude-code-action`), and both echo `MAXIMUM_FIX_PRIORITY:<level>` — the review states findings at that level; the fix-response echoes the threshold it worked against. Their `**Claude finished @<user>'s task**` headers do **not** separate them either: the review fires on `pull_request`, so its header names the *human PR author* (`github.actor`) — exactly like a human-typed `/claude-fix` response. The reliable signal is **position relative to the `/claude-fix` command**:

- A **`/claude-fix` response** is a `claude[bot]` `MAXIMUM_FIX_PRIORITY:` comment whose nearest *preceding* trigger comment (a standalone `/claude-review` or `/claude-fix` on its own line) is `/claude-fix`.
- A **review-finding** is a `claude[bot]` `MAXIMUM_FIX_PRIORITY:` comment that is NOT preceded by a `/claude-fix` — it responds either to the PR opening (auto-review) or to a `/claude-review`.

Matching on `MAXIMUM_FIX_PRIORITY:` alone (without this classification) treats a fix-response as a fresh finding, flips `reviewNeedsFix` true forever, and burns `/claude-fix` retries on already-addressed PRs. (Do NOT try to distinguish them by the `@<user>` in the header — the review names the human PR author, not `claude[bot]`.)

To classify: walk the PR's comments in chronological order tracking the most recent trigger command seen (`/claude-review` or `/claude-fix`); tag each `claude[bot]`-authored `MAXIMUM_FIX_PRIORITY:` comment as a review-finding or a fix-response per the rule above.

From `comments-{PR#}.json` and `HEAD_AT`, derive:

1. `reviewNeedsFix` — find the newest **review-finding** comment (classified as above; author `claude[bot]`). If its `MAXIMUM_FIX_PRIORITY` value is `NONE` / `XLOW` / `LOW` (or no review-finding exists), `reviewNeedsFix = false`. If `QA_ENABLED=true`, also require a comment containing `<!-- ai-qa-review -->` to exist — if QA hasn't posted yet, `reviewNeedsFix = false` (wait for QA). Otherwise, look for a `/claude-fix` command comment posted AFTER that review-finding. If present, `reviewNeedsFix = false` (already dispatched). Else, `reviewNeedsFix = true`.
2. `reviewMissing` — `true` if NO **review-finding** comment exists on the PR (a review has never posted findings). A `/claude-fix` response that echoes `MAXIMUM_FIX_PRIORITY:` does NOT count. Else `false`.
3. `fixAttemptsOnHead` — count of comments with `created_at >= HEAD_AT` whose body contains `/claude-fix` as a standalone slash command on its own line.
4. `reviewAttemptsOnHead` — same, but for `/claude-review`.
5. `rebaseAttemptsOnHead` — count of comments with `created_at >= HEAD_AT` whose body contains `@dependabot rebase`. Footnote ²'s idempotency gate: only comment `@dependabot rebase` on a Dependabot PR when `rebaseAttemptsOnHead == 0` (a rebase already requested since the last commit is still pending — wait for it to land).

Idempotent by construction: once `/claude-fix` is posted for a given review-finding `MAXIMUM_FIX_PRIORITY:` comment, subsequent runs see it and stop posting — until a newer review-finding appears.

Loop safety: `/claude-fix` and `/claude-review` are each capped at **3 posts per head commit**. A new push resets both counters. This bounds the retry loop when the underlying failure can't be cleared by re-invocation (and is cheap to un-cap by pushing any commit, including an empty one).

### Step 2b — QA review pending (`qaNeeded`)

Only relevant if `QA_ENABLED=true` (the repo has a `/qa-review` workflow such as `ai-qa-review.yml`).

The review pipeline runs review and QA IN PARALLEL on PR open, then the fix job runs once both finish: **(review ∥ QA) → fix (if needed)**. QA is usually triggered automatically by `pull_request`, but that event can be missed (cross-fork PRs, PRs opened as draft then converted to ready later on a runner that hiccups). This priority is the belt-and-suspenders: when a PR is old enough that QA should have fired but no QA comment exists, post `/qa-review` to kick it off.

Using the same `/tmp/comments-{PR#}.json` from Step 2a:

1. The PR is old enough that QA should have reached the browser phase. The QA workflow blocks waiting for the preview URL before it can click anything; nudging `/qa-review` before that finishes just cancels and replaces the QA run that's already waiting. Require: PR is older than 15 minutes (gives the preview-deploy + QA's first turn a comfortable window).

   If the repo posts a stable preview-deploy marker comment (e.g. `<!-- preview-deploy-comment -->` from a Cloudflare Pages or Netlify bot), additionally require a comment whose body contains that marker — set `PREVIEW_MARKER` below if so. If not configured, the 15-minute age check stands alone.

   If the age condition is unmet (or the marker is required but absent), `qaNeeded = false`.

2. QA has NOT already run for this cycle:
   - If no comment contains the marker `<!-- ai-qa-review -->` AND no comment contains `/qa-review`, `qaNeeded = true`.
   - Otherwise `qaNeeded = false` (already ran or already dispatched — wait for the QA comment to appear).

Idempotent by construction, same pattern as `reviewNeedsFix`: once `/qa-review` is posted OR the `<!-- ai-qa-review -->` comment appears, subsequent runs see it and stop posting.

### Step 2c — QA verdict (genuine finding vs. infra non-report)

Only relevant if `QA_ENABLED=true`.

A posted `<!-- ai-qa-review -->` comment is not automatically "QA passed". The QA workflow ends its comment with a structured verdict:

- `AI_QA_MAX_PRIORITY:<NONE|XLOW|LOW|MEDIUM|HIGH|UNKNOWN>` — highest-severity QA finding (`UNKNOWN` only on a non-report, below).
- `AI_QA_BLOCKING:<YES|NO>` — whether QA considers the PR blocked.
- A **non-report** means QA checked nothing, so it is **not a pass** — and not a finding either. It ends `AI_QA_MAX_PRIORITY:UNKNOWN`, or (from older QA workflow versions) carries `NONE` / `NO` under text such as `The QA run did not produce a report` or a `— could not run` heading. Typical causes: no report reached the publish job, browser automation could not start, or the preview was unreachable.

Derive these from the newest `<!-- ai-qa-review -->` comment (in `/tmp/comments-{PR#}.json`) alone. The QA check in `statusCheckRollup` cannot tell you: a `/qa-review` run is triggered by `issue_comment`, so GitHub files its checks under the default branch's commit, not the PR head.

1. `qaFindingNeedsFix` — the QA verdict is a genuine finding (`AI_QA_MAX_PRIORITY` is `MEDIUM`/`HIGH`, or `AI_QA_BLOCKING:YES` with any priority but `UNKNOWN`) AND no later comment contains `/claude-fix` on its own line. `/claude-fix` reads the QA comment directly — PR comments are readable by the fix bot even when CI logs are not — so it can act on a QA finding exactly as it acts on a review finding.
2. `qaInfraFailed` — the newest QA comment is a non-report AND no later comment contains `/qa-review` (a fresh run is already on its way). This is an **infra flake**, NOT a code defect — the remedy is to re-run QA, never to touch the code or ping `/claude-fix`.
3. `qaRunId` / `qaRunAttempt` / `qaRunStatus` / `qaRunConclusion` — the run that posted that comment, read from its workflow-run link. Do not look it up by the PR's head SHA: a `/qa-review` run carries the default branch's SHA, and pushes do not re-trigger QA, so the head usually has no QA run of its own.
   ```
   QA_RUN_ID="$(jq -r '[.[] | select(.body | contains("<!-- ai-qa-review -->"))] | last | .body' /tmp/comments-{PR#}.json \
     | grep -oE '/actions/runs/[0-9]+' | head -n 1 | grep -oE '[0-9]+$')"
   gh api repos/${REPO}/actions/runs/${QA_RUN_ID} --jq '.run_attempt, .status, .conclusion'
   ```
   Each rerun increments `run_attempt`, so this bounds infra reruns off durable GitHub state — no on-PR marker needed. No link in the comment means no `qaRunId`: report it for a human instead of re-running.

### Configuration (edit per repo if needed)

```
QA_ENABLED=true             # set to false if the repo has no /qa-review workflow
PREVIEW_MARKER=""           # e.g. "<!-- preview-deploy-comment -->" — empty disables marker check
FIX_ON_CI_FAILURE=true      # set to false if your fix bot cannot read CI logs (see P7 rationale)
```

## Step 3 — Classify remaining PRs

Walk in priority order. **First match wins**; do not apply multiple actions to the same PR.

Shorthand used below:

- `behind` — `gh api repos/${REPO}/compare/main...{headRefName} --jq '.behind_by'` is `> 0` (main has new commits). Replace `main` with the repo's default branch if different (`gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`).
- `stuckCI` — any check has `conclusion` in `FAILURE` / `CANCELLED` / `TIMED_OUT`.
- `checksPending` — checks list is empty or all-pending.
- `botLastCommit` — last commit author is a bot.
- `reviewCheckFailed` — the `Claude PR Review` entry in `statusCheckRollup` has `conclusion` in `FAILURE` / `CANCELLED` / `TIMED_OUT`.
- `qaHasPosted` — some comment on the PR contains the `<!-- ai-qa-review -->` marker. (If `QA_ENABLED=false`, treat as `true` so P7 doesn't gate on it.)
- `qaFindingNeedsFix` / `qaInfraFailed` — see Step 2c. (Both `false` if `QA_ENABLED=false`.)
- `ciFailed` — any check has `conclusion == FAILURE` AND `FIX_ON_CI_FAILURE=true`.
- `dependabot` — the PR author matches the Priority 2 skip-allowlist entry `dependabot`, case-insensitive.

| Priority | Condition                                                                                          | Action                                                                                                            |
| -------- | -------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| 1        | `mergeable == "CONFLICTING"`                                                                       | `/pr-merge-main {PR#}` — but `@dependabot rebase` for a Dependabot PR²; escalate a dueling-impl conflict³         |
| 2        | Bot-authored PR needing review (see below)                                                         | Update branch, then comment `/claude-review`                                                                      |
| 3        | `checksPending && botLastCommit && behind`                                                         | Update branch (merge retriggers CI)                                                                               |
| 4        | `checksPending && botLastCommit`                                                                   | Empty commit `"ci: retrigger checks"`                                                                             |
| 5        | `stuckCI && behind`                                                                                | Update branch (same as clicking GitHub "Update branch") — but `@dependabot rebase` for a Dependabot PR²           |
| 6        | `reviewMissing && reviewCheckFailed && reviewAttemptsOnHead < 3`                                   | Comment `/claude-review`                                                                                          |
| 7        | `(ciFailed OR ((reviewNeedsFix OR qaFindingNeedsFix) AND qaHasPosted)) && fixAttemptsOnHead < 3`¹  | Comment `/claude-fix`                                                                                             |
| 8        | `CANCELLED` / `TIMED_OUT` conclusion `&& botLastCommit && !dependabot`²                            | Empty commit `"ci: retrigger checks"`                                                                             |
| 9        | `qaNeeded` (see Step 2b; only if `QA_ENABLED=true`)                                                | Comment `/qa-review`                                                                                              |
| 10       | `qaInfraFailed && qaRunStatus == completed && qaRunAttempt < 3` (see Step 2c)                      | Re-run the QA run: `gh run rerun {qaRunId} --failed` if `qaRunConclusion` is `failure`, else `gh run rerun {qaRunId}` |

¹ The `qaHasPosted` gate is the parallel-pipeline invariant: fix is supposed to run against _both_ review and QA findings, so we wait for QA's `<!-- ai-qa-review -->` comment before nudging `/claude-fix`. P7 fires when **either** side has an open finding — a MEDIUM/HIGH review finding (`reviewNeedsFix`) **or** a MEDIUM/HIGH/blocking QA finding (`qaFindingNeedsFix`) — because `/claude-fix` reads both comments. The `ciFailed` half bypasses the QA gate — red CI is urgent and blocks merge regardless of QA's state — but only when `FIX_ON_CI_FAILURE=true` (see "Why P7 can be told to skip bare CI failures" below).

² **Dependabot exception.** You can't push to a Dependabot branch — a foreign merge or empty commit makes Dependabot disown the PR ("looks like this PR has been edited") and stop auto-managing it. So wherever a priority would merge into or empty-commit a Dependabot PR, comment `@dependabot rebase` instead: it rebases the PR onto the latest default branch (clearing staleness and conflicts) and re-runs CI. P8 skips Dependabot entirely — its trigger (CANCELLED / TIMED_OUT) only fires on an up-to-date branch (P5 catches behind ones first), and `@dependabot rebase` no-ops on an already-current branch. A red, up-to-date Dependabot PR — a cancelled run or a genuine bump breakage — is left for a human rather than auto-recreated. Idempotent: gated on `rebaseAttemptsOnHead == 0` (Step 2a); after the rebase lands, `behind`/`mergeable` flip and the priority stops re-firing on its own. A dependency-bump wave can open many red PRs at once; poke a handful per tick and catch the rest next tick.

³ **Dueling-implementation conflicts escalate — they do NOT "hold for human".** `/pr-merge-main` resolves _textual_ conflicts but aborts on a _semantic_ one — most often a **dueling implementation**, where the default branch has already merged a competing version of the same feature (e.g. two PRs adding the same webhook handler). Don't fall back to "held" on the first abort. A conflicting PR is rarely truly _superseded_: it usually still carries unique work on the non-conflicting files that a merge preserves. Instead, **dispatch a reconciliation agent** (see Step 4) that keeps the **superset** implementation (the one covering more cases), preserves the PR's unique non-conflicting changes, reconciles tests to the winning implementation, runs the **targeted** tests, and pushes only if green. Fall back to a human — with a concrete summary (which side is the superset, what unique work the PR still carries, which file conflicted) — only if the agent cannot get to green.

### Why this ordering

- **Why P7 can be told to skip bare CI failures (but never QA findings).** `/claude-fix` runs inside `anthropics/claude-code-action`, which acts as the Claude GitHub App. If that app's installation lacks `actions:read` / `checks:read`, every `gh run view` / check-run call from inside the action returns HTTP 403 "Resource not accessible by integration": the bot cannot diagnose failures **from CI logs**, correctly refuses to make speculative changes, and just posts an explanation — up to 3 identical ones per head SHA. If you see that, set `FIX_ON_CI_FAILURE=false`. Bare CI failures then rely on P5 (update if behind) and P4/P8 (retrigger), and persistent red up-to-date PRs need a human (or the opt-in `claude-auto-fix-ci.yml` workflow, which feeds the logs in directly). **A QA finding is different:** QA writes its findings into a PR comment, and PR comments are always readable by the fix bot — so P7 keeps firing on `qaFindingNeedsFix` either way.
- **P5 before P7 for red CI.** A red check on a stale branch is ambiguous — the fix may already be on main (test fixtures, dep bumps, CI workflow changes). Updating the branch is the human equivalent of clicking "Update branch"; if CI is still red on the next loop, P7 fires `/claude-fix`. Avoids wasting `/claude-fix` runs on stale-branch artifacts.
- **P6 before P7 so we run the review before trying to fix nothing.** When the `Claude PR Review` check is red AND no `MAXIMUM_FIX_PRIORITY:` comment has ever been posted, the auto-triggered review never actually produced findings — `/claude-fix` has no review-side work to do. Re-invoking `/claude-review` is the right remedy. If the review fails for a reason that can't be cleared in-PR (classically: a PR that edits the review workflow itself, where GitHub's workflow-identity check rejects the app-token exchange), the 3-attempt cap stops the loop.
- **Review-driven fixes bypass P5.** P7 still fires on `reviewNeedsFix` even when behind main — `/claude-fix` can cope with a stale branch on its own, and leaving an in-scope MEDIUM/HIGH review finding parked would silently drop work.
- **P7 gates on QA completion.** Because fix is supposed to run after BOTH review and QA, `reviewNeedsFix` waits for the `<!-- ai-qa-review -->` marker before firing `/claude-fix`. If QA is missing, P9 handles it first on this run; P7 fires next iteration once QA has posted.
- **Why cap P6/P7 at 3.** Empirically, when three consecutive `/claude-fix` (or `/claude-review`) runs against the same head commit produce the same "nothing to do" result, the next one will too. Three attempts is generous enough to ride through transient CI flakes and slow queues, tight enough to keep the PR timeline readable. The counter is scoped to the current head commit, so any real push (including a one-line empty commit) resets to zero.
- **P8 requires `botLastCommit`.** A human's last push already triggered CI; if something was cancelled, that may be intentional. P3/P4 use the same gate for the same reason.
- **P9 can fire without waiting for review/fix.** QA runs in parallel with review, so its belt-and-suspenders nudge doesn't need any sequencing — just "no QA comment exists on a PR old enough to have kicked off".
- **P10 clears QA infra flakes that fall through everything else.** A QA non-report is an infra flake, not a code defect. It matches none of P1–P9: it's up to date (not P5), it isn't CANCELLED/TIMED_OUT (not P8), and a QA comment already exists so P9's "no QA marker" gate blocks a fresh `/qa-review`. Left unhandled it sits forever looking like it "needs a human" when it just needs a re-run. P10 re-runs the run that posted it (no new commit, no other checks disturbed): only its failed jobs when it failed, all of it when it succeeded (`--failed` refuses a run with nothing failed). It waits while that run is still in progress, and is bounded by `qaRunAttempt < 3` so a systemically broken QA run escalates to a human instead of looping — a `/qa-review` posted instead would start a new run at attempt 1 and loop forever. Do NOT use P10 for a QA run that produced a genuine finding (that's P7's `qaFindingNeedsFix`).
- **Dependabot reds flow through P1/P5, not a special case.** A red or conflicting Dependabot PR is just a red bot PR — P1 or P5 already mean "bring it up to date". The only twist is the action: `@dependabot rebase` instead of a merge (footnote ²).
- **Never rebase green BLOCKED PRs.** P5 requires red CI _AND_ behind — not just behind. "BLOCKED + green" is a human merge-time concern, not ours; pre-emptively rebasing would thrash CI across many healthy PRs.

### Priority 2 — Bot PR needing review

Fire only if ALL of:

1. `author.is_bot == true`.
2. Author is NOT on the skip allowlist (below).
3. PR is older than 1 minute (let CI register).
4. No check is `IN_PROGRESS` or `QUEUED` (let CI finish).
5. No existing comment contains `MAXIMUM_FIX_PRIORITY:` (idempotency — already reviewed).
6. Changes are substantive — more than docs-only (`.md`), comment-only tweaks, pure dep bumps (`package.json` / `yarn.lock` / `Cargo.lock` / etc.), or config-only tweaks (`.json` / `.yaml` / `.yml`, no code).

Update the branch first (so the review sees latest code), then comment `/claude-review`.

**Skip allowlist** — match the bare bot name case-insensitively (logins may come prefixed, e.g. `app/dependabot`, `dependabot[bot]`):

- `dependabot` — dependency bumps, purely mechanical.

Default to reviewing any other bot. A false negative (skipping a bot that should have been reviewed) is worse than a false positive (reviewing a trivial PR). Add to the allowlist only if a bot is reliably always-mechanical. The allowlist only skips _review_ — a red or conflicting Dependabot PR is still brought up to date via P1/P5 (footnote ²).

## Step 4 — Execute all actions in parallel

All actions are independent: git work runs in isolated worktrees, comments are direct `gh` calls. Launch everything at once.

### Never switch the user's branch

**NEVER `git checkout <branch>` in the main working tree.** All git work happens in worktrees: `/pr-merge-main` runs through the Agent tool with `isolation: "worktree"`, and manual git work uses the helper below.

### Worktree helper

Worktree reuse is expected — if `/tmp/babysit-<branch>` exists from a prior run, reuse it; don't abort and don't pick a unique path.

```
DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)"
SAFE_BRANCH="$(echo '<branch>' | tr '/' '-')"
WORKTREE="/tmp/babysit-${SAFE_BRANCH}"
git fetch origin <branch> "$DEFAULT_BRANCH"
if [ -d "$WORKTREE" ]; then
  cd "$WORKTREE"
  git reset --hard HEAD && git clean -fd
  git checkout <branch>
  git reset --hard "origin/<branch>"
else
  git worktree add "$WORKTREE" <branch>
  cd "$WORKTREE"
fi
# ... do work ...
cd -
git worktree remove "$WORKTREE" || true   # safe to leave; next run will reuse
```

### Actions

- **`/pr-merge-main`** (P1) — invoke the `pr-merge-main` skill via the Agent tool with `isolation: "worktree"`, passing the PR number. It resolves conflicts thoughtfully rather than aborting on the first one.

- **Reconciliation agent** (P1 dueling-implementation escalation, footnote ³) — when `/pr-merge-main` aborts on a _semantic_ conflict, dispatch a **background** (`run_in_background: true`) general-purpose agent. Instruct it to work in its own git worktree of this repo, keep the superset implementation, preserve the PR's unique non-conflicting work, reconcile tests to the winning implementation, run the **targeted** tests (never the whole suite), and push to the PR branch only if green — otherwise report a human-readable summary.

- **Update branch** (P3, P5, and the merge step of P2) — in the worktree:
  ```
  git merge "origin/${DEFAULT_BRANCH}" --no-edit
  git push origin <branch>
  ```
  If the merge has conflicts you can't resolve mechanically, abort (`git merge --abort`) and surface the PR in the report with status `CONFLICT (manual)` — leave it for a human.

  > Alternative: `gh pr update-branch <PR#>` is the GitHub-native equivalent and avoids the worktree entirely. Prefer it when available; fall back to the worktree merge above if the API rejects it (e.g. branch protection requires up-to-date checks first).

- **Empty commit** (P4, P8) — use the worktree helper above, then:
  ```
  git commit --allow-empty -m "ci: retrigger checks"
  git push origin <branch>
  ```

- **PR comment** (P1/P5 Dependabot variant, P2, P6, P7, P9) — no worktree needed:
  ```
  gh pr comment <PR#> --body '/claude-review'      # P2 after the merge completes; P6 to retrigger a review that never posted findings
  gh pr comment <PR#> --body '/claude-fix'         # P7 — MEDIUM/HIGH review or QA findings (and red CI when FIX_ON_CI_FAILURE=true)
  gh pr comment <PR#> --body '/qa-review'          # P9 — kicks off the visual/behavioural QA workflow
  gh pr comment <PR#> --body '@dependabot rebase'  # P1/P5 Dependabot variant (footnote ²) — never merge into a Dependabot branch
  ```

- **Re-run the QA run** (P10) — no worktree, no comment; re-runs the run linked from the newest QA comment:
  ```
  gh run rerun <qaRunId> --failed   # the run failed: re-run only its failed jobs
  gh run rerun <qaRunId>            # the run succeeded but reported nothing (e.g. preview unreachable): re-run all of it
  ```
  Needs `actions:write` on your token. If the rerun returns `403 Resource not accessible`, report the QA infra failure as needing a human re-run rather than looping.

## Step 5 — Report

Print the raw `date` output at the top, then a summary table. Include PRs that got an action, plus any PR whose P6/P7 retry cap was hit on the current head commit (Action `—`, so the user can see we deliberately stopped). Skip fully healthy PRs. Sort by Status (alphabetical), then PR number (ascending).

**PR numbers MUST be clickable links** — use `gh pr view {PR#} --json url --jq .url` and format as `[{PR#}](url)`. No placeholder URLs.

```
Mon Apr  7 19:16:42 PDT 2026

| PR | Title | Status | Action |
|----|-------|--------|--------|
| [42](https://github.com/owner/repo/pull/42) | fix: off-by-one in pagination | CONFLICTING | updated branch |
| [51](https://github.com/owner/repo/pull/51) | feat: add CSV export | CHECK FAIL | commented /claude-fix |
| [58](https://github.com/owner/repo/pull/58) | chore: upgrade Vite | REVIEW MEDIUM | commented /claude-fix |
| [60](https://github.com/owner/repo/pull/60) | ci: review tracking cleanup | FIX CAP (3/3) | — |
| [63](https://github.com/owner/repo/pull/63) | refactor: split auth module | NEEDS REVIEW | commented /claude-review |
| [65](https://github.com/owner/repo/pull/65) | fix: race in webhook handler | CANCELLED + behind main | updated branch |
| [70](https://github.com/owner/repo/pull/70) | feat: invoice PDF rendering | QA PENDING | commented /qa-review |
| [72](https://github.com/owner/repo/pull/72) | feat: bulk invite | QA INFRA (attempt 1) | re-ran QA run |
| [74](https://github.com/owner/repo/pull/74) | chore(deps): bump lodash | CONFLICTING (dep) | commented @dependabot rebase |
```

Use `FIX CAP (n/3)` when `fixAttemptsOnHead >= 3` and `/claude-fix` would otherwise fire, and `REVIEW CAP (n/3)` for the `/claude-review` equivalent. When a dependency-bump wave means more red Dependabot PRs than you poked this tick, add a trailing note like `(N more red Dependabot PRs deferred to next tick)`.

If all PRs were healthy, report `All PRs are clean — nothing to do.`
