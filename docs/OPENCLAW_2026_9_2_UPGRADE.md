# OpenClaw 2026.9.4 integration

Targets official OpenClaw v2026.9.4, source
`3a9d69db306cd7f081e06254cb89c4bcc14a7107` (Gateway protocol v4,
device signature v3). The filename retains the original review target for link
compatibility.

## Gateway connection and recovery

- Device identity and tokens persist in Keychain, separately from shared
  token/password authentication. Production, default Dev and named Dev variants
  use separate credential namespaces.
- Local startup reads the selected configuration and respects its port,
  authentication and Tailscale settings. Existing listeners are borrowed;
  releasing a link never stops a borrowed process. Startup diagnostics are bounded
  and redact credentials. Configuration and secret-store access are read-only.
- Handshake timeouts, an idle watchdog and reconnect monitoring detect transport
  failures. Connection generations prevent retired clients and stale approval
  responses from writing through a replacement connection.
- Gateway-owned runs recover without resending uncertain input. Missing liveness
  remains unknown. Exact input keys take precedence over execution IDs when
  reconciling streamed replies, steering and native history. Duplicate repair
  preserves local run references and distinct same-text messages.

## Sessions and composer

- New local chats use `sessions.create` with a session-specific `cwd` pointing at
  the shared Woven Matter root. The response must confirm the directory; the
  OpenClaw agent's identity workspace and defaults remain independent.
- Settings imports retain native session keys, working directories and message
  dates. Browsing loads 25 eligible sessions per page, up to ten pages, excluding
  sessions already represented in Woven Matter.
- Import fetches all available history pages into private temporary files before
  one database transaction. Changed transcripts and failed reads abort the import.
  Native transcript identities deduplicate overlapping pages. Import activity
  keeps old imports in Recents without changing message timestamps; the existing
  hover card identifies imported sessions.
- The existing composer supplies model/thinking selection, prepared session-scoped
  model discovery, slash-command browsing and completion, stop controls and live
  permission handling. There is no separate session-controls sheet.

## Limits and validation

Ongoing refresh reads a recent 100-row snapshot after full import. Durable delta
catch-up, reset/compaction branch replacement, an offline outbox, native question
management and full rich-media/plugin rendering are outside this integration.
Raw Gateway message content is retained; upstream projection limits still apply.

`scripts/test-changes.sh --all` runs provider-free protocol, persistence, recovery,
import and native-editor fixtures, static/privacy checks, remote tests, and a macOS
Debug build with bundle validation. Live acceptance should cover linked-session
imports, original dates/directories, older-message scrolling, a reply across
reconnect, and composer command selection. Automated fixtures do not establish
live provider or remote-host acceptance.

## Upstream references

- [Official release](https://github.com/openclaw/openclaw/releases/tag/v2026.9.4)
- [Protocol version](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/packages/gateway-protocol/src/version.ts)
- [Connect authentication](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/packages/gateway-client/src/connect-auth.ts)
- [Session-aware models](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/src/gateway/server-methods/models.ts)
- [Transcript identity](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/src/sessions/transcript-events.ts)
