# OpenClaw 2026.9.4 integration

Technical reference for the pinned integration reviewed below. For user setup,
see [Agent setup](guide/agents.md) and [Scheduled work](guide/schedules-and-usage.md).

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
  ready Gateways keep running when the app closes or a link is removed. Incomplete
  startup is cancelled. Startup diagnostics are bounded and redact credentials;
  owned local processes write private host logs so closing the app cannot break
  their output pipe. Credential and secret-store access remain read-only.
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

### Scheduled jobs and results

- Cron Jobs provides native create, edit, pause/resume, run-now and delete actions,
  job history, and delivery routing. New jobs use isolated agent sessions and native
  `delivery.mode = none`; Woven Matter is their result destination. A stable
  declaration key makes retrying creation converge on the same job. Actions are
  never automatically retried after an uncertain response.
- Owned local and remote startup copies the bundled scheduled-result plugin to
  the selected host and uses OpenClaw's config writer to enable it. Existing plugin
  settings and credentials are preserved. An explicit plugin deny/disable is
  reported as a startup error. A borrowed Gateway may need restarting to load the
  newly configured plugin.
- The plugin synchronously retains full text from isolated `agent_end` messages
  and completion metadata from `cron_changed`, joining either hook order by job
  and native session identity. State lives under the host's persistent
  `~/.wovenmatter/scheduled-results/openclaw/` directory, separated by profile.
  It survives ordinary process/container restarts and desktop disconnection.
- The desktop fetches chunked full output and commits local history before
  acknowledging host retention. Conversation delivery separately commits a message,
  unread state and receipt in one transaction. Retries, route changes and deleted
  conversations cannot redeliver an acknowledged run. History-only, one new
  conversation per result, and a designated existing conversation are supported.
- Native history is paginated for catch-up. Retained full output is never replaced
  with a later summary. Deleted jobs retain a local history entry. Remote Gateway
  running intent persists across service/container restart; explicit Stop clears it.
- Full automatic retention currently covers isolated agent text results. Native
  main/reused-session jobs, script/command output, rich media, missing completion
  hooks, and results already pruned before capture are not guaranteed by these
  hooks. Unavailable output stays unacknowledged and surfaces a collection error;
  summaries are not presented as complete successful results. Host records are
  retained without automatic expiry, so disk capacity must be maintained. Disk
  failures are reported in the page and native logs when possible.
- Collection does not invoke a provider. **Continue in chat** prepares an unsent
  draft for explicit review; stored results are not silently added to later prompts.

### Other integration limits

Ongoing refresh reads a recent 100-row snapshot after full import. Durable delta
catch-up, reset/compaction branch replacement, an offline outbox, native question
management and full rich-media/plugin rendering are outside this integration.
Raw Gateway message content is retained; upstream projection limits still apply.

`scripts/test-changes.sh --all` runs provider-free protocol, persistence, recovery,
import and native-editor fixtures, static/privacy checks, remote tests, and a macOS
Debug build with bundle validation. Live acceptance should cover linked-session
imports, original dates/directories, older-message scrolling, a reply across
reconnect, and composer command selection. Automated fixtures do not establish
live provider acceptance. Provider-free remote fixtures also run in a Linux test
container; those fixtures do not establish an end-to-end live scheduled-agent run.

## Upstream references

- [Official release](https://github.com/openclaw/openclaw/releases/tag/v2026.9.4)
- [Protocol version](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/packages/gateway-protocol/src/version.ts)
- [Connect authentication](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/packages/gateway-client/src/connect-auth.ts)
- [Session-aware models](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/src/gateway/server-methods/models.ts)
- [Transcript identity](https://github.com/openclaw/openclaw/blob/3a9d69db306cd7f081e06254cb89c4bcc14a7107/src/sessions/transcript-events.ts)
