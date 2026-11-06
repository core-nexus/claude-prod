import { afterEach, describe, expect, it, vi } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import worker from '../src/index.js'
import { handleRequest } from '../src/handler.js'
import { hmacSha256Hex } from '../src/signature.js'
import { SELF_REPORT_PREFIX, SELF_REPORT_TAG } from '../src/selfReport.js'
import type { Env } from '../src/types.js'

const here = dirname(fileURLToPath(import.meta.url))
const fixture = (name: string): string => readFileSync(join(here, 'fixtures', name), 'utf8')

const SECRET = 'shh-its-a-secret'
const NOW_MS = 1_745_323_200_000
const TS_SECONDS = String(NOW_MS / 1000)
const TOKEN = 'test-github-token-must-never-leak'
const DSN = 'https://abc123pub@o0.ingest.sentry.example/1'
const ENVELOPE_URL = 'https://o0.ingest.sentry.example/api/1/envelope/'

function baseEnv(): Env {
  return {
    SENTRY_CLIENT_SECRET: SECRET,
    PROJECT_MAP: JSON.stringify({
      web: { repo: 'acme/web', eventType: 'sentry-triage' },
    }),
    GITHUB_PAT: TOKEN,
    SENTRY_DSN: DSN,
    LOG_LEVEL: 'error',
  }
}

// ExecutionContext is the Workers runtime boundary; this fake records
// waitUntil promises so the test can await the background Sentry report.
function fakeCtx(): ExecutionContext & { settle: () => Promise<unknown> } {
  const pending: Promise<unknown>[] = []
  return {
    waitUntil: (p: Promise<unknown>) => {
      pending.push(p)
    },
    passThroughOnException: () => {},
    props: {},
    settle: () => Promise.all(pending),
  } as unknown as ExecutionContext & { settle: () => Promise<unknown> }
}

type FetchCall = { url: string; init: RequestInit | undefined }

// Stub for the two external services: GitHub answers with `ghStatus`,
// Sentry's ingest always accepts.
function externalFetch(ghStatus: number, ghBody = '') {
  const calls: FetchCall[] = []
  const fn: typeof fetch = async (url, init) => {
    calls.push({ url: String(url), init })
    if (String(url).startsWith('https://api.github.com/')) {
      return new Response(ghBody || null, { status: ghStatus })
    }
    return new Response('{}', { status: 200 })
  }
  const sentryCalls = () => calls.filter((c) => c.url.startsWith(ENVELOPE_URL))
  return { fn, calls, sentryCalls }
}

async function signedRequest(body: string, resource: string, ts = TS_SECONDS): Promise<Request> {
  const sig = await hmacSha256Hex(SECRET, body)
  return new Request('https://worker.example.com/sentry/webhook', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'sentry-hook-resource': resource,
      'sentry-hook-timestamp': ts,
      'sentry-hook-signature': sig,
    },
    body,
  })
}

function envelopeEvent(call: FetchCall): Record<string, any> {
  const lines = String(call.init?.body).split('\n')
  expect(JSON.parse(lines[1]!).type).toBe('event')
  return JSON.parse(lines[2]!)
}

afterEach(() => {
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
})

describe('self-report: GitHub dispatch failure', () => {
  it('reports a 401 from GitHub to Sentry without leaking the token', async () => {
    const ext = externalFetch(401, '{"message":"Bad credentials"}' + 'x'.repeat(2000))
    const ctx = fakeCtx()
    const req = await signedRequest(fixture('event_alert.json'), 'event_alert')
    const res = await handleRequest(req, baseEnv(), ctx, { fetchFn: ext.fn, now: () => NOW_MS })
    expect(res.status).toBe(502)
    await ctx.settle()

    const sent = ext.sentryCalls()
    expect(sent).toHaveLength(1)
    const headers = new Headers(sent[0]!.init?.headers)
    expect(headers.get('x-sentry-auth')).toContain('sentry_key=abc123pub')
    const event = envelopeEvent(sent[0]!)
    expect(event.level).toBe('error')
    expect(event.message.startsWith(SELF_REPORT_PREFIX)).toBe(true)
    expect(event.message).toContain('github_dispatch_failed')
    expect(event.tags[SELF_REPORT_TAG]).toBe('true')
    expect(event.extra.ghStatus).toBe(401)
    expect(event.extra.ghBody).toContain('Bad credentials')
    expect(event.extra.ghBody.length).toBeLessThanOrEqual(500)
    expect(event.fingerprint).toEqual(['sentry-triage', 'github_dispatch_failed', '401'])
    expect(String(sent[0]!.init?.body)).not.toContain(TOKEN)
  })

  it('does not delay the response: the report goes through ctx.waitUntil', async () => {
    const ext = externalFetch(500)
    const ctx = fakeCtx()
    const spy = vi.spyOn(ctx, 'waitUntil')
    const req = await signedRequest(fixture('event_alert.json'), 'event_alert')
    await handleRequest(req, baseEnv(), ctx, { fetchFn: ext.fn, now: () => NOW_MS })
    expect(spy).toHaveBeenCalledTimes(1)
  })

  it('logs at error level and sends nothing to Sentry when SENTRY_DSN is unset', async () => {
    const logs: string[] = []
    vi.spyOn(console, 'log').mockImplementation((line: string) => {
      logs.push(line)
    })
    const ext = externalFetch(401)
    const ctx = fakeCtx()
    const env = { ...baseEnv(), SENTRY_DSN: undefined }
    const req = await signedRequest(fixture('event_alert.json'), 'event_alert')
    const res = await handleRequest(req, env, ctx, { fetchFn: ext.fn, now: () => NOW_MS })
    await ctx.settle()
    expect(res.status).toBe(502)
    expect(ext.sentryCalls()).toHaveLength(0)
    const unset = logs.map((l) => JSON.parse(l)).find((l) => l.msg === 'sentry_dsn_unset')
    expect(unset).toMatchObject({ level: 'error', reason: 'github_dispatch_failed' })
  })
})

describe('self-report: misconfiguration', () => {
  it('reports no_github_credentials', async () => {
    const ext = externalFetch(204)
    const ctx = fakeCtx()
    const env = { ...baseEnv(), GITHUB_PAT: undefined }
    const req = await signedRequest(fixture('event_alert.json'), 'event_alert')
    const res = await handleRequest(req, env, ctx, { fetchFn: ext.fn, now: () => NOW_MS })
    await ctx.settle()
    expect(res.status).toBe(500)
    const sent = ext.sentryCalls()
    expect(sent).toHaveLength(1)
    expect(envelopeEvent(sent[0]!).message).toContain('no_github_credentials')
  })

  it('reports bad_project_map', async () => {
    const ext = externalFetch(204)
    const ctx = fakeCtx()
    const env = { ...baseEnv(), PROJECT_MAP: '{not json' }
    const req = await signedRequest(fixture('event_alert.json'), 'event_alert')
    const res = await handleRequest(req, env, ctx, { fetchFn: ext.fn, now: () => NOW_MS })
    await ctx.settle()
    expect(res.status).toBe(500)
    const sent = ext.sentryCalls()
    expect(sent).toHaveLength(1)
    expect(envelopeEvent(sent[0]!).message).toContain('bad_project_map')
  })
})

describe('self-report: unhandled exception in the Worker entrypoint', () => {
  it('reports the exception to Sentry and still answers 500', async () => {
    const ext = externalFetch(204)
    vi.stubGlobal('fetch', ext.fn)
    vi.spyOn(console, 'log').mockImplementation(() => {})
    // A request body stream that errors mid-read (e.g. the client dropped).
    const req = new Request('https://worker.example.com/sentry/webhook', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: new ReadableStream({
        start(controller) {
          controller.error(new Error('stream exploded'))
        },
      }),
      duplex: 'half',
    } as RequestInit)
    const ctx = fakeCtx()
    const env = baseEnv()
    const res = await worker.fetch(req, env, ctx)
    await ctx.settle()
    expect(res.status).toBe(500)
    const sent = ext.sentryCalls()
    expect(sent).toHaveLength(1)
    const event = envelopeEvent(sent[0]!)
    expect(event.message).toContain('unhandled_exception')
    expect(event.message).toContain('stream exploded')
    expect(event.tags[SELF_REPORT_TAG]).toBe('true')
  })
})

describe('self-report: feedback loop', () => {
  // The Worker's self-report lands in Sentry, whose alert rule fires the same
  // webhook back at the Worker. Build that echo from the event we actually sent.
  async function echoOfSelfReport(): Promise<Record<string, any>> {
    const ext = externalFetch(401)
    const ctx = fakeCtx()
    const req = await signedRequest(fixture('event_alert.json'), 'event_alert')
    await handleRequest(req, baseEnv(), ctx, { fetchFn: ext.fn, now: () => NOW_MS })
    await ctx.settle()
    return envelopeEvent(ext.sentryCalls()[0]!)
  }

  it('filters an event_alert echo of its own report: no dispatch, no new report', async () => {
    const sent = await echoOfSelfReport()
    // Real webhook shape from the fixture, with the self-report's identity.
    const echo = JSON.parse(fixture('event_alert.json'))
    echo.data.event = {
      ...echo.data.event,
      event_id: sent.event_id,
      title: sent.message,
      message: sent.message,
      exception: undefined,
      tags: Object.entries(sent.tags),
    }
    const ext = externalFetch(401)
    const ctx = fakeCtx()
    const req = await signedRequest(JSON.stringify(echo), 'event_alert')
    const res = await handleRequest(req, baseEnv(), ctx, { fetchFn: ext.fn, now: () => NOW_MS })
    await ctx.settle()
    expect(res.status).toBe(200)
    expect(await res.json()).toMatchObject({ status: 'filtered', reason: 'self_report' })
    expect(ext.calls).toHaveLength(0)
  })

  it('filters an echo of a bad_project_map report while the map is still broken', async () => {
    // The map is checked before filter() would see the echo; a broken map must
    // not turn every echo into a fresh bad_project_map report.
    const broken = { ...baseEnv(), PROJECT_MAP: '{not json' }
    const first = externalFetch(204)
    const firstCtx = fakeCtx()
    const firstReq = await signedRequest(fixture('event_alert.json'), 'event_alert')
    await handleRequest(firstReq, broken, firstCtx, { fetchFn: first.fn, now: () => NOW_MS })
    await firstCtx.settle()
    const sent = envelopeEvent(first.sentryCalls()[0]!)
    expect(sent.message).toContain('bad_project_map')

    const echo = JSON.parse(fixture('event_alert.json'))
    echo.data.event = {
      ...echo.data.event,
      event_id: sent.event_id,
      title: sent.message,
      message: sent.message,
      exception: undefined,
      tags: Object.entries(sent.tags),
    }
    const ext = externalFetch(204)
    const ctx = fakeCtx()
    const req = await signedRequest(JSON.stringify(echo), 'event_alert')
    const res = await handleRequest(req, broken, ctx, { fetchFn: ext.fn, now: () => NOW_MS })
    await ctx.settle()
    expect(await res.json()).toMatchObject({ status: 'filtered', reason: 'self_report' })
    expect(ext.calls).toHaveLength(0)
  })

  it('filters an issue-resource echo (title only, no tags) of its own report', async () => {
    const sent = await echoOfSelfReport()
    const echo = {
      action: 'created',
      data: {
        issue: {
          id: '999',
          shortId: 'WEB-SELF',
          title: sent.message,
          level: 'error',
          platform: 'javascript',
          project: { slug: 'web' },
          organization: { slug: 'acme' },
        },
      },
    }
    const ext = externalFetch(401)
    const ctx = fakeCtx()
    const req = await signedRequest(JSON.stringify(echo), 'issue')
    const res = await handleRequest(req, baseEnv(), ctx, { fetchFn: ext.fn, now: () => NOW_MS })
    await ctx.settle()
    expect(await res.json()).toMatchObject({ status: 'filtered', reason: 'self_report' })
    expect(ext.calls).toHaveLength(0)
  })
})
