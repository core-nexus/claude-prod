import { describe, expect, it } from 'vitest'
import { filter } from '../src/filter.js'
import { SELF_REPORT_PREFIX, SELF_REPORT_TAG } from '../src/selfReport.js'
import type { Normalized } from '../src/types.js'

function makeNormalized(overrides: Partial<Normalized> = {}): Normalized {
  return {
    projectSlug: 'web',
    orgSlug: 'acme',
    shortId: 'WEB-1',
    issueId: '1',
    title: 't',
    culprit: null,
    message: null,
    level: 'error',
    platform: 'javascript',
    environment: 'production',
    release: null,
    transaction: null,
    serverName: null,
    firstSeen: null,
    lastSeen: null,
    count: 5,
    userCount: 1,
    issueType: 'error',
    issueCategory: null,
    isUnhandled: null,
    sentryIssueUrl: 'https://sentry.io/',
    sentryEventUrl: null,
    sentryApiEventUrl: null,
    sentryApiIssueUrl: null,
    latestEventId: null,
    triggeredRule: null,
    trigger: 'created',
    exception: null,
    topFrames: [],
    breadcrumbs: [],
    tags: {},
    request: null,
    user: null,
    contexts: {},
    sdk: null,
    fingerprint: [],
    extra: {},
    dispatchId: 'd',
    ...overrides,
  }
}

describe('filter', () => {
  it('passes error-level events for a known project', () => {
    const res = filter({
      normalized: makeNormalized(),
      projectConfig: { repo: 'acme/web', eventType: 'sentry-triage' },
      allowWarningsGlobal: false,
    })
    expect(res.pass).toBe(true)
  })

  it('drops when the project is unknown', () => {
    const res = filter({
      normalized: makeNormalized(),
      projectConfig: undefined,
      allowWarningsGlobal: false,
    })
    expect(res.pass).toBe(false)
    if (!res.pass) expect(res.reason).toBe('unknown_project')
  })

  it('drops trigger=other', () => {
    const res = filter({
      normalized: makeNormalized({ trigger: 'other' }),
      projectConfig: { repo: 'acme/web', eventType: 'sentry-triage' },
      allowWarningsGlobal: false,
    })
    expect(res.pass).toBe(false)
    if (!res.pass) expect(res.reason).toBe('trigger_other')
  })

  it('drops warning level by default', () => {
    const res = filter({
      normalized: makeNormalized({ level: 'warning' }),
      projectConfig: { repo: 'acme/web', eventType: 'sentry-triage' },
      allowWarningsGlobal: false,
    })
    expect(res.pass).toBe(false)
    if (!res.pass) expect(res.reason).toBe('level_warning_not_allowed')
  })

  it('allows warning level when project opts in', () => {
    const res = filter({
      normalized: makeNormalized({ level: 'warning' }),
      projectConfig: {
        repo: 'acme/web',
        eventType: 'sentry-triage',
        allowWarnings: true,
      },
      allowWarningsGlobal: false,
    })
    expect(res.pass).toBe(true)
  })

  it('allows warning level when the global flag is on', () => {
    const res = filter({
      normalized: makeNormalized({ level: 'warning' }),
      projectConfig: { repo: 'acme/web', eventType: 'sentry-triage' },
      allowWarningsGlobal: true,
    })
    expect(res.pass).toBe(true)
  })

  it('drops when below minEventCount', () => {
    const res = filter({
      normalized: makeNormalized({ count: 1 }),
      projectConfig: {
        repo: 'acme/web',
        eventType: 'sentry-triage',
        minEventCount: 5,
      },
      allowWarningsGlobal: false,
    })
    expect(res.pass).toBe(false)
    if (!res.pass) expect(res.reason).toBe('below_min_event_count')
  })

  it('treats a null count as 1 for minEventCount=1', () => {
    const res = filter({
      normalized: makeNormalized({ count: null }),
      projectConfig: { repo: 'acme/web', eventType: 'sentry-triage' },
      allowWarningsGlobal: false,
    })
    expect(res.pass).toBe(true)
  })

  it("drops the Worker's own self-report by tag", () => {
    const r = filter({
      normalized: makeNormalized({ tags: { [SELF_REPORT_TAG]: 'true' } }),
      projectConfig: { repo: 'a/b', eventType: 'x' },
      allowWarningsGlobal: false,
    })
    expect(r).toEqual({ pass: false, reason: 'self_report' })
  })

  it("drops the Worker's own self-report by title prefix when tags are absent", () => {
    const r = filter({
      normalized: makeNormalized({ title: `${SELF_REPORT_PREFIX} github_dispatch_failed: GitHub 401` }),
      projectConfig: { repo: 'a/b', eventType: 'x' },
      allowWarningsGlobal: false,
    })
    expect(r).toEqual({ pass: false, reason: 'self_report' })
  })
})
