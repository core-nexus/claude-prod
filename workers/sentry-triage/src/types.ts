export type Trigger =
  | 'created'
  | 'regressed'
  | 'escalated'
  | 'event_alert'
  | 'other'

export type Level = 'fatal' | 'error' | 'warning' | 'info' | 'debug'

export type Frame = {
  filename: string | null
  function: string | null
  lineNo: number | null
  colNo: number | null
  inApp: boolean
  contextLine: string | null
}

export type Breadcrumb = {
  category: string | null
  level: string | null
  message: string | null
  timestamp: string | null
}

export type SentryRequest = {
  url: string | null
  method: string | null
  queryString: string | null
}

export type SentryUser = {
  id: string | null
  username: string | null
  email: string | null
  ipAddress: string | null
  geo: Record<string, string> | null
}

export type Sdk = {
  name: string | null
  version: string | null
}

export type Normalized = {
  projectSlug: string
  orgSlug: string
  shortId: string
  issueId: string
  title: string
  culprit: string | null
  message: string | null
  level: Level
  platform: string
  environment: string | null
  release: string | null
  transaction: string | null
  serverName: string | null
  firstSeen: string | null
  lastSeen: string | null
  count: number | null
  userCount: number | null
  issueType: string | null
  issueCategory: string | null
  isUnhandled: boolean | null
  sentryIssueUrl: string
  sentryEventUrl: string | null
  sentryApiEventUrl: string | null
  sentryApiIssueUrl: string | null
  latestEventId: string | null
  triggeredRule: string | null
  trigger: Trigger
  exception: { type: string; value: string } | null
  topFrames: Frame[]
  breadcrumbs: Breadcrumb[]
  tags: Record<string, string>
  request: SentryRequest | null
  user: SentryUser | null
  contexts: Record<string, Record<string, string>>
  sdk: Sdk | null
  fingerprint: string[]
  extra: Record<string, string>
  dispatchId: string
}

export type ProjectConfig = {
  repo: string
  eventType: string
  minEventCount?: number
  allowWarnings?: boolean
}

export type ProjectMap = Record<string, ProjectConfig>

export type Env = {
  SENTRY_SEEN?: KVNamespace
  ANALYTICS?: AnalyticsEngineDataset
  SENTRY_CLIENT_SECRET: string
  PROJECT_MAP: string
  GITHUB_APP_ID?: string
  GITHUB_APP_PRIVATE_KEY?: string
  GITHUB_PAT?: string
  SENTRY_DSN?: string
  REDACT_PII?: string
  ALLOW_WARNINGS_GLOBAL?: string
  LOG_LEVEL?: string
}

export type Decision = 'dispatched' | 'filtered' | 'deduped' | 'rejected'
