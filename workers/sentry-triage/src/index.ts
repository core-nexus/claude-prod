import { handleRequest } from './handler.js'
import { reportToSentry } from './selfReport.js'
import type { Env } from './types.js'

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    try {
      return await handleRequest(request, env, ctx)
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      // eslint-disable-next-line no-console
      console.log(
        JSON.stringify({
          level: 'error',
          ts: new Date().toISOString(),
          msg: 'unhandled_exception',
          err: message,
        }),
      )
      ctx.waitUntil(
        reportToSentry(env.SENTRY_DSN, {
          reason: 'unhandled_exception',
          detail: message,
          extra: { stack: err instanceof Error ? err.stack : undefined },
        }),
      )
      return new Response('internal error', { status: 500 })
    }
  },
} satisfies ExportedHandler<Env>
