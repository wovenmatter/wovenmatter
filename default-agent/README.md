# Pi Durable

The built-in agent. The server runs `node src/main.mjs` once per session, with
the session's working directory as its cwd and `WOVEN_PI_DATA` set to a folder
it owns, and speaks ACP to it over newline-delimited JSON-RPC on stdio.

- **Storage**: the Pi Durable SDK's stock SQLite storage in
  `$WOVEN_PI_DATA/pi-durable.sqlite`. Each session has its own table prefix in
  that file, because the SDK allows one writer per storage and each session is
  its own process. Model catalogs and the Claude model list are cached beside it.
- **Credentials**: held in memory only. The agent asks the server with the
  request `woven/credentials` when it first needs them and again when one is
  missing or about to expire, and sends `woven/credentials/update` when the SDK
  renews an OAuth credential.
- **Models**: pi-ai's stock providers and catalogs, plus the Claude
  subscription, which is Claude Code's own sign-in used through the Claude
  Agent SDK, and `xai-api`, xAI by API key beside the Grok subscription.
- **Tools**: the SDK's `read`, `write`, `edit` and `bash`, a checklist shown as
  the ACP plan, web search through an Exa, Brave or Firecrawl key, foreground
  subagents (shown as `tool_call`s with `_meta.wovenKind: "task"`), and the
  session's MCP servers. Compaction is the SDK's own.

`node src/main.mjs --control` answers one JSON line: `providers`, `login` for
a subscription, or `update-sdk`, which installs the latest SDK packages under
`$WOVEN_PI_DATA/sdk` for sessions started afterwards.

| File | What it does |
| --- | --- |
| `src/main.mjs` | Entry point; picks up an updated SDK before anything loads it. |
| `src/agent.mjs` | The ACP methods. |
| `src/session.mjs` | One session: storage, harness, prompt, options. |
| `src/projection.mjs` | Conversation changes as `session/update`s. |
| `src/models.mjs`, `src/claude.mjs` | Model runtime, provider list, Claude. |
| `src/tools.mjs` | Checklist, search, subagents, MCP. |
| `src/credentials.mjs`, `src/control.mjs`, `src/sdk.mjs`, `src/rpc.mjs` | The rest. |

`npm test` runs the agent as a process against a synthetic model; it never
calls a provider.
