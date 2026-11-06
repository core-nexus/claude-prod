# Skipping CI on docs-only PRs

Documentation-only pull requests (README tweaks, `docs/` edits, a `LICENSE`
change) don't need your full lint/test/build/e2e suite. Skipping it on those PRs
saves minutes and CI minutes. There are two ways to skip, and they solve
different problems.

## Option A — `paths-ignore` (simple, for NON-required workflows)

If the workflow is **not** a required status check, the simplest skip is
`paths-ignore` on the trigger — the workflow just doesn't run:

```yaml
on:
  pull_request:
    paths-ignore:
      - '**/*.md'
      - '**/*.html'
      - '**/*.txt'
      - 'doc/**'
      - 'docs/**'
```

This repo's `claude-pr-review.yml` and `ai-qa-review.yml` already do this — a
docs-only PR gets no AI code review and no visual QA, because there's nothing
code-shaped to review. (`ai-qa-review.yml` also ignores `skills/**`: an agent
skill changes nothing a browser can observe.) Manual `/claude-review` and
`/qa-review` comments, and `workflow_dispatch`, bypass `paths-ignore`, so you can
always force a run.

`paths-ignore` cannot express exceptions, so it cannot say "`*.html` is docs
except under `src/`". An app-shell-only PR (`src/app.html`) therefore skips these
two **advisory** AI workflows. That is safe as long as your deterministic suite
gates on the classifier below (which does treat `src/*.html` as code); if you'd
rather the AI passes fire too, drop `'**/*.html'` from their `paths-ignore`.

**The catch:** if the workflow is a **required** status check, `paths-ignore`
makes it never run, so its status never reports, and the PR sits forever waiting
on a check that will never arrive. For required checks, use Option B.

## Option B — `detect-docs-only.sh` (for REQUIRED status checks)

`.github/workflows/scripts/detect-docs-only.sh` reads a PR's changed-file list on stdin and prints
`true` (run the full suite) or `false` (docs-only, skip). Gate your expensive
jobs on it. Because the job still **runs** and **reports success** (it just skips
the expensive steps), a required check stays green and the PR stays mergeable.

It's fail-safe: an empty file list or any unrecognized extension resolves to
`true` (run everything). It only skips when it is certain every changed file is
documentation.

### Wiring it into a required CI workflow

```yaml
jobs:
  detect-changes:
    runs-on: ubuntu-latest
    outputs:
      run_suite: ${{ steps.detect.outputs.run_suite }}
    steps:
      - uses: actions/checkout@v4
      - name: Detect docs-only PR
        id: detect
        env:
          GH_TOKEN: ${{ github.token }}
          EVENT_NAME: ${{ github.event_name }}
          PR_NUMBER: ${{ github.event.number }}
        run: |
          if [ "$EVENT_NAME" = "pull_request" ]; then
            # The REST files endpoint paginates (up to 3,000 files);
            # `gh pr view --json files` stops at 100, which would let a large
            # PR's 101st file — the code one — go unseen.
            FILES=$(gh api --paginate \
              "repos/${{ github.repository }}/pulls/${PR_NUMBER}/files" \
              --jq '.[].filename')
          else
            FILES=$(git diff --name-only HEAD~1 HEAD)
          fi
          RUN=$(printf '%s\n' "$FILES" | .github/workflows/scripts/detect-docs-only.sh)
          echo "run_suite=${RUN}" >> "$GITHUB_OUTPUT"

  test:
    needs: detect-changes
    # Fail-safe gate: skip ONLY when detection succeeded AND said docs-only.
    # If the detect job errored (API hiccup), run_suite is empty, not 'false',
    # so the full suite runs. A naive `run_suite == 'true'` gate would do the
    # opposite and silently skip the suite whenever detection broke.
    if: ${{ !cancelled() && (needs.detect-changes.result != 'success' || needs.detect-changes.outputs.run_suite != 'false') }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # ... your lint / test / build steps ...
```

When `run_suite == 'false'`, the `test` job is skipped. If `test` is a required
check, a skipped required job is treated as passing, so the docs-only PR merges
without waiting.

### Required checks fed by a fan-out of jobs

If your required check is an **aggregator** job (one `lint` check that `needs:`
several `lint-*` tasks), give the aggregator `if: always()` and have it treat a
**skipped** task as success and anything else non-`success` as failure. Then the
tasks can gate on `detect-changes` as above while the required check still
reports green on a docs-only PR.

### What counts as "docs"

`.github/workflows/scripts/detect-docs-only.sh` treats these as docs (safe to skip):

- `*.md`, `*.txt`, `*.html` (but see the exception below)
- anything under `doc/` or `docs/`
- `LICENSE` / `LICENSE.*`

Everything else forces the full suite. The one exception: `*.html` **under your
source root** (`src/*.html`) is treated as code, not docs — an app shell or
framework error page ends in `.html` but is real application code. Adjust the
`src/` prefix in the script to match your source layout, and add a similar arm
for any other directory of `.html` files that a build step consumes (generator
templates, icon sources): if a test guards their output, a PR that edits only
those files must not skip that test.

### Exempting a self-contained subproject

Some repos carry independently-deployed subprojects (a worker, a CLI) with their
own package manager, lockfile, and CI workflow. Your main suite exercises none of
their files, so an only-that-subproject PR gains nothing from it, and you can add
an arm such as `packages/my-worker/*) return 0 ;;` to the classifier.

The rule for such an exemption is **"the main suite does not test this code, and
something else does."** Exempt a subproject only if its tests live with it and a
workflow of its own runs them. If any of its tests run in the main suite, it
belongs in the suite, or a PR that touches only that logic merges with its tests
never having run. Put any carve-out arm *above* the broader one, since `case`
takes the first match, and add a test for it.

### Tests

`.github/workflows/scripts/detect-docs-only.test.sh` exercises the classifier against docs-only,
code, mixed, app-shell, and empty-input cases. Run it with:

```bash
bash .github/workflows/scripts/detect-docs-only.test.sh
```
