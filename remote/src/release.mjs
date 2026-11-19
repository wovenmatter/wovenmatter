// The Woven Matter release this server shipped in, for the `version` that MCP
// and ACP make every client and server state about itself. remote-host.sh
// sets it from the host bundle's manifest; a checkout has none and says so.
export const releaseName = (environment = process.env) => environment.WOVENMATTER_RELEASE_VERSION || 'development'
