import { parseProjectMap, isTruthy } from './config.js'
import { verifySentryWebhook } from './signature.js'
import { normalize } from './normalize.js'
import { filter, isSelfReport } from './filter.js'
import { checkSeen, markSeen } from './dedup.js'
import { dispatchToGitHub } from './github.js'
import { createLogger } from './log.js'
import { reportToSentry, type SelfReport } from './selfReport.js'
import type { Decision, Env } from './types.js'

const SUPPORTED_RESOURCES = new Set(['event_alert', 'issue', 'metric_alert'])
// We only actively triage these.
const TRIAGED_RESOURCES = new Set(['event_alert', 'issue'])

const MAX_BODY_BYTES = 1024 * 1024 // 1 MB

export type HandlerDeps = {
  // Allows tests to inject a fake fetch for the GitHub call.
  fetchFn?: typeof fetch
  now?: () => number
  randomUUID?: () => string
}

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

function uuid(fn?: () => string): string {
  return fn ? fn() : crypto.randomUUID()
}

export async function handleRequest(
  request: Request,
  env: Env,
  ctx: ExecutionContext | undefined,
  deps: HandlerDeps = {},
): Promise<Response> {
  const log = createLogger(env.LOG_LEVEL)
  const url = new URL(request.url)
  const requestId = uuid(deps.randomUUID)
  const startedAt = deps.now ? deps.now() : Date.now()
  const reportFailure = (report: SelfReport): void => {
    const p = reportToSentry(env.SENTRY_DSN, report, deps.fetchFn)
    ctx?.waitUntil(p)
  }

  if (url.pathname === '/health' && request.method === 'GET') {
    return new Response('ok', { status: 200 })
  }

  if (url.pathname !== '/sentry/webhook') {
    return new Response('not found', { status: 404 })
  }

  if (request.method !== 'POST') {
    return new Response('method not allowed', { status: 405 })
  }

  const contentType = request.headers.get('content-type') ?? ''
  if (!contentType.toLowerCase().includes('application/json')) {
    return new Response('unsupported media type', { status: 415 })
  }

  const contentLength = request.headers.get('content-length')
  if (contentLength && Number(contentLength) > MAX_BODY_BYTES) {
    return new Response('payload too large', { status: 413 })
  }

  const rawBody = await request.text()
  if (new TextEncoder().encode(rawBody).length > MAX_BODY_BYTES) {
    return new Response('payload too large', { status: 413 })
  }

  const resource = request.headers.get('sentry-hook-resource')
  const timestamp = request.headers.get('sentry-hook-timestamp')
  const signature = request.headers.get('sentry-hook-signature')
  if (!resource || !timestamp || !signature) {
    log('warn', { requestId, decision: 'rejected', reason: 'missing_headers' })
    return new Response('bad request', { status: 400 })
  }

  const now = deps.now ? deps.now() : Date.now()
  const verify = await verifySentryWebhook({
    secret: env.SENTRY_CLIENT_SECRET ?? '',
    rawBody,
    signatureHeader: signature,
    timestampHeader: timestamp,
    now,
  })
  if (!verify.ok) {
    const reason = verify.reason
    const status = reason === 'missing_signature' || reason === 'missing_timestamp' ? 400 : 401
    log('warn', { requestId, decision: 'rejected', reason })
    return new Response('unauthorized', { status })
  }

  if (!SUPPORTED_RESOURCES.has(resource)) {
    log('info', { requestId, decision: 'filtered', reason: 'unsupported_resource', resource })
    return jsonResponse(200, { dispatchId: requestId, status: 'filtered', reason: 'unsupported_resource' })
  }

  if (!TRIAGED_RESOURCES.has(resource)) {
    // metric_alert and friends: accept-ignore.
    log('info', { requestId, decision: 'filtered', reason: 'not_triaged', resource })
    return jsonResponse(200, { dispatchId: requestId, status: 'filtered', reason: 'not_triaged' })
  }

  let parsed: unknown
  try {
    parsed = JSON.parse(rawBody)
  } catch {
    log('warn', { requestId, decision: 'rejected', reason: 'bad_json' })
    return new Response('bad request', { status: 400 })
  }

  const redactPii = isTruthy(env.REDACT_PII, true)
  const allowWarningsGlobal = isTruthy(env.ALLOW_WARNINGS_GLOBAL, false)
  const dispatchId = uuid(deps.randomUUID)
  const norm = normalize(resource, parsed, { dispatchId, redactPii })
  if (norm.kind === 'skip') {
    log('info', {
      requestId,
      dispatchId,
      decision: 'filtered',
      reason: `normalize_${norm.reason}`,
      resource,
    })
    return jsonResponse(200, { dispatchId, status: 'filtered', reason: norm.reason })
  }

  const n = norm.data
  // Drop echoes of our own reports before anything below can fail and report
  // again (a broken PROJECT_MAP would otherwise re-report on every echo).
  if (isSelfReport(n)) {
    log('info', { requestId, dispatchId, decision: 'filtered', reason: 'self_report' })
    return jsonResponse(200, { dispatchId, status: 'filtered', reason: 'self_report' })
  }

  let projectMap
  try {
    projectMap = parseProjectMap(env.PROJECT_MAP)
  } catch (err) {
    log('error', { requestId, decision: 'rejected', reason: 'bad_project_map', err: (err as Error).message })
    reportFailure({ reason: 'bad_project_map', detail: (err as Error).message, extra: { requestId } })
    return new Response('server misconfigured', { status: 500 })
  }

  const projectConfig = projectMap[n.projectSlug]
  const filterResult = filter({
    normalized: n,
    projectConfig,
    allowWarningsGlobal,
  })
  if (!filterResult.pass) {
    log('info', {
      requestId,
      dispatchId,
      decision: 'filtered',
      reason: filterResult.reason,
      projectSlug: n.projectSlug,
      shortId: n.shortId,
    })
    return jsonResponse(200, { dispatchId, status: 'filtered', reason: filterResult.reason })
  }

  const seen = await checkSeen(env.SENTRY_SEEN, n.projectSlug, n.shortId)
  if (seen && n.trigger !== 'regressed') {
    log('info', {
      requestId,
      dispatchId,
      decision: 'deduped',
      projectSlug: n.projectSlug,
      shortId: n.shortId,
      priorDispatchId: seen.dispatchId,
    })
    return jsonResponse(200, { dispatchId, status: 'deduped' })
  }

  const token = env.GITHUB_PAT
  if (!token) {
    // GitHub App path not yet implemented here; explicit error so onboarding is obvious.
    log('error', {
      requestId,
      dispatchId,
      decision: 'rejected',
      reason: 'no_github_credentials',
    })
    reportFailure({ reason: 'no_github_credentials', detail: 'GITHUB_PAT is not set', extra: { requestId, dispatchId } })
    return new Response('server misconfigured', { status: 500 })
  }

  const dispatch = await dispatchToGitHub({
    token,
    projectConfig: projectConfig!,
    normalized: n,
    fetchFn: deps.fetchFn,
  })
  if (!dispatch.ok) {
    log('error', {
      requestId,
      dispatchId,
      decision: 'rejected',
      reason: 'github_dispatch_failed',
      ghStatus: dispatch.status,
      ghBody: dispatch.body.slice(0, 500),
      projectSlug: n.projectSlug,
      shortId: n.shortId,
    })
    reportFailure({
      reason: 'github_dispatch_failed',
      detail: `GitHub ${dispatch.status}`,
      fingerprintExtra: String(dispatch.status),
      extra: {
        requestId,
        dispatchId,
        ghStatus: dispatch.status,
        ghBody: dispatch.body.slice(0, 500),
        repo: projectConfig!.repo,
        projectSlug: n.projectSlug,
        shortId: n.shortId,
      },
    })
    return jsonResponse(502, { dispatchId, status: 'rejected', reason: 'github_dispatch_failed' })
  }

  const dispatchedAt = new Date(deps.now ? deps.now() : Date.now()).toISOString()
  await markSeen(env.SENTRY_SEEN, n.projectSlug, n.shortId, {
    dispatchId,
    dispatchedAt,
    trigger: n.trigger,
  })

  const durationMs = (deps.now ? deps.now() : Date.now()) - startedAt
  const decision: Decision = 'dispatched'
  log('info', {
    requestId,
    dispatchId,
    decision,
    resource,
    action: (parsed as { action?: string }).action ?? null,
    projectSlug: n.projectSlug,
    shortId: n.shortId,
    trigger: n.trigger,
    durationMs,
  })

  if (env.ANALYTICS) {
    try {
      env.ANALYTICS.writeDataPoint({
        blobs: [n.projectSlug, n.trigger],
        doubles: [durationMs],
        indexes: ['dispatched'],
      })
    } catch {
      // Analytics is best-effort.
    }
  }

  return jsonResponse(202, { dispatchId, status: 'dispatched' })
}
