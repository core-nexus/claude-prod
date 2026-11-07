import { describe, expect, it } from 'vitest'
import { dispatchToGitHub } from '../src/github.js'
import type { Normalized } from '../src/types.js'

function makeNormalized(): Normalized {
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
    environment: null,
    release: null,
    transaction: null,
    serverName: null,
    firstSeen: null,
    lastSeen: null,
    count: 1,
    userCount: null,
    issueType: null,
    issueCategory: null,
    isUnhandled: null,
    sentryIssueUrl: 'https://sentry.io/issues/1/',
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
  }
}

describe('dispatchToGitHub', () => {
  it('POSTs to the right URL with the right headers and body', async () => {
    let capturedUrl = ''
    let capturedInit: RequestInit | undefined
    const fakeFetch: typeof fetch = async (url, init) => {
      capturedUrl = String(url)
      capturedInit = init
      return new Response(null, { status: 204 })
    }
    const res = await dispatchToGitHub({
      token: 'ghp_testtoken',
      projectConfig: { repo: 'acme/web', eventType: 'sentry-triage' },
      normalized: makeNormalized(),
      fetchFn: fakeFetch,
    })
    expect(res.ok).toBe(true)
    if (res.ok) expect(res.status).toBe(204)
    expect(capturedUrl).toBe(
      'https://api.github.com/repos/acme/web/dispatches',
    )
    const headers = capturedInit?.headers as Record<string, string>
    expect(headers.Authorization).toBe('Bearer ghp_testtoken')
    expect(headers.Accept).toBe('application/vnd.github+json')
    expect(headers['X-GitHub-Api-Version']).toBe('2022-11-28')
    expect(headers['User-Agent']).toBe('sentry-triage-worker/1.0')
    const body = JSON.parse(String(capturedInit?.body))
    expect(body.event_type).toBe('sentry-triage')
    expect(body.client_payload.shortId).toBe('WEB-1')
    const data = JSON.parse(body.client_payload.data)
    expect(data.sentryIssueUrl).toBe('https://sentry.io/issues/1/')
  })

  it('honors a custom eventType', async () => {
    const fakeFetch: typeof fetch = async () => new Response(null, { status: 204 })
    let capturedBody = ''
    const capturingFetch: typeof fetch = async (_url, init) => {
      capturedBody = String(init?.body)
      return fakeFetch('')
    }
    await dispatchToGitHub({
      token: 'tok',
      projectConfig: { repo: 'acme/web', eventType: 'custom-event' },
      normalized: makeNormalized(),
      fetchFn: capturingFetch,
    })
    expect(JSON.parse(capturedBody).event_type).toBe('custom-event')
  })

  it('returns ok=false on non-2xx', async () => {
    const fakeFetch: typeof fetch = async () =>
      new Response('Unauthorized', { status: 401 })
    const res = await dispatchToGitHub({
      token: 'bad',
      projectConfig: { repo: 'acme/web', eventType: 'sentry-triage' },
      normalized: makeNormalized(),
      fetchFn: fakeFetch,
    })
    expect(res.ok).toBe(false)
    if (!res.ok) {
      expect(res.status).toBe(401)
      expect(res.body).toBe('Unauthorized')
    }
  })

  it('rejects a malformed repo', async () => {
    const res = await dispatchToGitHub({
      token: 'tok',
      projectConfig: { repo: 'bad-repo', eventType: 'sentry-triage' },
      normalized: makeNormalized(),
      fetchFn: async () => new Response(null, { status: 204 }),
    })
    expect(res.ok).toBe(false)
  })
})
