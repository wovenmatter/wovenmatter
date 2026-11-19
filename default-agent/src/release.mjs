// The Woven Matter release this agent shipped in, for the `version` that MCP
// and ACP make every client and server state about itself. Whatever starts the
// agent says so in WOVENMATTER_RELEASE_VERSION; a checkout has none.
export const releaseName = (environment = process.env) => environment.WOVENMATTER_RELEASE_VERSION || 'development';
