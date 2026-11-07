import type { Normalized, ProjectConfig } from './types.js'
import { SELF_REPORT_PREFIX, SELF_REPORT_TAG } from './selfReport.js'

export type FilterInput = {
  normalized: Normalized
  projectConfig: ProjectConfig | undefined
  allowWarningsGlobal: boolean
}

export type FilterResult =
  | { pass: true }
  | { pass: false; reason: string }

// The Worker's own failure reports echo back through the alert rule; never
// triage them, or a broken dispatch would feed itself (see selfReport.ts).
export function isSelfReport(n: Normalized): boolean {
  return n.tags[SELF_REPORT_TAG] === 'true' || n.title.startsWith(SELF_REPORT_PREFIX)
}

export function filter(input: FilterInput): FilterResult {
  const { normalized: n, projectConfig, allowWarningsGlobal } = input

  if (isSelfReport(n)) {
    return { pass: false, reason: 'self_report' }
  }

  if (!projectConfig) {
    return { pass: false, reason: 'unknown_project' }
  }

  if (n.trigger === 'other') {
    return { pass: false, reason: 'trigger_other' }
  }

  const allowWarnings = projectConfig.allowWarnings === true || allowWarningsGlobal === true
  if (n.level !== 'fatal' && n.level !== 'error') {
    if (!(n.level === 'warning' && allowWarnings)) {
      return { pass: false, reason: `level_${n.level}_not_allowed` }
    }
  }

  const minCount = projectConfig.minEventCount ?? 1
  const count = n.count ?? 1
  if (count < minCount) {
    return { pass: false, reason: `below_min_event_count` }
  }

  return { pass: true }
}
