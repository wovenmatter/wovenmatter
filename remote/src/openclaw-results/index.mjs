import { createResultStore } from './store.mjs'

export default {
  id: 'wovenmatter-scheduled-results',
  name: 'Woven Matter scheduled results',
  register(api) {
    const store = createResultStore(api.pluginConfig.directory)
    const capture = callback => (...args) => {
      try { callback(...args) }
      catch {
        try { store.recordFailure() } catch { /* Disk failure is also reported in the native log. */ }
        api.logger.error('Woven Matter could not retain a scheduled result. Check host storage.')
      }
    }
    api.on('agent_end', capture(store.captureAgent))
    api.on('cron_changed', capture(store.captureCron))
    for (const [name, method, scope] of [
      ['list', store.list, 'operator.read'],
      ['output', store.output, 'operator.read'],
      ['ack', store.acknowledge, 'operator.write'],
    ]) {
      api.registerGatewayMethod(`wovenmatter.results.${name}`, ({ params, respond }) => {
        try { respond(true, method(params)) }
        catch { respond(false, undefined, { code: 'UNAVAILABLE', message: 'Scheduled result storage is unavailable or the request is invalid.' }) }
      }, { scope })
    }
  },
}
