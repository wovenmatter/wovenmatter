# Workspace history, session messaging, and asset versions

WovenMatter owns one `workspace.sqlite`. This feature adds tables and indexes to
that database; it does not replace UI projections or create a second database.
`woven-note` remains the note/page/spreadsheet/HTML editing interface.

## Agent-facing contract

Every UI-dispatched turn receives its own backend-bound `woven-history` invocation,
including when no note is open. Use that supplied invocation (local environment
plus bundled binary, or a portable executable inside the remote workspace).

```text
woven-history conversations --json
woven-history conversation SESSION_ID --after 0 --limit 50 --json
woven-history runs --conversation SESSION_ID --json
woven-history trace RUN_ID --json
woven-history events --harness pi --kind wire.in --since 2026-09-01T00:00:00Z --json
woven-history search "customer research" --json
woven-history event EVENT_ID --offset 65536 --characters 65536 --json
woven-history versions NOTE_ID --json
woven-history version VERSION_ID --json
woven-history send TARGET_SESSION_ID --text "Here are my findings" --request-id UUID --json
```

- Query responses contain `schemaVersion: 1`, `rows`, `nextCursor`, and `hasMore`.
  Cursors are exclusive. Limits default to 50 and may range from 1 to 200.
- `events`, `trace`, and `search` accept conversation, run, harness, kind, and
  recorded-time filters. Search uses SQLite FTS5 literal phrase matching, not SQL
  or an executable FTS expression. `runs` accepts a conversation filter.
- Event IDs remain stable. Native payload text is preserved before projection.
  Event listings inline up to 65,536 characters per payload. Larger payloads have
  `payload: null` and `payload_characters`; retrieve them with `event ID` and
  character offsets. Chunking never truncates the stored evidence.
- Query results are JSON; protocol/dispatch errors use `error` and a nonzero CLI
  exit status. No arbitrary SQL, shell execution, or database mutation command is
  exposed by the history service.
- Read-only queries are themselves audited. Their result IDs are journaled, not
  recursively embedded copies of earlier traces. Harness-observed tool calls and
  results remain captured independently.
- `versions` lists metadata; `version` retrieves one retained snapshot. Linked
  JSON/SQLite data references are part of the document, but **external data files
  are not versioned** by this feature.

### Session messaging: the explicit write operation

`send` follows the same `ApplicationModel.sendAgentMessage` path as UI messages:
start a turn in an idle session, or use the existing steering path in an active
session. Busy/configuring/unavailable sessions and unsupported steering report a
failure; they are not silently queued somewhere else. Sending does not wait for
the agent's full response. Read the target conversation/trace to follow progress.

Sender identity comes from the backend endpoint bound to the originating
conversation, not a `--from` argument. The durable delivery records retain the
source session, source agent/title snapshots, target session, content, request ID,
status, and target message ID. Target message insertion and attribution attachment
are one SQLite transaction. The UI displays a separate **Sent from agent · session**
label; the recipient's delivered context identifies the text as agent-authored,
not a new instruction from the human.

Use a fresh UUID request ID for each logical message and reuse it only when
retrying that same message. A reservation prevents duplicate dispatch on retries;
a reused ID with a different sender/target/body is rejected. `accepted` means
accepted into the target session, not that the target completed its task. A
`pending` receipt after a crash is deliberately not automatically resent: inspect
the target before deciding whether to issue a new message. Self-send is rejected,
text is limited to 64 KiB, and each source can reserve at most 20 sends per minute.
There are no broadcasts, automatic replies, or background agent conversations.

## Capture and provenance

- Codex, Claude Code, Grok Build, Cursor, Hermes, and OpenCode: capture their
  original ACP inbound and outbound frames before notification filtering or tool
  activity merging. Unknown future fields/events survive.
- Pi: capture native RPC inbound/outbound JSON, including tool bodies and unknown
  events omitted from its current UI projection.
- OpenClaw: capture gateway request/response/event frames, including events that
  have no UI projection. Authentication handshake material is excluded. Gateway
  events with a known session key are associated with its conversation; frames
  without an unambiguous mapping remain agent-level evidence, not guessed run data.
- SQLite triggers preserve human messages and run transitions. Append-only text
  deltas avoid repeatedly saving growing UI message bodies.
- `woven-note` service requests/results/errors are recorded directly, in addition
  to whatever a harness exposes about those tool calls.

The recorder uses transactional inserts, monotonic database sequence numbers, and
unique event IDs. Reusing an event ID is idempotent only for the same event data;
a conflicting payload is an error. Transport capture failures propagate through
client failure handling instead of silently continuing an apparently complete run.
The native wire observation is not falsely labeled exactly-once upstream delivery:
if a harness replays a frame without a durable upstream ID, both observations can
be retained. Original upstream identifiers/timestamps remain in the raw payload.

A one-time migration imports surviving messages, normalized activities, and prior
OpenClaw raw trace records with **legacy-partial** coverage. Missing historical
transitions, deleted records, hidden provider reasoning, harness-local files not
exposed by its protocol, and work performed outside WovenMatter are not fabricated.
This is complete capture of the supported protocol traffic WovenMatter observes,
not instrumentation inside every CLI subprocess or a reconstruction of past loss.
Process stderr diagnostics are not part of the protocol archive.

## Local and remote connection model

Local endpoints are owner-only Unix sockets in a private application-instance
directory. They share the tested socket framing, timeout, cancellation, and bounded
connection implementation with `woven-note`, but have separate handlers/contracts.
The endpoint overrides any caller-provided source session field.

Managed remote workspaces receive a Python-stdlib CLI and a private Unix socket
inside their existing container. A backend-owned SSH process launches the relay
with `docker exec --interactive`. Requests and responses traverse that SSH stdio
connection back to the same backend handler/database. Startup waits for a ready
handshake. Disconnect removes the relay socket; the next dispatched turn can
reestablish a failed bridge. There is no public port, database copy, new hosted
service, or backend credential placed in an agent prompt. Python 3 is already part
of the managed workspace image.

These are user-owned local/SSH workspace trust boundaries, not isolation between
mutually hostile agents sharing one OS account. Remote history requires the owning
WovenMatter application and its authenticated workspace connection to remain up.
Managed workspaces are automatic; an arbitrary external machine without a
configured WovenMatter workspace/SSH connection is not automatically enrolled.

## Bounded note-asset versions

Applies to ordinary notes/pages, spreadsheets, and HTML artifacts:

| Rule | Default |
|---|---|
| Maximum retained snapshots per asset | 50 |
| Maximum retained content bytes per asset | 20 MiB |
| Maximum retained content bytes across assets | 256 MiB |
| Ordinary editing checkpoints | At most every 5 minutes, plus close/history-view checkpoints |
| Agent edits | Preserve before/after boundaries immediately |
| Restore | Preserve current content first, restore as a new revision/checkpoint |
| Unchanged title/content | No duplicate snapshot |

The oldest snapshots are pruned to enforce **both count and byte budgets**. A
single snapshot larger than 20 MiB is not retained. Current documents are never
pruned by these rules. SQLite reuses freed pages; pruning is not a promise that the
physical database file immediately shrinks. The limits cover snapshot contents,
not SQLite metadata/index overhead or the separately durable event journal.

The version UI lists timestamps/source labels, previews retained content, and
restores with an expected-revision check. Revision tokens stay timestamp-shaped
for existing `woven-note` clients but advance strictly, even for same-millisecond
edits. Restore is an application mutation, **not** a read-only history command.
Snapshots are lazily seeded for existing assets when viewed or edited; no earlier
versions are invented. Pruned version IDs may remain referenced by durable events;
retrieving a pruned version returns no retained row.

## Verification

Run `scripts/test-changes.sh --all`. When running from a Codex session that injects
`CODEX_HOME`, use `env -u CODEX_HOME scripts/test-changes.sh --all`: an existing
Codex workspace catalog test otherwise reads the injected home instead of its
fixture (also reproducible on unchanged main).

Coverage includes database reopen, replay/collision behavior, search/cursors,
bounded large-event reads, query auditing, version counts/bytes, rapid revision
checks, restore conflicts, all three asset kinds, atomic sender attribution,
message retries, Pi unknown native events, native CLI/socket integration, and the
portable relay's stdio/socket behavior and disconnect cleanup. No provider calls
are required. A live SSH/container/harness exercise and rendered UI review remain
manual integration checks; deterministic relay tests do not claim to replace them.
