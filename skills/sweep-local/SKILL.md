---
name: sweep-local
description: Sweep local Claude Code history for loose ends — scan recent session logs for work that was started but never finished or PR'd, turn it into a task list, do the clear items, and surface the rest as decisions. Use for '/sweep-local', 'sweep local', 'find loose ends', 'what did we leave unfinished'. Part of /sweep.
allowed-tools: Bash(gh *),Bash(git *),Bash(python3 *),Read,Edit,Write,Grep,Glob,TaskCreate,TaskUpdate,TaskList
argument-hint: '[days, default 7] [--dry-run]'
---

Sessions end badly more often than they end cleanly. A machine crashes, a
context window fills, a `/loop` gets interrupted, a thread drifts to a new
topic and the last one is simply never returned to. Each of those leaves work
that a human believes is done and that nothing on GitHub reflects.

This skill sweeps `$CLAUDE_CONFIG_DIR/projects` (default `~/.claude/projects`)
for the last N days, finds that work, and lands what it safely can.

**Scope:** `$ARGUMENTS` may set the window in days (default `7`). `--dry-run`
means report only — no commits, no pushes, no PRs.

## The one rule

**A loose end is work with no home on GitHub.** Not "a session that looked
busy" — a thing that was started and is now represented nowhere: no merged PR,
no open PR, no issue. Every candidate gets checked against `gh` before it goes
on the list. Most won't survive that check, and that is the point; the value
here is a short, true list, not a long, plausible one.

## Step 1 — Extract the sessions

```bash
python3 skills/sweep-local/scripts/extract_sessions.py --days 7 --out "$SCRATCH/sweep-local-sessions.json"
```

(`$SCRATCH` is any scratch directory outside the repo. `--root` overrides the
projects directory.)

Per session it returns the branch, cwd, title, first and last human prompts,
the last thing the assistant said, every PR number mentioned, the replayed task
list, and an `interrupted` flag. The digest it prints to stdout is usually
enough to decide which sessions deserve a closer read.

Read the **last assistant message** of any session you're unsure about. It is
by far the highest-signal field in the transcript: a finishing agent writes a
summary with links, and an interrupted one stops mid-sentence.

The transcripts can contain anything a session saw, including secrets pasted
into a prompt. Keep the extracted JSON in the scratch directory, never commit
it, and quote from it only what a PR or report actually needs.

## Step 2 — Cross-reference against GitHub

```bash
gh pr list --state open   --limit 60 --json number,title,headRefName,isDraft,mergeStateStatus
gh pr list --state merged --limit 60 --json number,title,headRefName,mergedAt
```

Join on `headRefName` against each session's branch, then classify:

| What you find                                        | What it means                                                                                                             |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Branch has a **merged** PR                           | Done. Drop it.                                                                                                            |
| Branch has an **open** PR, checks green, `CLEAN`     | Waiting on a human to merge — a decision, not a task.                                                                     |
| Branch has an **open** PR, `mergeStateStatus: DIRTY` | **Merge conflict.** Clear, actionable, yours.                                                                             |
| Branch has an **open** PR with red checks            | Read the logs before reacting — a cancelled/superseded run is not a failure.                                              |
| Branch has **no PR at all**                          | The real find. Was it abandoned on purpose, or dropped?                                                                   |
| Session promised a follow-up PR that doesn't exist   | The other real find. Grep last assistant messages for "say the word", "follow-up", "still worth your call", "open items". |

Sessions span every project on the machine, so check each session's `cwd`
against the repo it belongs to. A move between repos is two PRs, and the pair
can half-land — one side merged, the other still open, leaving two live copies
of the thing that was supposed to exist once.

## Step 3 — Sweep the worktrees for stranded work

```bash
git worktree list --porcelain | grep '^worktree ' | sed 's/^worktree //' | while read wt; do
  [ -d "$wt" ] || continue
  dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  ahead=$(git -C "$wt" log --oneline @{u}..HEAD 2>/dev/null | wc -l | tr -d ' ')
  [ "$dirty" = 0 ] && [ "$ahead" = 0 ] && continue
  echo "### $wt  dirty=$dirty unpushed=$ahead  ($(git -C "$wt" branch --show-current))"
  git -C "$wt" status --porcelain 2>/dev/null | head -8 | sed 's/^/    /'
done
```

**Unpushed commits are the emergency.** They exist on exactly one disk. Say so
loudly and near the top of the report.

**Most dirt is not work.** Generated code, sample data and stray dependency
directories often show as modified in long-lived worktrees without anyone
having touched them. Look at the actual paths before calling something lost
work — and never `git checkout`/`clean` a worktree to tidy it. Deleting
someone's uncommitted work is the one mistake this skill must never make.

## Step 4 — Split the list in two

Build the task list with `TaskCreate`, then sort every item into one of two
piles. The split is the deliverable.

**Do it now** — all four must hold:

- **Clear** — you know exactly what the change is without asking.
- **Actionable** — nothing blocks it.
- **Important** — something is actually broken, stranded, or blocking.
- **Reversible** — a PR someone can decline. Not a merge, not a deletion.

**Ask first** — anything that is one of:

- A product, pricing, naming or scope call.
- A merge, a force-push, a deletion, or anything touching prod data.
- Work whose shape depends on an answer only they have.
- An open PR sitting green: merging is theirs, not yours.

When in doubt, it goes in the ask pile. A missed fix costs one round trip; a
wrong irreversible action costs much more.

## Step 5 — Do the "do it now" pile

Normal repo rules (see the repo's `CLAUDE.md` / `AGENTS.md`): a worktree per
change, a failing test first where a test makes sense, targeted tests only, let
the pre-commit hook run, one PR per concern. Say in each PR body that
`/sweep-local` found it and which session dropped it — that provenance is what
stops the same thing being re-found next week.

Skip this step entirely under `--dry-run`.

## Step 6 — Report

Lead with what you did and the PR links. Then the decisions, each with enough
context to answer without opening anything: what the decision is, why it is
theirs, what happens either way, and your recommendation. Number them so they
can reply "1 and 3, yes".

Close with what you deliberately left alone and why. A `/sweep-local` that
silently drops something is worse than one that reports it as skipped.

## What the logs actually look like

Learned the hard way; these are the things that cost time if you rediscover them.

- **Task state lives in `TaskCreate`/`TaskUpdate` tool calls, not `TodoWrite`.**
  Current Claude Code uses the Task tools; `TodoWrite` appears only in older
  transcripts. Scan for both or every session reports zero open tasks. Task ids
  are 1-based in creation order, which is how a `TaskUpdate` maps back to its
  `TaskCreate`.
- **`TaskUpdate` descriptions are the richest field in the whole log.** Agents
  write their outcome into the description when completing a task — PR number,
  what was fixed, what was deliberately left. Read them before reading anything
  else.
- **File mtime is not last-activity time.** Bulk operations touch these files.
  Use mtime to pick candidate files cheaply, then order by message `timestamp`.
- **`role: user` is not "the human typed this".** Tool results, skill preambles
  (`Base directory for this skill:`), attachments and interrupt markers all
  arrive as user messages. Filter on `origin.kind == 'human'`.
- **The `interrupted` heuristic is a hint, not a verdict.** It flags a final
  message that doesn't end in sentence-ending punctuation, which also fires on
  a message ending in a bare path or a wide markdown table. Read before
  believing.
- **Skip `*/subagents/*.jsonl` on the first pass.** They duplicate the parent's
  work at several times the volume. Open one only when a parent needs detail.
- **Sessions with one prompt are usually noise** (`Hi`, `pwd`) — but not always:
  a one-prompt session can be a whole epic with the summary in the last message.
  Judge on the last assistant message, not the prompt count.
- **A branch can be merged and still be checked out.** After a squash-merge the
  local branch survives and reads as far behind main. That's a stale checkout,
  not unlanded work.
