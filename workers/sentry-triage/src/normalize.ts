import type {
  Breadcrumb,
  Frame,
  Level,
  Normalized,
  Sdk,
  SentryRequest,
  SentryUser,
  Trigger,
} from './types.js'

// Tags carry a lot of triage signal (feature flags, tenant ids, custom
// dimensions), so we forward all of them rather than a small whitelist —
// minus anything that looks like a secret, and minus PII when redaction is on.
const PII_TAG_KEYS = new Set([
  'user.email',
  'user.ip_address',
  'user.ip',
  'email',
  'ip',
  'ip_address',
])
const SENSITIVE_KEY_RE =
  /secret|token|password|passwd|api[_-]?key|apikey|auth|credential|cookie|session|private[_-]?key/i
const MAX_TAGS = 50
const MAX_TAG_VALUE = 200
// Contexts we forward verbatim (flattened to scalar string maps). Others are
// dropped to keep the payload focused and within GitHub's size cap.
const CONTEXT_WHITELIST = new Set([
  'trace',
  'runtime',
  'os',
  'browser',
  'device',
  'app',
  'gpu',
  'culture',
  'response',
  'profile',
  'replay',
])
const MAX_CONTEXT_KEYS = 16
const MAX_EXTRA_KEYS = 20
const MAX_EXTRA_VALUE = 300
const MAX_FINGERPRINT = 16

const VALID_LEVELS: ReadonlySet<Level> = new Set<Level>([
  'fatal',
  'error',
  'warning',
  'info',
  'debug',
])

export type NormalizeOptions = {
  dispatchId: string
  redactPii?: boolean
}

export class NormalizeError extends Error {}

function asString(v: unknown): string | null {
  return typeof v === 'string' && v.length > 0 ? v : null
}

function asNumber(v: unknown): number | null {
  if (typeof v === 'number' && Number.isFinite(v)) return v
  if (typeof v === 'string') {
    const n = Number(v)
    return Number.isFinite(n) ? n : null
  }
  return null
}

function asLevel(v: unknown): Level {
  if (typeof v === 'string' && VALID_LEVELS.has(v as Level)) return v as Level
  return 'error'
}

function truncate(s: string | null, n: number): string | null {
  if (s === null) return null
  return s.length > n ? s.slice(0, n) : s
}

type RawFrame = {
  filename?: unknown
  abs_path?: unknown
  function?: unknown
  lineno?: unknown
  colno?: unknown
  in_app?: unknown
  context_line?: unknown
}

function normalizeFrames(rawFrames: RawFrame[] | undefined): Frame[] {
  if (!Array.isArray(rawFrames) || rawFrames.length === 0) return []
  // Sentry orders frames from oldest → newest. We want the most recent first.
  const reversed = [...rawFrames].reverse()
  const mapFrame = (f: RawFrame): Frame => ({
    filename: asString(f.filename) ?? asString(f.abs_path),
    function: asString(f.function),
    lineNo: asNumber(f.lineno),
    colNo: asNumber(f.colno),
    inApp: f.in_app === true,
    contextLine: truncate(asString(f.context_line), 200),
  })
  const mapped = reversed.map(mapFrame)
  const inApp = mapped.filter((f) => f.inApp)
  if (inApp.length >= 10) return inApp.slice(0, 10)
  const rest = mapped.filter((f) => !f.inApp)
  return [...inApp, ...rest].slice(0, 10)
}

function extractFrames(event: Record<string, unknown> | null): Frame[] {
  if (!event) return []
  const exception = (event.exception ?? null) as Record<string, unknown> | null
  const values = (exception?.values ?? null) as Array<Record<string, unknown>> | null
  if (!values || values.length === 0) return []
  // Sentry convention: the last entry in values is the innermost exception.
  const last = values[values.length - 1]!
  const stacktrace = (last.stacktrace ?? null) as Record<string, unknown> | null
  const frames = (stacktrace?.frames ?? null) as RawFrame[] | null
  return normalizeFrames(frames ?? undefined)
}

function extractException(
  event: Record<string, unknown> | null,
): { type: string; value: string } | null {
  if (!event) return null
  const exception = (event.exception ?? null) as Record<string, unknown> | null
  const values = (exception?.values ?? null) as Array<Record<string, unknown>> | null
  if (!values || values.length === 0) return null
  const last = values[values.length - 1]!
  const type = asString(last.type)
  const value = asString(last.value)
  if (type === null && value === null) return null
  return { type: type ?? '', value: value ?? '' }
}

function extractBreadcrumbs(event: Record<string, unknown> | null): Breadcrumb[] {
  if (!event) return []
  const bc = (event.breadcrumbs ?? null) as Record<string, unknown> | Array<unknown> | null
  let values: Array<Record<string, unknown>> | null = null
  if (Array.isArray(bc)) {
    values = bc as Array<Record<string, unknown>>
  } else if (bc && typeof bc === 'object') {
    const v = (bc as Record<string, unknown>).values
    if (Array.isArray(v)) values = v as Array<Record<string, unknown>>
  }
  if (!values || values.length === 0) return []
  const last10 = values.slice(-10)
  return last10.map((b) => ({
    category: asString(b.category),
    level: asString(b.level),
    message: truncate(asString(b.message), 200),
    timestamp: (() => {
      if (typeof b.timestamp === 'number' && Number.isFinite(b.timestamp)) {
        return new Date(b.timestamp * 1000).toISOString()
      }
      return asString(b.timestamp)
    })(),
  }))
}

function isSensitiveKey(key: string, redactPii: boolean): boolean {
  if (SENSITIVE_KEY_RE.test(key)) return true
  if (redactPii && PII_TAG_KEYS.has(key)) return true
  return false
}

function scalarToString(v: unknown): string | null {
  if (typeof v === 'string') return v.length > 0 ? v : null
  if (typeof v === 'number' && Number.isFinite(v)) return String(v)
  if (typeof v === 'boolean') return String(v)
  return null
}

function extractTags(
  event: Record<string, unknown> | null,
  issue: Record<string, unknown> | null,
  redactPii: boolean,
): Record<string, string> {
  const out: Record<string, string> = {}
  const rawTags: unknown = event?.tags ?? issue?.tags ?? null
  const add = (k: unknown, v: unknown): void => {
    if (typeof k !== 'string' || k.length === 0) return
    if (Object.keys(out).length >= MAX_TAGS && !(k in out)) return
    const val = scalarToString(v)
    if (val === null) return
    if (isSensitiveKey(k, redactPii)) return
    out[k] = truncate(val, MAX_TAG_VALUE)!
  }
  if (Array.isArray(rawTags)) {
    for (const pair of rawTags) {
      if (Array.isArray(pair) && pair.length >= 2) {
        add(pair[0], pair[1])
      } else if (pair && typeof pair === 'object') {
        const p = pair as Record<string, unknown>
        add(p.key, p.value)
      }
    }
  } else if (rawTags && typeof rawTags === 'object') {
    for (const [k, v] of Object.entries(rawTags as Record<string, unknown>)) {
      add(k, v)
    }
  }
  return out
}

function extractMessage(event: Record<string, unknown> | null): string | null {
  if (!event) return null
  const direct = asString(event.message)
  if (direct) return truncate(direct, 500)
  const logentry = (event.logentry ?? null) as Record<string, unknown> | null
  if (logentry) {
    const formatted = asString(logentry.formatted) ?? asString(logentry.message)
    if (formatted) return truncate(formatted, 500)
  }
  return null
}

function extractRequest(
  event: Record<string, unknown> | null,
  redactPii: boolean,
): SentryRequest | null {
  if (!event) return null
  const req = (event.request ?? null) as Record<string, unknown> | null
  if (!req) return null
  const url = truncate(asString(req.url), 500)
  const method = asString(req.method)
  // Query strings frequently carry tokens/PII, so only forward them when
  // redaction is disabled.
  let queryString: string | null = null
  if (!redactPii) {
    const raw = req.query_string
    if (typeof raw === 'string') queryString = truncate(raw, 300)
    else if (Array.isArray(raw)) {
      const parts: string[] = []
      for (const pair of raw) {
        if (Array.isArray(pair) && pair.length >= 2) {
          const k = scalarToString(pair[0])
          const v = scalarToString(pair[1])
          if (k !== null) parts.push(v === null ? k : `${k}=${v}`)
        }
      }
      queryString = parts.length > 0 ? truncate(parts.join('&'), 300) : null
    }
  }
  if (url === null && method === null && queryString === null) return null
  return { url, method, queryString }
}

function extractUser(
  event: Record<string, unknown> | null,
  redactPii: boolean,
): SentryUser | null {
  if (!event) return null
  const user = (event.user ?? null) as Record<string, unknown> | null
  if (!user) return null
  let geo: Record<string, string> | null = null
  const rawGeo = (user.geo ?? null) as Record<string, unknown> | null
  if (rawGeo) {
    const g: Record<string, string> = {}
    for (const key of ['country_code', 'region', 'city', 'subdivision']) {
      const v = asString(rawGeo[key])
      if (v) g[key] = v
    }
    if (Object.keys(g).length > 0) geo = g
  }
  const out: SentryUser = {
    id: asString(user.id),
    username: asString(user.username),
    email: redactPii ? null : asString(user.email),
    ipAddress: redactPii ? null : (asString(user.ip_address) ?? asString(user.ip)),
    geo,
  }
  if (
    out.id === null &&
    out.username === null &&
    out.email === null &&
    out.ipAddress === null &&
    out.geo === null
  ) {
    return null
  }
  return out
}

function extractContexts(
  event: Record<string, unknown> | null,
): Record<string, Record<string, string>> {
  const out: Record<string, Record<string, string>> = {}
  if (!event) return out
  const contexts = (event.contexts ?? null) as Record<string, unknown> | null
  if (!contexts) return out
  for (const [name, value] of Object.entries(contexts)) {
    if (!CONTEXT_WHITELIST.has(name)) continue
    if (!value || typeof value !== 'object' || Array.isArray(value)) continue
    const flat: Record<string, string> = {}
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      if (k === 'type') continue
      if (Object.keys(flat).length >= MAX_CONTEXT_KEYS) break
      const s = scalarToString(v)
      if (s !== null) flat[k] = truncate(s, MAX_TAG_VALUE)!
    }
    if (Object.keys(flat).length > 0) out[name] = flat
  }
  return out
}

function extractSdk(event: Record<string, unknown> | null): Sdk | null {
  if (!event) return null
  const sdk = (event.sdk ?? null) as Record<string, unknown> | null
  if (!sdk) return null
  const name = asString(sdk.name)
  const version = asString(sdk.version)
  if (name === null && version === null) return null
  return { name, version }
}

function extractFingerprint(event: Record<string, unknown> | null): string[] {
  if (!event) return []
  const fp = event.fingerprint
  if (!Array.isArray(fp)) return []
  const out: string[] = []
  for (const part of fp) {
    const s = scalarToString(part)
    if (s !== null) out.push(truncate(s, MAX_TAG_VALUE)!)
    if (out.length >= MAX_FINGERPRINT) break
  }
  return out
}

function extractExtra(
  event: Record<string, unknown> | null,
  redactPii: boolean,
): Record<string, string> {
  const out: Record<string, string> = {}
  if (!event) return out
  const extra = (event.extra ?? null) as Record<string, unknown> | null
  if (!extra) return out
  for (const [k, v] of Object.entries(extra)) {
    if (Object.keys(out).length >= MAX_EXTRA_KEYS) break
    if (isSensitiveKey(k, redactPii)) continue
    let s: string | null
    if (typeof v === 'string') s = v
    else if (v === null || v === undefined) s = null
    else {
      try {
        s = JSON.stringify(v)
      } catch {
        s = null
      }
    }
    if (s === null || s.length === 0) continue
    out[k] = truncate(s, MAX_EXTRA_VALUE)!
  }
  return out
}

// Aggregate stats (times seen, users affected, first/last seen) live on
// Sentry's *issue* serializer, not the per-event one. Issue webhooks include
// them directly; event_alert webhooks usually don't, but newer payloads
// sometimes nest an `issue` object alongside the event — extract from wherever
// it shows up so we forward exact numbers whenever Sentry gives them to us.
function extractAggregate(
  ...sources: Array<Record<string, unknown> | null | undefined>
): { count: number | null; userCount: number | null; firstSeen: string | null; lastSeen: string | null } {
  let count: number | null = null
  let userCount: number | null = null
  let firstSeen: string | null = null
  let lastSeen: string | null = null
  for (const src of sources) {
    if (!src) continue
    count ??= asNumber(src.count)
    userCount ??= asNumber(src.userCount) ?? asNumber(src.user_count)
    firstSeen ??= asString(src.firstSeen) ?? asString(src.first_seen)
    lastSeen ??= asString(src.lastSeen) ?? asString(src.last_seen)
  }
  return { count, userCount, firstSeen, lastSeen }
}

function asBool(v: unknown): boolean | null {
  if (typeof v === 'boolean') return v
  return null
}

// Best-effort: derive {org, project} slugs from a Sentry URL like
// "https://<org>.sentry.io/organizations/<org>/issues/<id>/..."
// or "https://sentry.io/organizations/<org>/projects/<project>/..."
function slugsFromUrl(url: string | null): { orgSlug: string | null; projectSlug: string | null } {
  if (!url) return { orgSlug: null, projectSlug: null }
  try {
    const u = new URL(url)
    const parts = u.pathname.split('/').filter(Boolean)
    let orgSlug: string | null = null
    let projectSlug: string | null = null
    const orgIdx = parts.indexOf('organizations')
    if (orgIdx >= 0 && parts[orgIdx + 1]) orgSlug = parts[orgIdx + 1]!
    const projIdx = parts.indexOf('projects')
    if (projIdx >= 0 && parts[projIdx + 1]) {
      // API URL shape is /api/0/projects/{org}/{project}/..., so the slug
      // right after "projects" is the org and the one after is the project.
      // Web URL shape is /organizations/{org}/projects/{project}/..., so the
      // slug after "projects" is the project directly.
      const isApiUrl = parts[0] === 'api'
      if (isApiUrl) {
        if (!orgSlug) orgSlug = parts[projIdx + 1]!
        if (parts[projIdx + 2]) projectSlug = parts[projIdx + 2]!
      } else {
        projectSlug = parts[projIdx + 1]!
      }
    }
    // Fallback: subdomain like "<org>.sentry.io"
    if (!orgSlug) {
      const host = u.hostname
      if (host.endsWith('.sentry.io')) {
        const sub = host.slice(0, -'.sentry.io'.length)
        if (sub && sub !== 'www') orgSlug = sub
      }
    }
    return { orgSlug, projectSlug }
  } catch {
    return { orgSlug: null, projectSlug: null }
  }
}

function mapIssueAction(action: string | null): Trigger {
  switch (action) {
    case 'created':
      return 'created'
    case 'unresolved':
      return 'regressed'
    case 'escalating':
      return 'escalated'
    default:
      return 'other'
  }
}

export type NormalizeResult =
  | { kind: 'normalized'; data: Normalized }
  | { kind: 'skip'; reason: string }

export function normalize(
  resource: string,
  payload: unknown,
  opts: NormalizeOptions,
): NormalizeResult {
  if (resource !== 'event_alert' && resource !== 'issue') {
    return { kind: 'skip', reason: 'unsupported_resource' }
  }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    return { kind: 'skip', reason: 'payload_not_object' }
  }
  const root = payload as Record<string, unknown>
  const action = asString(root.action)
  const data = (root.data ?? null) as Record<string, unknown> | null
  if (!data) return { kind: 'skip', reason: 'missing_data' }

  const redactPii = opts.redactPii !== false

  if (resource === 'event_alert') {
    const event = (data.event ?? null) as Record<string, unknown> | null
    if (!event) return { kind: 'skip', reason: 'missing_event' }
    const issueUrl = asString(event.issue_url) ?? asString(event.web_url) ?? asString(event.url)
    const eventUrl = asString(event.web_url)
    const apiUrl = asString(event.url)
    const urlCandidates = [issueUrl, eventUrl, apiUrl]
    let orgFromUrl: string | null = null
    let projectFromUrl: string | null = null
    for (const candidate of urlCandidates) {
      const parsed = slugsFromUrl(candidate)
      orgFromUrl ??= parsed.orgSlug
      projectFromUrl ??= parsed.projectSlug
      if (orgFromUrl && projectFromUrl) break
    }
    const project = (event.project ?? null) as Record<string, unknown> | null
    const orgSlug =
      asString(root.actor ? (root.actor as Record<string, unknown>).organization_slug : null) ??
      asString(project?.organization_slug) ??
      orgFromUrl
    const projectSlug = asString(event.project_slug) ?? asString(project?.slug) ?? projectFromUrl
    if (!orgSlug || !projectSlug) {
      return { kind: 'skip', reason: 'missing_slugs' }
    }
    const shortId = asString(event.issue_id) ? asString(event.issue_id)! : asString(event.event_id)!
    const issueIdRaw =
      asString(event.issue_id) ??
      asString(event.groupID) ??
      asString((event.metadata as Record<string, unknown> | null)?.issue_id) ??
      ''
    const issueId = issueIdRaw
    const latestEventId = asString(event.event_id)
    const sentryIssueUrl =
      issueUrl ??
      `https://${orgSlug}.sentry.io/issues/${issueId || shortId}/`
    const sentryEventUrl =
      eventUrl ??
      (latestEventId
        ? `https://${orgSlug}.sentry.io/issues/${issueId || shortId}/events/${latestEventId}/`
        : null)
    const sentryApiEventUrl =
      latestEventId && projectSlug
        ? `https://sentry.io/api/0/projects/${orgSlug}/${projectSlug}/events/${latestEventId}/`
        : null
    const resolvedIssueId = issueId || shortId
    // So downstream can fetch exact frequency/affected-user counts that the
    // event_alert webhook does not include.
    const sentryApiIssueUrl = resolvedIssueId
      ? `https://sentry.io/api/0/organizations/${orgSlug}/issues/${resolvedIssueId}/`
      : null
    const dataIssue = (data.issue ?? null) as Record<string, unknown> | null
    const aggregate = extractAggregate(
      event,
      dataIssue,
      (event.metadata ?? null) as Record<string, unknown> | null,
    )
    const normalized: Normalized = {
      projectSlug,
      orgSlug,
      shortId: asString(event.issue_id) ?? shortId,
      issueId: resolvedIssueId,
      title: asString(event.title) ?? asString(event.message) ?? '(no title)',
      culprit: asString(event.culprit),
      message: extractMessage(event),
      level: asLevel(event.level),
      platform: asString(event.platform) ?? 'unknown',
      environment: asString(event.environment),
      release: asString(event.release),
      transaction: asString(event.transaction),
      serverName: asString(event.server_name),
      firstSeen: aggregate.firstSeen,
      lastSeen:
        aggregate.lastSeen ?? asString(event.datetime) ?? asString(event.received),
      count: aggregate.count,
      userCount: aggregate.userCount,
      issueType: asString(event.type),
      issueCategory: null,
      isUnhandled: asBool(event.unhandled) ?? asBool(dataIssue?.isUnhandled ?? null),
      sentryIssueUrl,
      sentryEventUrl,
      sentryApiEventUrl,
      sentryApiIssueUrl,
      latestEventId,
      triggeredRule: asString(data.triggered_rule),
      trigger: 'event_alert',
      exception: extractException(event),
      topFrames: extractFrames(event),
      breadcrumbs: extractBreadcrumbs(event),
      tags: extractTags(event, null, redactPii),
      request: extractRequest(event, redactPii),
      user: extractUser(event, redactPii),
      contexts: extractContexts(event),
      sdk: extractSdk(event),
      fingerprint: extractFingerprint(event),
      extra: extractExtra(event, redactPii),
      dispatchId: opts.dispatchId,
    }
    return { kind: 'normalized', data: normalized }
  }

  if (resource === 'issue') {
    const issue = (data.issue ?? null) as Record<string, unknown> | null
    if (!issue) return { kind: 'skip', reason: 'missing_issue' }
    const project = (issue.project ?? null) as Record<string, unknown> | null
    const organization = (issue.organization ?? null) as Record<string, unknown> | null
    const permalink = asString(issue.permalink) ?? asString(issue.web_url)
    const { orgSlug: orgFromUrl, projectSlug: projectFromUrl } = slugsFromUrl(permalink)
    const projectSlug = asString(project?.slug) ?? projectFromUrl
    const orgSlug = asString(organization?.slug) ?? orgFromUrl
    if (!orgSlug || !projectSlug) {
      return { kind: 'skip', reason: 'missing_slugs' }
    }
    const shortId = asString(issue.shortId) ?? asString(issue.short_id) ?? ''
    const issueId = asString(issue.id) ?? shortId
    if (!issueId) return { kind: 'skip', reason: 'missing_issue_id' }
    const trigger = mapIssueAction(action)
    const sentryIssueUrl =
      permalink ?? `https://${orgSlug}.sentry.io/issues/${issueId}/`
    const sentryApiIssueUrl = `https://sentry.io/api/0/organizations/${orgSlug}/issues/${issueId}/`
    // The issue serializer carries error type/value under `metadata`; surface
    // it as a structured exception so triage has the failure detail.
    const metadata = (issue.metadata ?? null) as Record<string, unknown> | null
    const metaType = asString(metadata?.type)
    const metaValue = asString(metadata?.value)
    const issueException =
      metaType !== null || metaValue !== null
        ? { type: metaType ?? '', value: metaValue ?? '' }
        : null
    const normalized: Normalized = {
      projectSlug,
      orgSlug,
      shortId: shortId || issueId,
      issueId,
      title: asString(issue.title) ?? '(no title)',
      culprit: asString(issue.culprit),
      message: metaValue ? truncate(metaValue, 500) : null,
      level: asLevel(issue.level),
      platform: asString(issue.platform) ?? asString(project?.platform) ?? 'unknown',
      environment: null,
      release: null,
      transaction: null,
      serverName: null,
      firstSeen: asString(issue.firstSeen) ?? asString(issue.first_seen),
      lastSeen: asString(issue.lastSeen) ?? asString(issue.last_seen),
      count: asNumber(issue.count),
      userCount: asNumber(issue.userCount) ?? asNumber(issue.user_count),
      issueType: asString(issue.type),
      issueCategory: asString(issue.issueCategory) ?? asString(issue.issue_category),
      isUnhandled: asBool(issue.isUnhandled) ?? asBool(metadata?.isUnhandled ?? null),
      sentryIssueUrl,
      sentryEventUrl: null,
      sentryApiEventUrl: null,
      sentryApiIssueUrl,
      latestEventId: null,
      triggeredRule: null,
      trigger,
      exception: issueException,
      topFrames: [],
      breadcrumbs: [],
      tags: extractTags(null, issue, redactPii),
      request: null,
      user: null,
      contexts: {},
      sdk: null,
      fingerprint: [],
      extra: {},
      dispatchId: opts.dispatchId,
    }
    return { kind: 'normalized', data: normalized }
  }

  return { kind: 'skip', reason: 'unsupported_resource' }
}
