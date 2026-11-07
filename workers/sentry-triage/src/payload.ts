import type { Normalized } from './types.js'

// The dispatcher wraps the normalized object into `{ shortId, data }`, where
// `data` is the stringified payload. GitHub rejects a `repository_dispatch`
// whose `client_payload` exceeds ~10 KB with a 422 ("client_payload is too
// large"). We measure the *actual* serialized client_payload (post-escaping)
// rather than estimating from the pre-escape object, and keep a small margin
// under the cap.
export const MAX_CLIENT_PAYLOAD_BYTES = 9500

const CORE_TAG_WHITELIST = [
  'environment',
  'release',
  'transaction',
  'url',
  'runtime',
  'runtime.name',
  'browser',
  'browser.name',
  'os',
  'os.name',
  'level',
  'handled',
  'mechanism',
]

const CORE_CONTEXTS = ['trace', 'runtime', 'os', 'browser']

// Build the exact object handed to GitHub as `client_payload`. Kept here (and
// reused by the dispatcher) so size measurement matches what's actually sent.
export function buildClientPayload(n: Normalized): { shortId: string; data: string } {
  return { shortId: n.shortId, data: JSON.stringify(n) }
}

function clientPayloadBytes(n: Normalized): number {
  return new TextEncoder().encode(JSON.stringify(buildClientPayload(n))).length
}

function stripContextLines(n: Normalized): Normalized {
  return {
    ...n,
    topFrames: n.topFrames.map((f) => ({ ...f, contextLine: null })),
  }
}

function restrictTags(n: Normalized, keys: string[]): Normalized {
  const keep: Record<string, string> = {}
  for (const k of keys) {
    const v = n.tags[k]
    if (typeof v === 'string') keep[k] = v
  }
  return { ...n, tags: keep }
}

function restrictContexts(n: Normalized, keep: string[]): Normalized {
  const out: Record<string, Record<string, string>> = {}
  for (const k of keep) {
    if (n.contexts[k]) out[k] = n.contexts[k]!
  }
  return { ...n, contexts: out }
}

// Progressively shrink until the serialized client_payload is under budget.
// Order sheds the least decision-relevant data first; aggregate counts, the
// exception, IDs, and URLs are never dropped.
export function fitClientPayload(n: Normalized): Normalized {
  let out = n
  if (clientPayloadBytes(out) <= MAX_CLIENT_PAYLOAD_BYTES) return out

  // 1. Drop free-form extra blob.
  out = { ...out, extra: {} }
  if (clientPayloadBytes(out) <= MAX_CLIENT_PAYLOAD_BYTES) return out

  // 2. Drop breadcrumbs.
  out = { ...out, breadcrumbs: [] }
  if (clientPayloadBytes(out) <= MAX_CLIENT_PAYLOAD_BYTES) return out

  // 3. Reduce contexts to a core set.
  out = restrictContexts(out, CORE_CONTEXTS)
  if (clientPayloadBytes(out) <= MAX_CLIENT_PAYLOAD_BYTES) return out

  // 4. Reduce topFrames to 5.
  out = { ...out, topFrames: out.topFrames.slice(0, 5) }
  if (clientPayloadBytes(out) <= MAX_CLIENT_PAYLOAD_BYTES) return out

  // 5. Whitelist tags to a small core set.
  out = restrictTags(out, CORE_TAG_WHITELIST)
  if (clientPayloadBytes(out) <= MAX_CLIENT_PAYLOAD_BYTES) return out

  // 6. Reduce topFrames to 3.
  out = { ...out, topFrames: out.topFrames.slice(0, 3) }
  if (clientPayloadBytes(out) <= MAX_CLIENT_PAYLOAD_BYTES) return out

  // 7. Drop remaining contexts and fingerprint.
  out = { ...out, contexts: {}, fingerprint: [] }
  if (clientPayloadBytes(out) <= MAX_CLIENT_PAYLOAD_BYTES) return out

  // 8. Strip contextLine on frames.
  out = stripContextLines(out)
  if (clientPayloadBytes(out) <= MAX_CLIENT_PAYLOAD_BYTES) return out

  // Last resort: truncate long strings. Never drop URLs or IDs.
  const truncate = (s: string | null, max: number): string | null =>
    s === null ? null : s.length > max ? s.slice(0, max) : s
  out = {
    ...out,
    title: truncate(out.title, 500) ?? out.title,
    culprit: truncate(out.culprit, 500),
    message: truncate(out.message, 500),
    exception: out.exception
      ? {
          type: truncate(out.exception.type, 200) ?? '',
          value: truncate(out.exception.value, 500) ?? '',
        }
      : null,
  }
  return out
}
