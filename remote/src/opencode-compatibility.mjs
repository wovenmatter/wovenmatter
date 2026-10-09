// OpenCode v2 minor/patch releases are independently updatable; v1 is unsupported.
export const supportsOpenCodeVersion = version => typeof version === 'string'
  && /^2\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/.test(version)
export const normalizeOpenCodeVersion = output => String(output).trim().replace(/^opencode2? v/, '')
export const openCodeCommands = ['opencode', 'opencode2']
