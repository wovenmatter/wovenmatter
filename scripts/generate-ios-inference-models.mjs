#!/usr/bin/env node
// Regenerate with the exact Pi AI version locked in default-agent/package-lock.json.
// This reads installed package metadata only; it never fetches provider catalogs or credentials.
import { writeFile } from 'node:fs/promises';
const root = new URL('../default-agent/node_modules/@earendil-works/pi-ai/dist/providers/', import.meta.url);
const entries = [['openai', 'openaiProvider'], ['openai-codex', 'openaiCodexProvider'], ['openrouter', 'openrouterProvider'],
  ['opencode-go', 'opencodeGoProvider'], ['anthropic', 'anthropicProvider'], ['xai', 'xaiProvider']];
const models = [];
for (const [id, factory] of entries) {
  const provider = await import(new URL(id + '.js', root));
  models.push(...provider[factory]().getModels());
}
models.push(...models.filter(model => model.provider === 'xai').map(model => ({ ...model, provider: 'xai-api', api: 'openai-responses', baseUrl: 'https://api.x.ai/v1' })));
// Subscription aliases are an offline picker hint. The authorized host's live catalog is authoritative.
models.push(...models.filter(model => model.provider === 'anthropic').map(model => ({ ...model, provider: 'claude-subscription', api: 'woven-claude-native', baseUrl: 'process://claude-native' })));
await writeFile(new URL('../ios/Sources/CompanionInference/Resources/models.json', import.meta.url), JSON.stringify(models, null, 2) + '\n');
console.log(`Generated ${models.length} iOS inference descriptors from the installed Pi AI SDK.`);
