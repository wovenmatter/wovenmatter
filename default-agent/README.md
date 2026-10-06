# Built-in runtime

Built-in uses pinned Pi Durable 1.0.3 `Harness`, `Conversation` and `Submission`
APIs locally and remotely. The coding-agent library supplies image/file/search
and code-mode tools, instructions and `ModelRuntime`; Durable owns execution.
Claude accounts use the official Claude Agent SDK. Standalone Pi is independent.

## Native persistence

Each conversation owns `durable/<woven-session-uuid>/native/` under its execution
host's Built-in workspace root. Durable persists its tasks, requests, checkpoints
and context in fsynced multi-file JSONL. A small manifest identifies the store and
working directory; a library heartbeat lock enforces one execution owner.

Input fingerprints reject reuse with different content. Native request IDs and
unsafe-tool receipts prevent duplicate external effects. Stop aborts native work
and withdraws queued submissions. Worker retirement waits for native tasks,
submissions and pending configuration/archive writes.

This is a clean break: old Pi sessions are not converted, and Woven does not
reconstruct interrupted UI runs or redispatch saved prompts. Existing files stay
untouched. Remote transport retains fingerprint-only acceptance tombstones and
fails closed when a prior process's delivery outcome is uncertain.

## Native compaction

Foreground threshold/overflow compaction and `/compact [instructions]` prefer
native OpenAI/xAI compact endpoints, the ChatGPT Codex compaction-trigger stream,
or Claude SDK compaction. Manual admission atomically binds the input receipt and
native task. Only unsupported routes use Pi summary compaction; native failures
never silently fall back. SDK retries are disabled at Woven's model boundary.

Native windows and original covered entries remain separate from the full run
archive. Continuation identity includes model, account, endpoint, credential
identity and native principal where available. Switching routes rebuilds compatible
original context and strips foreign opaque signatures. Claude SDK owns its disk
persistence/resume; Woven copies exposed records through supported callbacks and
keeps a small current-prefix descriptor. Host tool-result boundaries start a fresh
SDK context with actual canonical results instead of inventory placeholders.

Provider contracts follow the [OpenAI guide](https://developers.openai.com/api/docs/guides/compaction)
and [xAI guide](https://docs.x.ai/developers/advanced-api-usage/context-compaction).
Connected-account behavior still requires manual verification.

## Central archive transport

`session/update` emits `woven_native_record` batches with stable native source and
session IDs. Each change has one raw record with its normalized search projection,
known Woven run ID and native kind. Credential/configuration transport is excluded.
Woven SQLite keeps an additional searchable copy; native stores remain independent.

`woven/history {sessionId, after, limit}` pages the current process's archive spool.
Spools are fresh and preserve old files without scanning, repairing or replaying
them. Inline records up to 512 KiB retain complete payloads; larger records use
bounded 256 KiB checksummed chunks and reconstruction manifests. Pages target
1 MiB, with cursors expressed as ordinals or `{record, byteOffset}`. Remote UI
polling uses the same append/paging backend and current operation handles.

Scheduled native runs use the same chunk format and bounded presentation helper.
Stored result pages stream into SQLite with global event ordinals; full transcripts
are not duplicated in completion JSON or held in a result array. A scheduled update
envelope is limited to 2 MiB; producers keep full native payloads in chunks and
split text losslessly, so there is no cumulative run-output cap.

## Validation

`npm test` uses synthetic models, local peers and temporary native stores, without
provider services. It covers current execution, native persistence/compaction,
account isolation, unsafe effects, cancellation, native permission/default behavior,
exact oversized capture/search/export and credential privacy. Packaging validation
checks the pinned SDKs and official Claude executable.
