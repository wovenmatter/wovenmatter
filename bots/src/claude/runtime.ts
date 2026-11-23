import { accessSync, constants, statSync } from "node:fs";
import { chmod, lstat, mkdir } from "node:fs/promises";
import { delimiter, join } from "node:path";

/**
 * The Claude Agent SDK runtime: where Claude Code runs and with which environment. It runs the
 * Claude Code installed on this machine, found on PATH at each request, with Claude Code's own
 * sign-in and default configuration, as Pi Durable does (`default-agent/src/claude.mjs`). The
 * runtime never reads that sign-in. An Anthropic API key is the separate `anthropic` provider,
 * which does not run Claude Code.
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
}) => AsyncIterable<ClaudeSdkEvent> & { close?(): void; supportedModels?(): Promise<unknown> };

export type ClaudeAgentOptions = {
  /** Private runtime directory (mode 0700), holding the SDK's working directory. */
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

  /** The SDK's working directory, private to this user like the runtime's own. */
  async workspace(): Promise<string> {
    const workspace = join(this.options.directory, "workspace");
    await privateDirectory(this.options.directory);
    await privateDirectory(workspace);
    return workspace;
  }

  /**
   * The SDK process environment: the parent's, without anything that would switch Claude Code
   * away from its own sign-in (the filter Pi Durable uses), and with no telemetry or SDK-side
   * retries (Pi Durable owns retries).
   */
  environment(source = process.env): Record<string, string> {
    const env: Record<string, string> = {};
    for (const [name, value] of Object.entries(source)) {
      if (value !== undefined && !/^(ANTHROPIC_|CLAUDECODE$|CLAUDE_CODE_ENTRYPOINT$|CLAUDE_CODE_OAUTH_TOKEN$)/.test(name)) {
        env[name] = value;
      }
    }
    return {
      ...env,
      CLAUDE_AGENT_SDK_CLIENT_APP: "wovenmatter-bots",
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
      DISABLE_TELEMETRY: "1",
      DISABLE_ERROR_REPORTING: "1",
      ENABLE_TOOL_SEARCH: "false",
      CLAUDE_CODE_MAX_RETRIES: "0",
      CLAUDE_CODE_TOTAL_TOKENS_REMINDER: "off",
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
