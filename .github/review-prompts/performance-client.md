# Client Performance Review (Browser / Bundle / Core Web Vitals)

## Objective

Deep audit of **the experience a real browser pays for**: how heavy the
download is, how fast the app paints and becomes interactive, and how it holds
up during a long session. The **backend runtime/cost** half of performance
lives in `performance-server.md`, and long-horizon growth in `scalability.md`.

First establish how the app renders. If it is a client-rendered SPA (no server
render, no prerendering), the compiled client bundle _is_ the entire first-load
cost and client-side runtime _is_ the entire rendering story — this review is
then very high-leverage. With SSR/SSG, still audit hydration cost and what each
route ships.

**Your mission is not just to prevent regressions — it is to actively find ways
to raise Lighthouse scores and lower bundle weight over time.** Every review
should leave the app measurably lighter or faster, or at minimum identify the
next concrete win.

## The CI gates you are reinforcing

Look for existing performance gates (a bundle-size script or budget, Lighthouse
CI config, a web-vitals check) and read them so your findings build on them
rather than duplicating them:

- **Bundle-size gate** — find the structural wins that keep the number trending
  _down_ (code-splitting, lazy imports, lighter deps, tree-shaking). A gate that
  measures only TOTAL bytes cannot see a code-split regression that moves a
  heavy library into the entry chunk; recommend a check on the entry chunk's
  static import graph if none exists.
- **Lighthouse CI** — hunt the causes of warned metrics and propose fixes;
  recommend _tightening thresholds and promoting warnings to errors_ once the
  app earns the headroom; suggest adding high-value routes as they stabilize.

When you find a durable win, also note whether a threshold can now be
tightened — ratcheting the gate is how scores improve permanently instead of
drifting back. If no gates exist, recommending one is itself a finding.

## Review Checklist

### Bundle Size & Code-Splitting (HIGHEST PRIORITY)

- [ ] **Heavy deps in the initial chunk**: 3D/graphics, charting, animation,
      icon sets, ML/vision libraries — any of these landing in the entry
      chunk is a regression. They must be dynamically imported per route.
- [ ] **Tree-shaking defeats**: `import * as X from 'big-lib'` or barrel-file
      imports that pull a whole package. Prefer named imports.
- [ ] **`import type` vs runtime import**: an `import type { … }` is erased at
      build — leave it. A runtime `import { … }` is not. Don't confuse the two
      when chasing bundle weight.
- [ ] **Route-level lazy loading**: heavy views (3D, maps, charts,
      dashboards) are `await import()`-ed so they never touch the logged-out
      entry bundle. Check the components ALWAYS mounted by the root layout
      — a single static import there drags a
      heavy library into every route.
- [ ] **Static side-effect imports** (e.g. a library's CSS) land in every chunk
      that imports the component even when it never renders; move them to the
      dynamic-import path.
- [ ] **Duplicate dependencies**: two versions of the same lib bundled twice.

### Core Web Vitals & Render Performance

- [ ] **LCP (Largest Contentful Paint)**: what is the largest element on first
      paint, and is anything blocking it (render-blocking CSS/JS, late fonts,
      unsized hero media)?
- [ ] **CLS (Cumulative Layout Shift)**: images/embeds without explicit
      width/height, late-injected banners, web-font swap reflow.
- [ ] **TBT / INP (interactivity)**: long tasks on the main thread during boot.
      Heavy synchronous work in component init, big JSON parses, scene setup.
      Break up with `requestIdleCallback`, web workers, or deferral.
- [ ] **Main thread blocking**: data transformation, sorting/filtering, layout
      math done in the render cycle. Move it off the hot path.

### Lists, DOM Size & Virtualization

- [ ] **Virtual scrolling / windowing**: any list that can exceed ~50 items
      (feeds, search results, member lists, chat/comment streams, admin tables)
      needs windowing or progressive rendering. Unbounded DOM growth tanks INP
      and memory. Chat surfaces: mount a bottom-anchored tail with "load
      earlier", not every message.
- [ ] **Unbounded accumulators**: append-only "load more" buffers that never
      evict, and pagers that refetch the whole growing prefix each page
      (O(n²) over a session). Cap the rendered set or keyset-paginate.

### Images & Media

- [ ] **Lazy loading** for off-screen images (`loading="lazy"`).
- [ ] **Responsive `srcset`/`sizes`**, or resizing to the container width, so
      phones don't download desktop images and small cards don't fetch
      full-size uploads.
- [ ] **Modern formats** (WebP/AVIF).

### Memory & Lifecycle (long sessions)

- [ ] **Event listeners** not cleaned up on unmount.
- [ ] **Intervals/timeouts/animation frames** not cleared — including ones
      started by a modal or panel that a parent can unmount while they run.
- [ ] **Store/observable subscriptions** not unsubscribed.
- [ ] **Graphics/animation resources** (geometries, textures, render loops,
      animation timers) not disposed when a view unmounts.
- [ ] **Growing arrays/maps** that are never pruned.

## Known Hotspot Map (LIVING — keep this current)

> A code-grounded map of the heaviest **frontend render and bundle** hot spots in THIS repo, with `file:line` anchors. A
> generic checklist rots; a map that points at the real un-split bundles and heavy views compounds every run —
> an insight not written back here is lost. Keep it reading true against the
> default branch.
>
> **Maintaining the map depends on which stage you are:**
>
> - **Review stage (read-only — you do NOT edit files or open PRs):** do not edit
>   this file. Record every new/changed/cleared hotspot in your findings issue
>   under a `Hotspot map updates` heading (with `file:line`, why it matters, and
>   the exact edit you'd make) so the fixer can apply it verbatim.
> - **Fix stage / manual PRs (you DO edit files):** apply those edits here in the
>   same PR — add new spots (`STATUS: open`), flip resolved ones
>   (`STATUS: fixed (<PR/date>)`), clear false alarms
>   (`STATUS: cleared (<reason>)`), and re-anchor drifted line numbers. Stale
>   `file:line` anchors are worse than none.

_Empty until the first review seeds it. One entry per hotspot:_

```markdown
- **`path/to/file.ext:123` `functionName` — what it is and why it matters.**
  What to re-check on every run. STATUS: open | fixed (<PR/date>) | cleared (<reason>)
```

## Severity Guide

- **CRITICAL**: A heavy library pulled into the logged-out entry chunk; an
  unbounded DOM/accumulator that grows without limit
- **HIGH**: Tree-shaking defeats (`import *`), a route that should be lazy but
  isn't, a graphics/animation resource leak, a list >50 items with no
  virtualization
- **MEDIUM**: Missing image lazy-loading/responsive sizes, main-thread work that
  should be deferred, a CLS source, a metric warned by Lighthouse CI
- **LOW**: Minor preloading hints, micro-optimizations, opportunities to tighten
  a now-comfortable Lighthouse threshold or bundle budget
