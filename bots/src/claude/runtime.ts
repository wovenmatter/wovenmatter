import { accessSync, constants, statSync } from "node:fs";
import { chmod, lstat, mkdir } from "node:fs/promises";
import { delimiter, join } from "node:path";
import type { ClaudeCredential } from "./provider.ts";

/**
 * The Claude Agent SDK runtime: where Claude Code runs and with which environment. It runs the
 * Claude Code installed on this machine, found on PATH at each request. Credentials
 * come from the server: for a Claude subscription, Claude Code's own sign-in on this machine with
 * its default configuration (the runtime never reads it); for an API key, the key through the
 * SDK's environment and a private configuration directory.
 */

/** The parts of an SDK message the runtime reads. The SDK's own types are much wider. */
export type ClaudeSdkEvent = {
  readonly type: string;
  readonly subtype?: string;
  // biome-ignore lint/suspicious/noExplicitAny: SDK message payloads (Anthropic Messages JSON).
  readonly [key: string]: any;
};

/** A frame on the SDK's streaming input: a user message or a replayed assistant message. */
export type ClaudeSdkFrame = {
  readonly type: "user" | "assistant";
  // biome-ignore lint/suspicious/noExplicitAny: Anthropic Messages content blocks.
  readonly message: { readonly role: "user" | "assistant"; readonly content: any[] };
  readonly parent_tool_use_id: null;
  readonly session_id: string;
  readonly shouldQuery?: false;
  readonly client_composed?: true;
};

export type ClaudeSdkQuery = (params: {
  readonly prompt: AsyncIterable<ClaudeSdkFrame>;
  readonly options: Record<string, unknown>;
}) => AsyncIterable<ClaudeSdkEvent> & { close?(): void };

export type ClaudeAgentOptions = {
  /** Private runtime directory (mode 0700): the working directory, and the config dir for keys. */
  readonly directory: string;
  /** Replace the SDK's `query` (tests inject a fake; no Claude Code process starts). */
  readonly query?: ClaudeSdkQuery;
  /** Idle timeout per SDK request. Default 180 s, like Woven. */
  readonly timeoutMs?: number;
};

/** The installed Claude Code: the first executable `claude` on `path`. */
export function claudeExecutable(path = process.env.PATH ?? ""): string {
  for (const folder of path.split(delimiter)) {
    if (!folder) continue;
    const candidate = join(folder, "claude");
    try {
      if (!statSync(candidate).isFile()) continue;
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      continue;
    }
  }
  throw new Error("Claude Code is not installed on this machine.");
}

/** Which variable carries a stored credential: `claude setup-token` tokens (sign-in or pasted), or an API key. */
export function claudeCredentialEnv(key: string): Record<string, string> {
  return key.startsWith("sk-ant-oat")
    ? { CLAUDE_CODE_OAUTH_TOKEN: key }
    : { ANTHROPIC_API_KEY: key };
}

async function privateDirectory(path: string): Promise<void> {
  await mkdir(path, { recursive: true, mode: 0o700 });
  const info = await lstat(path);
  if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid?.()) {
    throw new Error(`The Claude runtime directory ${path} is not private to this user.`);
  }
  await chmod(path, 0o700);
}

export class ClaudeAgentRuntime {
  readonly options: ClaudeAgentOptions;
  constructor(options: ClaudeAgentOptions) {
    this.options = options;
  }

  /**
   * `config` is CLAUDE_CONFIG_DIR (undefined with Claude Code's own sign-in: its default), and
   * `workspace` the SDK's cwd; the runtime's own directories are private to this user.
   */
  async directories(native: boolean): Promise<{ config: string | undefined; workspace: string }> {
    const config = native ? undefined : join(this.options.directory, "config");
    const workspace = join(this.options.directory, "workspace");
    await privateDirectory(this.options.directory);
    if (config) await privateDirectory(config);
    await privateDirectory(workspace);
    return { config, workspace };
  }

  /**
   * The SDK process environment: the parent's, minus every inherited Anthropic/Claude variable,
   * plus the config dir (for a key), the credential, and no telemetry or SDK-side retries (Pi
   * Durable owns retries).
   */
  environment(
    config: string | undefined,
    credential: ClaudeCredential,
    source = process.env,
  ): Record<string, string> {
    const env: Record<string, string> = {};
    for (const [name, value] of Object.entries(source)) {
      if (value !== undefined && !/^(ANTHROPIC_|CLAUDE_|CLAUDECODE$)/.test(name)) env[name] = value;
    }
    return {
      ...env,
      ...(config ? { CLAUDE_CONFIG_DIR: config } : {}),
      CLAUDE_AGENT_SDK_CLIENT_APP: "wovenmatter-bots",
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
      DISABLE_TELEMETRY: "1",
      DISABLE_ERROR_REPORTING: "1",
      ENABLE_TOOL_SEARCH: "false",
      CLAUDE_CODE_MAX_RETRIES: "0",
      CLAUDE_CODE_TOTAL_TOKENS_REMINDER: "off",
      ...(credential.key ? claudeCredentialEnv(credential.key) : {}),
    };
  }

  async query(params: Parameters<ClaudeSdkQuery>[0]): Promise<ReturnType<ClaudeSdkQuery>> {
    if (this.options.query) return this.options.query(params);
    const options = { ...params.options, pathToClaudeCodeExecutable: claudeExecutable(), mcpServersDelivery: "argv" };
    const sdk = await loadClaudeAgentSDK();
    return sdk.query({
      prompt: params.prompt,
      options,
    } as unknown as Parameters<typeof sdk.query>[0]) as unknown as ReturnType<ClaudeSdkQuery>;
  }
}

/** The Claude Agent SDK this process runs Claude subscriptions through (Pi Durable's copy). */
export async function loadClaudeAgentSDK(): Promise<typeof import("@anthropic-ai/claude-agent-sdk")> {
  const sdk = await import("@anthropic-ai/claude-agent-sdk");
  if (typeof sdk.query !== "function") throw new Error("The Claude Agent SDK has no query function.");
  return sdk;
}
