// Only use a relocation returned by the authenticated previous central or its
// scoped management capability. Ordinary HTTP redirects remain forbidden.
export function libraryRelocationEndpoint(value, libraryID) {
  const relocation=value?.relocation??value
  const uuid=value=>typeof value==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)
  if(relocation?.previousLibraryID!==libraryID||typeof relocation.transferID!=='string'
    ||!uuid(relocation.transferID)||!uuid(relocation.libraryID))throw Error('Invalid library relocation identity.')
  const endpoint=new URL(relocation.endpoint)
  if(endpoint.protocol!=='https:'||!endpoint.hostname.endsWith('.ts.net')||endpoint.username||endpoint.password
    ||endpoint.search||endpoint.hash||endpoint.pathname!=='/wovenmatter')throw Error('Invalid private library relocation endpoint.')
  return endpoint.href.replace(/\/$/,'')
}
