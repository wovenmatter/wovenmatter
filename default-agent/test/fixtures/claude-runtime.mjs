export const fakeClaudeRuntime = (overrides = {}) => ({ models: [], loadModels: async () => {}, withProfile: (_, operation) => operation(), ...overrides });
