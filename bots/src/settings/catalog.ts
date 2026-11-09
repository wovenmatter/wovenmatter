/**
 * Provider connections bots can use. They are Woven Matter connections (Settings → Connections),
 * with the same ids as the machine's default agent; the runtime only reads them through the host.
 */
export type AccountSpec = {
  /** Woven connection id, which is also the pi-ai provider id. */
  readonly id: string;
  readonly provider: string;
  readonly group: string;
  readonly label: string;
  readonly method: "oauth" | "api_key";
};

export const ACCOUNTS: readonly AccountSpec[] = [
  { id: "claude-subscription", provider: "claude-subscription", group: "Claude", label: "Claude · Subscription", method: "oauth" },
  { id: "anthropic", provider: "anthropic", group: "Claude", label: "Claude · API key", method: "api_key" },
  { id: "openai-codex", provider: "openai-codex", group: "OpenAI", label: "OpenAI · ChatGPT subscription", method: "oauth" },
  { id: "openai", provider: "openai", group: "OpenAI", label: "OpenAI · API key", method: "api_key" },
  { id: "xai", provider: "xai", group: "Grok (xAI)", label: "Grok subscription", method: "oauth" },
  { id: "xai-api", provider: "xai-api", group: "Grok (xAI)", label: "xAI · API key", method: "api_key" },
  { id: "openrouter", provider: "openrouter", group: "OpenRouter", label: "OpenRouter", method: "api_key" },
  { id: "opencode-go", provider: "opencode-go", group: "OpenCode Go", label: "OpenCode Go", method: "api_key" },
];

export type SearchProviderId = "exa" | "brave" | "firecrawl";

export const SEARCH_PROVIDERS: readonly (AccountSpec & { id: SearchProviderId })[] = [
  { id: "exa", provider: "exa", group: "Search", label: "Exa", method: "api_key" },
  { id: "brave", provider: "brave", group: "Search", label: "Brave Search", method: "api_key" },
  { id: "firecrawl", provider: "firecrawl", group: "Search", label: "Firecrawl", method: "api_key" },
];

export function findAccount(id: string): AccountSpec | undefined {
  return ACCOUNTS.find((entry) => entry.id === id) ?? SEARCH_PROVIDERS.find((entry) => entry.id === id);
}
