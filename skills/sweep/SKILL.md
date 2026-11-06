---
name: sweep
description: Run both sweeps in one go. First sweep-local, which finds loose ends in recent Claude Code sessions and lands them. Then sweep-github, which closes dead PRs and issues, ranks everything into Priority-1..10, bulk-merges the top ten PRs and builds PRs for urgent issues. Use for '/sweep', 'run the sweep', 'sweep everything', 'do a full sweep'.
allowed-tools: Bash, Read, Edit, Write, Grep, Glob, Agent, Skill, SendMessage, TaskCreate, TaskUpdate, TaskList
argument-hint: '[--local-only | --github-only] [--dry-run]'
---

# Sweep

A container that runs the two sweeps in order. Each one also runs on its own:

| Skill                 | Sweeps                                                       | Run alone with  |
| --------------------- | ------------------------------------------------------------ | --------------- |
| `skills/sweep-local`  | recent local Claude Code session history                     | `/sweep-local`  |
| `skills/sweep-github` | open PRs (minus `SWEEP_SKIP_AUTHORS`) and every open issue   | `/sweep-github` |

**Argument:** `$ARGUMENTS` may be:

- `--local-only` or `--github-only` to run one half.
- `--dry-run`, passed to both. In sweep-local it means report only. In
  sweep-github it means assess and report, but close, label and merge nothing.

## Order: local first, then GitHub

1. **Run `skills/sweep-local`** (load it with the Skill tool and follow it).
   It finds work that was started in a session but never reached GitHub, and
   opens PRs for the clear items.
2. **Then run `skills/sweep-github`.** The PRs sweep-local just opened are now
   on GitHub, so they get ranked into a `Priority-N` bucket alongside
   everything else. They aren't stranded in a separate report.

Don't run them in parallel: the GitHub sweep's scope list is taken at its
round 0, and it should include the local sweep's new PRs.

The two halves share no state beyond GitHub itself. When one fails, report it
and still run the other.

## Report

Send one combined report, local first:

1. **Sweep local:** loose ends found, what was landed (PR links), and what was
   left as a decision.
2. **Sweep GitHub:** use sweep-github's report sections (closed, ranked, round
   3, live exposures, follow-ups).

Link every PR with its full URL (`https://github.com/<owner>/<repo>/pull/N`) so
it is clickable wherever the report is read. Each half's own "send the human
the closed list straight away" step still applies mid-run.
