# Woven session instructions

Woven launches Pi Durable, Codex, Claude Code, Grok Build, and OpenCode.
Standalone Pi CLI, Cursor, Hermes, and OpenClaw integrations are retired. Their
saved history remains readable; start a new supported chat to continue work.

The one maintained block is [harnesses/woven-instructions.txt](../harnesses/woven-instructions.txt).
It points agents to app tools and current session context. It prescribes no file
layout and never overwrites project instructions or user global instructions.

- Pi Durable composes the block alongside native system sections and project
  instruction files. Its child-agent prompt composition remains native.
- Codex ACP 2.3.0 accepts `CODEX_CONFIG`; Woven appends `developer_instructions`
  to any supplied developer text and keeps the native base prompt and project
  instruction discovery. See [adapter configuration](https://github.com/agentclientprotocol/codex-acp).
- Claude ACP 0.97.0 forwards `_meta.systemPrompt.append` to the native Claude Code
  preset. Woven adds the block when creating a session, retaining existing preset
  options. Existing sessions retain their original instructions. See [adapter](https://github.com/agentclientprotocol/claude-agent-acp).
- Grok Build accepts `_meta.rules` on session creation and appends it to its native
  prompt. Resume keeps original rules; Woven does not replace the entire prompt
  or replay instructions. See [upstream composition](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-shell/src/agent/mvp_agent/mod.rs#L976-L1052).
- OpenCode v2.0.22's `session.context` plugin hook supplies the normal request's
  system parts. Only sessions explicitly connected to Woven receive one text
  block; every assembled request deduplicates it. Resume uses the same hook,
  with no stored chat-message injection. See [hook assembly](https://github.com/anomalyco/opencode/blob/v2.0.22/packages/core/src/session/model-request.ts)
  and [SystemPart shape](https://github.com/anomalyco/opencode/blob/v2.0.22/packages/ai/src/schema/messages.ts#L19-L34).

Scheduled ACP tasks use the same launch wrapper. Scheduled OpenCode tasks connect
only their own session to the service owner's MCP endpoint, allowing database
writes while the Mac is offline. Unrelated sessions on a shared OpenCode service
receive no Woven system block.
