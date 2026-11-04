import { randomUUID } from 'node:crypto'

export function enroll(service, extra = {}) {
  const enrollment = { libraryID: randomUUID(), workspaceID: randomUUID(), ownerDeviceID: randomUUID(), deviceID: randomUUID(), scopes: ['execution'], ...extra }
  const grant = service.provision(enrollment)
  return { enrollment, grant, principal: service.principal('Bearer ' + grant.token, 'execution') }
}
