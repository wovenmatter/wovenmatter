# OpenCode v2 integration contract and parity

This integration replaces OpenCode ACP with the native v2 service API. Existing OpenCode SQLite transcripts are retained and read-only. Other harness transports remain unchanged. Connecting v2 remains an explicit user action; startup and installation never happen merely because a conversation is selected.

## Compatibility reference

- Tested runtime and official client: `@opencode/cli@0.0.0-beta-19278` and `@opencode/client@0.0.0-beta-19278` (`opencode2`). Only this exact beta is accepted until another version is tested.
- Upstream source inspected: [`anomalyco/opencode` at `be41bc4e7de76637f4c7a94d6110637270bfff37`](https://github.com/anomalyco/opencode/tree/be41bc4e7de76637f4c7a94d6110637270bfff37). This is the source reference; npm did not supply a `gitHead`, so it is not asserted to be the package's exact build commit.
- Runtime routes were checked against the generated client shipped in the pinned npm package, the reference OpenAPI, and the running pinned beta.
- Native terminal: SwiftTerm 1.10.1, revision `5c83a9d214e7354697624c11deb4e488bdcfabad`. The CPU renderer avoids an Xcode build plugin and separately installed Metal compiler. The dependency and transitive resolution are committed.

Starting documentation: [overview](https://opencode.ai/v2/docs/), [build](https://opencode.ai/v2/docs/build/), [client](https://opencode.ai/v2/docs/build/client/), [SDK](https://opencode.ai/v2/docs/build/sdk/), [API](https://opencode.ai/v2/docs/api), [CLI](https://opencode.ai/v2/docs/cli/), [troubleshooting](https://opencode.ai/v2/docs/troubleshooting/), [v1 migration](https://opencode.ai/v2/docs/migrate-v1/).

## Architecture and evidence

The desktop's `packages/desktop/src/main/service/background-service.ts` uses `@opencode/client/service`, requires Basic authentication, and canonicalizes `0.0.0.0` to loopback. Its `Service.ensure` helper may replace an incompatible or unhealthy service. Woven Matter implements the small registration/health contract in Swift and deliberately leaves replacement to OpenCode. Adding a Node helper would not improve that contract and would introduce another runtime dependency.

Local discovery reads `$XDG_STATE_HOME/opencode/service.json`, defaulting to `~/.local/state/opencode/service.json`. Registration includes a dynamic URL, PID, version and password. Health validates the actual process and version. No fixed port or unauthenticated discovery fallback is used. A user-requested start verifies `opencode2 --version` and runs `serve --service` only if no registration exists. Disconnect and app shutdown only cancel this client's network tasks. They never call service stop or session interrupt.

Remote connections use an explicitly entered HTTP(S) origin, including a Tailnet origin or user-managed SSH forwarding address. Their Basic credentials are stored in macOS Keychain. Paths, file reads, shell commands and terminals are sent to the session's host. The existing remote ACP proxy does not pretend to support v2 and points users to direct OpenCode settings. Woven Matter does not deploy OpenCode or modify tunnels automatically.

The general `/api/event` subscription is live-only. Recovery uses the experimental session log with an exclusive `after` sequence plus canonical HTTP snapshots. See `packages/schema/src/session-event.ts`, `packages/core/test/session-log.test.ts`, `packages/core/src/session/store.ts`, and the generated client. Cursors are committed to SQLite atomically with projected messages and activities. Snapshots refresh at 500 ms while active and 2.5 s while idle; streaming content is rendered from canonical message state, rather than concatenating potentially duplicated ephemeral deltas. Reconnect pages through missed history and refreshes the history already held locally. Message order follows server sequence, not timestamp or identifier sorting.

Prompt admission persists a client-generated message ID and body before sending. Lost responses reconcile against the inbox and individual message lookup. A 404 during reconciliation does not prove rejection. Uncertain input is never automatically resent. Session creation also retains an uncertain ID. Closing a view is distinct from an explicit interrupt or terminal termination.

## Functional checklist

“Verified” below means the named evidence, not full provider or human acceptance. “Implemented but unverified” means code and build validation exist, with the live scenario still outstanding. No claim of 100% parity is made.

| Capability | Status | Evidence / boundary |
| --- | --- | --- |
| Authenticated local discovery, dynamic port, exact version check | Implemented and verified | Connected native Dev app to isolated beta; malformed origin/PID and incompatible-version fixtures |
| Explicit remote origin and Keychain credentials | Implemented but unverified | Native HTTP(S) connection; remote-host acceptance remains |
| Shared service startup, disconnect, shutdown | Implemented but unverified | Version preflight; never stop shared service; native app restart and automatic reconnect verified; shared service replacement/restart acceptance remains |
| Existing sessions, create, open, search, pagination | Implemented and verified | Created via beta API and opened same identity in native session browser |
| History recovery, stable order and deduplication | Implemented and verified | Deterministic 251-message and 1,700-message catch-up, older-page and revert tests; SQLite reopen; official-client imported transcript rendered natively |
| Persisted durable cursor / log follow / reconnect backoff | Implemented but unverified | SSE fragmentation tests; live restart scenario remains |
| Prompt response loss and uncertain acceptance | Implemented and verified | Accepted-response-loss and unresolved-404 fixtures each assert one submission |
| Shared changes from another client | Implemented and verified | Native form and queued input appeared after external API changes |
| Streaming text, reasoning, tool calls/results/errors | Implemented but unverified | Native imported transcript displays text, reasoning and tool result; live provider streaming acceptance remains |
| Attachments, images, tool file output, server file references | Implemented but unverified | Pinned beta accepts attachment with execution disabled; imported file attachment displayed natively; live image/provider round trip remains |
| Permissions, once/always/reject, saved-permission revocation | Implemented but unverified | Pending request recovery fixture; live request decision remains |
| Questions/forms, visibility conditions, options and custom input | Implemented and verified | External client created form; native UI selected and submitted answers |
| Model/provider/agent discovery and per-session model variant | Implemented but unverified | Native pickers; credentialed provider/variant acceptance remains |
| Queue/steer/cancel inbox, resume, interrupt, background tools | Implemented but unverified | Live inactive queue inspected; no provider run consumed |
| Rename, fork, fork-before, delete, import/export | Implemented but unverified | Native lifecycle controls; full live lifecycle matrix remains |
| Context/usage/cost and compaction | Implemented but unverified | Native inspection and compact action; live compaction requires provider |
| File browsing/read/find, working/branch/committed diff | Implemented but unverified | APIs bound to session location; live Git fixture remains |
| Staged revert, clear and explicit commit | Implemented but unverified | Native history controls; no automatic destructive commit |
| Worktree create/refresh/remove and move session | Implemented but unverified | Native host-scoped controls; live Git fixture remains |
| Ordinary workspace PTYs | Implemented but unverified | Native SwiftTerm + authenticated WebSocket; same API as desktop `packages/app/src/session/terminal/context.tsx` |
| Persistent session PTYs | Implemented and verified | Native creation in the session directory, printf input/output, display disconnect and checkpoint recovery; reference TUI `packages/tui/src/component/terminal-pane.tsx` |
| Commands, skills, shell and background jobs | Implemented but unverified | Native discovery/actions, background output pagination and explicit stop; no provider-consuming execution in tests |
| Integrations: key, OAuth, code, command sign-in; credentials | Implemented but unverified | Native connect forms, status/cancel, activate/rename/remove; live sign-in requires user account |
| MCP local/remote server configuration, connect/disconnect/resources | Implemented but unverified | Native controls; third-party MCP acceptance remains |
| Plugin inventory, update check/update | Implemented but unverified | Package targets come from `Plugin.Source`; built-in/local/SDK sources inspectable |
| Configuration inspection | Implemented but unverified | `/api/config` exposes inspection; no global config mutation endpoint in pinned API |
| Session instruction entries and environment overrides | Implemented and verified | API successfully set instruction and environment in isolated session; native editors included |
| v1 transcript preservation and no ACP continuation | Implemented and verified | Database execution guard and fixture; no old transcript/session-ID migration |
| Global configuration-file editor through a native config-write API | Unsupported upstream | Pinned `/api/config` has GET only; host configuration remains managed with OpenCode |
| Arbitrary plugin-specific UI / RPC | Unsupported as a universal native contract | Plugin features vary; inventory is exposed, but no arbitrary plugin interface is invented |

## Validation still required before human acceptance

The provider-backed two-interface scenario is deliberately not claimed as complete: open the same session in Woven Matter and OpenCode's desktop/TUI, submit from both, exercise tools and permissions, attach an image, change a model, disconnect during execution, reconnect and confirm no duplicate input. Automated tests must not consume provider services. Test signed-in remote connections and OAuth/MCP integrations with the intended accounts.

Automated validation: `scripts/test-changes.sh --all` (109 Swift tests, including 12 OpenCode fixtures; 11 remote-service tests; static/public-tree checks; native application validation). The Dev build uses the isolated OpenCode variant described in TESTING.md. Review and human acceptance are separate from these results.
