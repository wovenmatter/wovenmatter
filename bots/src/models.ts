import { tmpdir } from "node:os";
import { join } from "node:path";
import type { CredentialStore, MutableModels, Provider } from "@earendil-works/pi-ai";
import { createModels } from "@earendil-works/pi-ai/models";
import { anthropicProvider } from "@earendil-works/pi-ai/providers/anthropic";
import { openaiProvider } from "@earendil-works/pi-ai/providers/openai";
import { openaiCodexProvider } from "@earendil-works/pi-ai/providers/openai-codex";
import { opencodeGoProvider } from "@earendil-works/pi-ai/providers/opencode-go";
import { openrouterProvider } from "@earendil-works/pi-ai/providers/openrouter";
import { xaiProvider } from "@earendil-works/pi-ai/providers/xai";
import { claudeAgentProvider } from "./claude/provider.ts";
import type { ClaudeAgentOptions } from "./claude/runtime.ts";
import type { ModelRef } from "./config.ts";

export type BotModelsOptions = {
  /** The Claude Agent SDK runtime; `directory` defaults to a per-user temp dir (app: the data dir). */
  readonly claude?: Partial<ClaudeAgentOptions>;
};

/**
 * Woven keeps the xAI subscription (`xai`, OAuth) and the xAI API key (`xai-api`) as separate
 * connections, as the default agent does: `xai-api` is pi-ai's xAI provider with key auth only.
 */
function xaiApiProvider(): Provider {
  const xai = xaiProvider();
  const relabel = <T extends { provider: string }>(model: T): T => ({ ...model, provider: "xai-api" });
  return {
    ...xai,
    id: "xai-api",
    name: "xAI API key",
    auth: { apiKey: xai.auth.apiKey } as Provider["auth"],
    getModels: () => xai.getModels().map(relabel),
    getAllModels: () => (xai.getAllModels?.() ?? xai.getModels()).map(relabel),
    refreshModels: undefined,
  } as Provider;
}

/**
 * pi-ai models for every bot. Request auth resolves through `credentials` (the host API: provider
 * connections in Woven settings). `claude-subscription` is Claude through the Claude Agent SDK.
 */
export function createBotModels(
  credentials: CredentialStore,
  options: BotModelsOptions = {},
): MutableModels {
  const models = createModels({ credentials });
  models.setProvider(openaiProvider());
  models.setProvider(openaiCodexProvider());
  models.setProvider(anthropicProvider());
  models.setProvider(openrouterProvider());
  models.setProvider(xaiProvider());
  models.setProvider(xaiApiProvider());
  models.setProvider(opencodeGoProvider());
  models.setProvider(
    claudeAgentProvider({
      ...options.claude,
      directory:
        options.claude?.directory ??
        join(tmpdir(), `woven-bots-claude-agent-${process.getuid?.() ?? "user"}`),
    }),
  );
  return models;
}

/** Problems with the configured roles, for startup warnings (unknown provider or model). */
export function checkModelRoles(models: MutableModels, roles: Record<string, ModelRef>): string[] {
  const problems: string[] = [];
  for (const [role, ref] of Object.entries(roles)) {
    if (!models.getProvider(ref.provider)) {
      problems.push(`models.${role}: unknown provider "${ref.provider}"`);
    } else if (!models.getModel(ref.provider, ref.modelId)) {
      problems.push(`models.${role}: provider "${ref.provider}" has no model "${ref.modelId}"`);
    }
  }
  return problems;
}
