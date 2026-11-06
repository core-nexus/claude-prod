import type { Normalized, ProjectConfig } from './types.js'
import { buildClientPayload, fitClientPayload } from './payload.js'

export type DispatchInput = {
  token: string
  projectConfig: ProjectConfig
  normalized: Normalized
  fetchFn?: typeof fetch
}

export type DispatchResult =
  | { ok: true; status: number }
  | { ok: false; status: number; body: string }

export async function dispatchToGitHub(input: DispatchInput): Promise<DispatchResult> {
  const { token, projectConfig, normalized } = input
  const fetchFn = input.fetchFn ?? fetch
  const [owner, repo] = projectConfig.repo.split('/')
  if (!owner || !repo) {
    return { ok: false, status: 0, body: `invalid repo "${projectConfig.repo}"` }
  }
  const url = `https://api.github.com/repos/${owner}/${repo}/dispatches`
  const fitted = fitClientPayload(normalized)
  // GitHub caps client_payload at 10 top-level properties. Keep shortId at
  // top-level (the workflow's GitHub Actions expressions read it directly)
  // and stuff everything else into a stringified JSON `data` field.
  const clientPayload = buildClientPayload(fitted)
  const body = JSON.stringify({
    event_type: projectConfig.eventType,
    client_payload: clientPayload,
  })
  const res = await fetchFn(url, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'sentry-triage-worker/1.0',
      'Content-Type': 'application/json',
    },
    body,
  })
  if (res.status >= 200 && res.status < 300) {
    return { ok: true, status: res.status }
  }
  const text = await res.text().catch(() => '')
  return { ok: false, status: res.status, body: text }
}
