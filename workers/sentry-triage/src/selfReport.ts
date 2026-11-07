// Reports the Worker's own failures to Sentry with a dependency-free envelope
// POST. A Worker that answers Sentry with a 502 is not an error as far as
// Cloudflare is concerned, so without this a dead GITHUB_PAT goes unnoticed.
//
// Feedback loop: the self-report lands in the same Sentry project whose alert
// rule calls this Worker. Every self-report carries SELF_REPORT_TAG and starts
// with SELF_REPORT_PREFIX, and `filter` drops anything bearing either, so an
// echo is never dispatched and can never fail into a second report. The fixed
// fingerprint also groups every repeat of one failure into a single issue.

export const SELF_REPORT_PREFIX = '[sentry-triage]'
export const SELF_REPORT_TAG = 'sentry_triage.self_report'

const MAX_DETAIL = 500

export type SelfReport = {
  reason: string
  detail?: string
  extra?: Record<string, unknown>
  fingerprintExtra?: string
}

type ParsedDsn = { envelopeUrl: string; publicKey: string }

function parseDsn(dsn: string): ParsedDsn | null {
  try {
    const u = new URL(dsn)
    const projectId = u.pathname.replace(/^\/+|\/+$/g, '')
    if (!u.username || !projectId) return null
    return {
      envelopeUrl: `${u.protocol}//${u.host}/api/${projectId}/envelope/`,
      publicKey: u.username,
    }
  } catch {
    return null
  }
}

function logError(fields: Record<string, unknown>): void {
  // eslint-disable-next-line no-console
  console.log(JSON.stringify({ level: 'error', ts: new Date().toISOString(), ...fields }))
}

function truncateDetail(s: string): string {
  return s.length > MAX_DETAIL ? s.slice(0, MAX_DETAIL) : s
}

export async function reportToSentry(
  dsn: string | undefined,
  report: SelfReport,
  fetchFn: typeof fetch = fetch,
): Promise<void> {
  if (!dsn) {
    logError({ msg: 'sentry_dsn_unset', reason: report.reason, note: 'failure not reported to Sentry' })
    return
  }
  const parsed = parseDsn(dsn)
  if (!parsed) {
    logError({ msg: 'sentry_dsn_invalid', reason: report.reason })
    return
  }
  const eventId = crypto.randomUUID().replace(/-/g, '')
  const message = report.detail
    ? `${SELF_REPORT_PREFIX} ${report.reason}: ${truncateDetail(report.detail)}`
    : `${SELF_REPORT_PREFIX} ${report.reason}`
  const event = {
    event_id: eventId,
    timestamp: Date.now() / 1000,
    level: 'error',
    platform: 'javascript',
    logger: 'sentry-triage',
    server_name: 'sentry-triage-worker',
    message,
    tags: { [SELF_REPORT_TAG]: 'true', reason: report.reason },
    extra: report.extra ?? {},
    fingerprint: ['sentry-triage', report.reason, ...(report.fingerprintExtra ? [report.fingerprintExtra] : [])],
  }
  const body = [
    JSON.stringify({ event_id: eventId, sent_at: new Date().toISOString() }),
    JSON.stringify({ type: 'event' }),
    JSON.stringify(event),
  ].join('\n')
  try {
    const res = await fetchFn(parsed.envelopeUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-sentry-envelope',
        'X-Sentry-Auth': `Sentry sentry_version=7, sentry_key=${parsed.publicKey}, sentry_client=sentry-triage/1.0`,
      },
      body,
    })
    if (!res.ok) {
      logError({ msg: 'sentry_self_report_failed', reason: report.reason, sentryStatus: res.status })
    }
  } catch (err) {
    // Runs inside waitUntil; nothing upstream to rethrow to, so log loudly.
    logError({ msg: 'sentry_self_report_failed', reason: report.reason, err: (err as Error).message })
  }
}
