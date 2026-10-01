// Model-menu product copy is separate from connection/status names and auth modes.
const modelConnectionNames = {
  'openai-codex': 'ChatGPT subscription',
  openai: 'OpenAI subscription',
  openrouter: 'OpenRouter subscription',
  'opencode-go': 'OpenCode Go',
  xai: 'Grok subscription',
  'xai-api': 'XAI subscription',
  'claude-subscription': 'Claude subscription',
  anthropic: 'Anthropic subscription',
};

export function modelOption(model) {
  return {
    value: model.id,
    name: `${model.name} · ${modelConnectionNames[model.provider] ?? model.providerName}`,
    // Keep the actual connection route available when menu titles coincide.
    description: model.providerName,
    _meta: { modelName: model.name },
  };
}

// Match Claude Code's presentation: use the version reported for this family,
// without replacing the selectable alias or guessing a version for cold caches.
export function claudeModelName(model) {
  const base = model.value.replace(/\[1m\]$/, '').replace(/^claude-/, '');
  const family = base.match(/^[a-z]+/i)?.[0];
  if (!family || base === 'default') return model.displayName;
  const title = family[0].toUpperCase() + family.slice(1).toLowerCase();
  // Prefer the canonical SDK resolution over potentially older display prose.
  // A dated suffix is a release date, never an extra component of the version.
  const resolvedPattern = new RegExp(`^claude-${family}-(\\d+(?:[-.]\\d{1,2})?)(?:-\\d{8})?(?:\\[1m\\])?$`, 'i');
  const resolved = typeof model.resolvedModel === 'string' ? model.resolvedModel : model.value;
  const version = resolved.match(resolvedPattern)?.[1];
  if (version) return `${title} ${version.replace('-', '.')}`;
  const versionPattern = new RegExp(`\\b${family}\\s+(\\d+(?:\\.\\d+)*)\\b`, 'i');
  for (const text of [model.displayName, model.description]) {
    const version = typeof text === 'string' && text.match(versionPattern)?.[1];
    if (version) return `${title} ${version}`;
  }
  return model.displayName;
}
