import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { normalize } from '../src/normalize.js'

const here = dirname(fileURLToPath(import.meta.url))
const fx = (name: string): unknown =>
  JSON.parse(readFileSync(join(here, 'fixtures', name), 'utf8'))

const DISPATCH_ID = 'dispatch-0000'

describe('normalize event_alert', () => {
  it('produces the expected normalized shape', () => {
    const result = normalize('event_alert', fx('event_alert.json'), {
      dispatchId: DISPATCH_ID,
      redactPii: true,
    })
    expect(result.kind).toBe('normalized')
    if (result.kind !== 'normalized') return
    const n = result.data
    expect(n.projectSlug).toBe('web')
    expect(n.orgSlug).toBe('acme')
    expect(n.shortId).toBe('WEB-4F2')
    expect(n.title).toContain('TypeError')
    expect(n.level).toBe('error')
    expect(n.platform).toBe('javascript')
    expect(n.environment).toBe('production')
    expect(n.release).toBe('web@1.2.3')
    expect(n.trigger).toBe('event_alert')
    expect(n.triggeredRule).toBe('High Priority Errors')
    expect(n.dispatchId).toBe(DISPATCH_ID)
    expect(n.latestEventId).toBe('abc123abc123abc123abc123abc12345')
    expect(n.sentryIssueUrl).toMatch(/sentry\.io/)
    expect(n.sentryEventUrl).toMatch(/abc123/)
    expect(n.sentryApiEventUrl).toMatch(/^https:\/\/sentry\.io\/api\/0\/projects\/acme\/web\/events\//)
  })

  it('extracts the exception type and value', () => {
    const result = normalize('event_alert', fx('event_alert.json'), {
      dispatchId: DISPATCH_ID,
    })
    if (result.kind !== 'normalized') throw new Error('expected normalized')
    expect(result.data.exception).toEqual({
      type: 'TypeError',
      value: "Cannot read properties of undefined (reading 'foo')",
    })
  })

  it('prefers in_app frames and reverses order so newest is first', () => {
    const result = normalize('event_alert', fx('event_alert.json'), {
      dispatchId: DISPATCH_ID,
    })
    if (result.kind !== 'normalized') throw new Error('expected normalized')
    const frames = result.data.topFrames
    // Two in-app frames come first.
    expect(frames[0]?.inApp).toBe(true)
    expect(frames[1]?.inApp).toBe(true)
    // src/index.ts should be first after reversal (it was last in source list).
    expect(frames[0]?.filename).toBe('src/index.ts')
    expect(frames[1]?.filename).toBe('src/foo.ts')
    // Non-in-app fills after.
    expect(frames[2]?.inApp).toBe(false)
    expect(frames[2]?.filename).toBe('node_modules/framework/runtime.js')
  })

  it('extracts breadcrumbs with ISO timestamps', () => {
    const result = normalize('event_alert', fx('event_alert.json'), {
      dispatchId: DISPATCH_ID,
    })
    if (result.kind !== 'normalized') throw new Error('expected normalized')
    const bc = result.data.breadcrumbs
    expect(bc).toHaveLength(3)
    expect(bc[0]?.category).toBe('navigation')
    expect(bc[0]?.timestamp).toMatch(/^\d{4}-\d{2}-\d{2}T/)
  })

  it('whitelists tags and drops PII when redactPii is true', () => {
    const result = normalize('event_alert', fx('event_alert.json'), {
      dispatchId: DISPATCH_ID,
      redactPii: true,
    })
    if (result.kind !== 'normalized') throw new Error('expected normalized')
    expect(result.data.tags.environment).toBe('production')
    expect(result.data.tags.release).toBe('web@1.2.3')
    expect(result.data.tags['browser.name']).toBe('Chrome')
    expect(result.data.tags['user.email']).toBeUndefined()
    expect(result.data.tags['internal.secret_tag']).toBeUndefined()
  })

  it('keeps user.email when redactPii is false', () => {
    const result = normalize('event_alert', fx('event_alert.json'), {
      dispatchId: DISPATCH_ID,
      redactPii: false,
    })
    if (result.kind !== 'normalized') throw new Error('expected normalized')
    expect(result.data.tags['user.email']).toBe('alice@example.com')
  })

  it('forwards all non-sensitive tags, not just a whitelist', () => {
    const result = normalize('event_alert', fx('event_alert.json'), {
      dispatchId: DISPATCH_ID,
      redactPii: true,
    })
    if (result.kind !== 'normalized') throw new Error('expected normalized')
    // Previously these non-whitelisted tags were dropped.
    expect(result.data.tags.os).toBe('Mac OS X 14.2')
    expect(result.data.tags.url).toBe('https://acme.example/dashboard')
  })

  it('captures request, user, contexts, sdk, fingerprint and extra', () => {
    const result = normalize('event_alert', fx('event_alert.json'), {
      dispatchId: DISPATCH_ID,
      redactPii: true,
    })
    if (result.kind !== 'normalized') throw new Error('expected normalized')
    const n = result.data
    expect(n.transaction).toBe('/dashboard')
    expect(n.serverName).toBe('web-01')
    expect(n.message).toContain('TypeError')
    expect(n.request).toEqual({
      url: 'https://acme.example/dashboard',
      method: 'GET',
      queryString: null, // redacted because it can carry tokens/PII
    })
    expect(n.user?.id).toBe('u_123')
    expect(n.user?.username).toBe('alice')
    expect(n.user?.email).toBeNull()
    expect(n.user?.ipAddress).toBeNull()
    expect(n.user?.geo).toEqual({ country_code: 'US', region: 'California', city: 'San Francisco' })
    expect(n.contexts.runtime).toEqual({ name: 'node', version: '20.11.0' })
    expect(n.contexts.trace?.trace_id).toBe('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
    expect(n.sdk).toEqual({ name: 'sentry.javascript.browser', version: '7.99.0' })
    expect(n.fingerprint).toEqual(['{{ default }}'])
    expect(n.extra.feature_flag).toBe('new-dashboard')
    expect(n.extra.retry_count).toBe('3')
    // Secret-looking extra keys are dropped.
    expect(n.extra.api_token).toBeUndefined()
  })

  it('keeps PII (email/ip/query) when redactPii is false', () => {
    const result = normalize('event_alert', fx('event_alert.json'), {
      dispatchId: DISPATCH_ID,
      redactPii: false,
    })
    if (result.kind !== 'normalized') throw new Error('expected normalized')
    const n = result.data
    expect(n.user?.email).toBe('alice@example.com')
    expect(n.user?.ipAddress).toBe('203.0.113.7')
    expect(n.request?.queryString).toBe('tab=overview&token=sekret')
  })

  it('exposes a Sentry issue API URL so downstream can fetch exact counts', () => {
    const result = normalize('event_alert', fx('event_alert.json'), {
      dispatchId: DISPATCH_ID,
    })
    if (result.kind !== 'normalized') throw new Error('expected normalized')
    expect(result.data.sentryApiIssueUrl).toBe(
      'https://sentry.io/api/0/organizations/acme/issues/WEB-4F2/',
    )
  })

  it('extracts aggregate counts when the event_alert payload nests an issue', () => {
    const payload = {
      action: 'triggered',
      data: {
        triggered_rule: 'High Priority Errors',
        issue: { count: 42, userCount: 7, firstSeen: '2025-04-01T00:00:00Z' },
        event: {
          event_id: 'e1',
          issue_id: 'WEB-9',
          title: 'boom',
          level: 'error',
          platform: 'javascript',
          project: { slug: 'web', organization_slug: 'acme' },
        },
      },
    }
    const result = normalize('event_alert', payload, { dispatchId: DISPATCH_ID })
    if (result.kind !== 'normalized') throw new Error('expected normalized')
    expect(result.data.count).toBe(42)
    expect(result.data.userCount).toBe(7)
    expect(result.data.firstSeen).toBe('2025-04-01T00:00:00Z')
  })
})

describe('normalize issue', () => {
  it('maps action=created to trigger=created', () => {
    const result = normalize('issue', fx('issue_created.json'), {
      dispatchId: DISPATCH_ID,
    })
    expect(result.kind).toBe('normalized')
    if (result.kind !== 'normalized') return
    expect(result.data.trigger).toBe('created')
    expect(result.data.projectSlug).toBe('web')
    expect(result.data.orgSlug).toBe('acme')
    expect(result.data.shortId).toBe('WEB-4F2')
    expect(result.data.issueId).toBe('1234567890')
    expect(result.data.count).toBe(3)
    expect(result.data.userCount).toBe(1)
    expect(result.data.firstSeen).toBe('2025-04-22T12:00:00Z')
    expect(result.data.topFrames).toEqual([])
    expect(result.data.breadcrumbs).toEqual([])
  })

  it('derives an exception and API URL from the issue metadata', () => {
    const result = normalize('issue', fx('issue_created.json'), {
      dispatchId: DISPATCH_ID,
    })
    if (result.kind !== 'normalized') throw new Error('expected normalized')
    expect(result.data.exception).toEqual({
      type: 'TypeError',
      value: 'Cannot read properties of undefined',
    })
    expect(result.data.isUnhandled).toBe(true)
    expect(result.data.sentryApiIssueUrl).toBe(
      'https://sentry.io/api/0/organizations/acme/issues/1234567890/',
    )
  })

  it('maps action=unresolved to trigger=regressed', () => {
    const result = normalize('issue', fx('issue_unresolved.json'), {
      dispatchId: DISPATCH_ID,
    })
    if (result.kind !== 'normalized') throw new Error('expected normalized')
    expect(result.data.trigger).toBe('regressed')
  })

  it('returns skip when the resource is unknown', () => {
    const result = normalize('unknown', {}, { dispatchId: DISPATCH_ID })
    expect(result).toEqual({ kind: 'skip', reason: 'unsupported_resource' })
  })

  it('returns skip when the payload is missing data', () => {
    const result = normalize('issue', { action: 'created' }, { dispatchId: DISPATCH_ID })
    expect(result.kind).toBe('skip')
  })

  it('maps assigned/archived actions to trigger=other', () => {
    const result = normalize(
      'issue',
      {
        action: 'assigned',
        data: {
          issue: {
            id: '1',
            shortId: 'X-1',
            title: 't',
            level: 'error',
            platform: 'node',
            project: { slug: 'web' },
            organization: { slug: 'acme' },
          },
        },
      },
      { dispatchId: DISPATCH_ID },
    )
    if (result.kind !== 'normalized') throw new Error('expected normalized')
    expect(result.data.trigger).toBe('other')
  })
})
