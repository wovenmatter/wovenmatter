# Background server parity audit

Comparison: pre-change `d0dd31c7c03b41a5a83a382cac5cb6eca48a21e9` versus
the background-server ownership branch, including its launch and startup fixes.
The combined snapshot also contains the separate Pi SQLite storage change.

## Ownership versus execution

| Area | Before | With the ownership change |
| --- | --- | --- |
| Production library host | Background execution defaulted on; an off preference selected a foreground owner. | Always a background owner. The window connects to it. |
| Snapshot development build | The window process owned the isolated workspace and harnesses. | An isolated `--backend` process owns them. This is the largest behavioral change in this testing profile. |
| Local harness launch | `LocalACPSessionCoordinator` / OpenCode services in the execution owner. | Same launch/configuration/prompt/cancel code, in the backend. Inspection adds owner metadata, not launch arguments or environment. |
| Chat rendering | Foreground ownership refreshed directly; the existing optional background mode used invalidations and read-only SQLite projections. | Always uses that existing background projection path for a library host. The server persists streamed content; the UI reloads affected visible chats. |
| Credentials, model routing | Owning services resolve settings and credentials. | Same services and provider request builder; credentials are not transferred in UI state snapshots. |
| Scheduling and remote connections | Belonged to whichever process owned execution. | Belong to the backend; UI exit leaves them running. |
| Remote workspace execution | Workspace service owned runtime processes, durable accepted input, cancellation and reconnect. | Execution protocol remains the same. The added inventory reports managed activity. |
| Paired-library client | Optional secondary Mac execution workspace was hosted inside the client. | Unchanged. This federation path is still an exception to service ownership; the library-host change did not migrate it. |
| Pi persistence | Native task/conversation state used the Chord JSONL adapter. | Separate PR #161 substitutes a host-local SQLite adapter. Provider serialization and task semantics remain unchanged. |

The move should preserve harness behavior. It does not require a new agent loop,
provider payload format, tmux wrapper, or alternative task scheduler.

## Failures found and corrections

- **Executable path aliases:** Node canonicalized module URLs while an executable
  path could retain `/tmp` rather than `/private/tmp`. Main-module guards then
  silently skipped wrapper startup. The background launch exposed this mismatch.
  Guards now canonicalize the command-line path. Subprocess tests exercise aliases
  and paths with spaces; actual snapshot Codex metadata initialization succeeded.
- **Pi new-chat permissions:** the initial metadata read could leave an idle probe
  holding a use count when saved permission defaults were applied. The coordinator
  now waits for that existing probe, then revalidates cancellation and admission.
  It still rejects changes during real active work.
- **Readable tool output:** Pi published live output only in ACP `rawOutput`, which
  the Swift chat renderer does not treat as readable content. This gap also exists
  in the pre-change source. Live window edits now become bounded standard ACP
  content snapshots. Original native output and results remain archived.
- **Code-mode children:** retained synthetic model-kind tool tasks have no SDK live
  tool slot. Their existing execution, ownership, cancellation and native receipts
  are preserved; the adapter now explicitly projects their starts, live output and
  terminal results into chat. This avoids changing recovery/storage machinery as
  part of a display fix.
- **Empty output snapshots:** the Swift ACP client previously collapsed an explicit
  empty content array to an absent update, retaining stale text. Empty snapshots
  now clear text; absent content still preserves the last output.
- **Inspection placement:** the chat inspection asset/button is removed. Settings
  retains service/process inventory. Agent output belongs in the chat transcript.

## Verification and remaining boundary

Provider-free tests use actual local shell processes and gated completion to
prove that output arrives before exit, across code-mode settings. Cancellation
tests cover ordinary and code-mode children. ACP client fixtures cover Pi,
Codex, Claude Code and Grok. Existing OpenCode native streaming/reconciliation
tests cover its separate transport. The process-boundary fixture exercises a
separate owner, frontend write exclusion, live/terminal read-only transcript
projections after frontend exit, reconnect and restart. These fixtures do not
certify real provider acceptance or a live remote-container deployment.

The OpenCode Go/Kimi HTTP 400 is **not resolved by these streaming fixes**.
The ownership diff does not change its model request builder. An offline request
inspection shows the selected model, supported low reasoning effort and stable
session header being supplied; this rules out those specific fresh-request
omissions, not every provider rejection. The current safe diagnostic retains the
HTTP classification but deliberately discards arbitrary response text. A real
provider rejection must be diagnosed before calling that integration fixed.
Repository instructions prohibit tests that consume provider services, so no
automated inference request was made during this audit.
