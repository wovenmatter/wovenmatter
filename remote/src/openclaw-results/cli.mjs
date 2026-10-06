import { createHash } from 'node:crypto'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { binding, bindGeneration, connect, shellInput } from './binding.mjs'

const key = value => createHash('sha256').update(value).digest('hex')
export function registerCLI(api, root) {
  const directory = sessionKey => join(root, 'cli', key(sessionKey))
  const runs = new Map()
  api.registerGatewayMethod('wovenmatter.cli.bind', ({ params, respond }) => {
    try {
      if (typeof params?.sessionKey !== 'string' || !params.sessionKey) throw new Error('Missing session key')
      const target = directory(params.sessionKey)
      connect(target, params.context)
      if (typeof params.inputID === 'string' && params.inputID) {
        // Native chat.send records this user input under its idempotency key.
        bindGeneration(target, params.inputID + ':user', params.context.captureID)
      }
      respond(true, { ready: true })
    } catch (error) { respond(false, undefined, { code: 'INVALID_REQUEST', message: error.message }) }
  }, { scope: 'operator.write' })
  api.on('before_prompt_build', (event, ctx) => {
    if (!ctx.sessionKey || !ctx.runId || !event.currentUserMessageId) return
    const target = directory(ctx.sessionKey)
    if (!existsSync(join(target, 'connection.json'))) return
    const identity = event.currentUserMessageId
    runs.set(ctx.sessionKey + ':' + ctx.runId, identity)
    // Observe native consumption only: no prompt, system or history mutation.
  })
  api.on('before_tool_call', (event, ctx) => {
    if (event.toolName !== 'exec' || !ctx.sessionKey || !ctx.runId) return
    const identity = runs.get(ctx.sessionKey + ':' + ctx.runId)
    if (!identity) return
    return { params: shellInput(event.params, binding(directory(ctx.sessionKey), identity)) }
  }, { matcher: ['exec'] })
  api.on('agent_end', (_, ctx) => { runs.delete(ctx.sessionKey + ':' + ctx.runId) })
}
