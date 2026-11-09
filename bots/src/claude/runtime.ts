import { chmod, lstat, mkdir } from "node:fs/promises";
import { join } from "node:path";
import { VERSION } from "../version.ts";
import type { ClaudeCredential } from "./provider.ts";

/**
 * The Claude Agent SDK runtime: where Claude Code runs and with which environment. Mirrors Woven
 * Matter's `default-agent/src/claude-runtime.mjs`. Credentials come from the host API: for a
 * Claude subscription the machine's native Claude directories, which Claude Code owns (the runtime
 * never reads or copies their contents); for an API key, the key through the SDK's environment.
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
  /** Private runtime directory (mode 0700): Claude Code's config dir and working directory. */
  readonly directory: string;
  /** Replace the SDK's `query` (tests inject a fake; no Claude Code process starts). */
  readonly query?: ClaudeSdkQuery;
  /** `pathToClaudeCodeExecutable`; the SDK's bundled binary by default. */
  readonly executable?: string;
  /** Idle timeout per SDK request. Default 180 s, like Woven. */
  readonly timeoutMs?: number;
};

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
   * `config` is CLAUDE_CONFIG_DIR (the native one when given), `workspace` the SDK's cwd; the
   * runtime's own directories are private to this user.
   */
  async directories(nativeConfig?: string): Promise<{ config: string; workspace: string }> {
    const config = nativeConfig ?? join(this.options.directory, "config");
    const workspace = join(this.options.directory, "workspace");
    await privateDirectory(this.options.directory);
    if (!nativeConfig) await privateDirectory(config);
    await privateDirectory(workspace);
    return { config, workspace };
  }

  /**
   * The SDK process environment: the parent's, minus every inherited Anthropic/Claude variable,
   * plus the config dir, the credential, and no telemetry or SDK-side retries (Pi Durable owns
   * retries).
   */
  environment(
    config: string,
    credential: ClaudeCredential,
    source = process.env,
  ): Record<string, string> {
    const env: Record<string, string> = {};
    for (const [name, value] of Object.entries(source)) {
      if (value !== undefined && !/^(ANTHROPIC_|CLAUDE_|CLAUDECODE$)/.test(name)) env[name] = value;
    }
    return {
      ...env,
      CLAUDE_CONFIG_DIR: config,
      ...(credential.native?.secureStorageDir
        ? { CLAUDE_SECURESTORAGE_CONFIG_DIR: credential.native.secureStorageDir }
        : {}),
      CLAUDE_AGENT_SDK_CLIENT_APP: `wovenmatter-bots/${VERSION}`,
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
    const sdk = await import("@anthropic-ai/claude-agent-sdk");
    const options = this.options.executable
      ? { ...params.options, pathToClaudeCodeExecutable: this.options.executable }
      : params.options;
    return sdk.query({
      prompt: params.prompt,
      options,
    } as unknown as Parameters<typeof sdk.query>[0]) as unknown as ReturnType<ClaudeSdkQuery>;
  }
}
