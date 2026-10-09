# Conversation streaming

The transcript follows T3 Code's chronological work log: commentary stays where
it was emitted, contiguous thinking/tool activity becomes a compact disclosure,
and the final answer remains a native selectable response with Copy. Only an
expanded work group gets a bounded inner scroll view. Completed work folds under
its duration; interrupted/failed work remains inspectable.

Execution checklists appear above the composer, using the harness's own steps,
identities and statuses. They disappear when the run settles. Proposed plans
remain separate transcript content. A checklist control call is hidden only when
there is a normalized replacement, and failed controls remain visible. Providers
that do not emit checklists do not get invented progress.

## Storage and rendering

- Canonical native/wire captures remain in the central SQLite database. The
  desktop activity index is a disposable compact read model, not the archive.
- A revision clock, invalidation triggers and tombstones support incremental
  activity refreshes, including corrections/deletions in retained older runs.
  Older-page loads reconcile with the current presentation before application.
- Markdown, merged timelines and file-change counts are prepared off the main
  actor. Compact file-change records omit diff bodies; opening a diff loads its
  owning activity's full data.
- Tool details load on expansion and actual scroll visibility. Visible live
  details refresh; collapse/offscreen cancellation stops those full reads.
  Settled details use a bounded in-memory cache keyed by all contributing
  record revisions. Large text details are paged.
- Sending explicitly returns to the newest reply. Reading/expanding older work
  suspends following, and Latest reply returns to the stream. Response selection
  survives updates only while its selected source text is unchanged.
- The active-chat sweep draws into a canvas rather than animating child layout.
  Reduce Motion continues to suppress the sweep through the shared activity
  presentation.

The paragraph-stability rule was adapted from T3 Code; attribution and the MIT
notice are bundled in `app/App/ThirdPartyNotices.txt`. Reference source examined:
`t3dotgg/t3code` commit `611132c171f3a821bd2e32f22261135cef6330ac`.

## Real-session acceptance, 2026-10-07

These observations used the normal development app and real provider sessions.
Synthetic replay tests protect the underlying contracts but were not used as
live streaming acceptance. The harmless workloads were `python3 -c` calculations,
generated strings and timed waits, with no repository/file/network changes.
The local test chats are titled **Streaming Behavior Observation** (Codex and
Pi Durable); the T3 reference chat has the same title in Fleet.

| Scenario | Observed behavior |
| --- | --- |
| Codex, GPT-6-Luna Medium, three stages/six calls | Commentary interleaves with three Ran 2 commands groups; only the composer shows checklist progress. Completed work folds and the final table stays visible. |
| Matching T3 reference | Same commentary/group/checklist/completion structure. The six-call runs took 1m43s in WovenMatter and 1m48s in T3. |
| Twenty actual calls, batches of 16 and 4 | WovenMatter retained Ran 16 commands and Ran 4 commands disclosures. Opening a command showed all 20 printed lines plus its raw capture while later calls continued. Matching runs took 1m19s in WovenMatter and 1m16s in T3. These durations include provider/tool time. |
| Stop during a 45-second command | WovenMatter showed Stopped after 42s within approximately 0.53 seconds of the observed click/state round trip, removed the task badge and accepted another task in the same chat. T3 likewise retained the interrupted command and removed its badge. |
| Follow-up while a command was running | A follow-up sent during a 25-second wait was incorporated into the final answer (`FOLLOWUP_OK`), without another shell command. |
| Pi Durable | Native checklist advanced Wait to Verify; commentary preceded each actual command; six timed output lines and 42 were retained; completion folded after 49s. Its configured OpenAI subscription model was GPT-6 Astra Low. |
| Reopen and Copy | Relaunch/thread switching retained real work groups and expandable full captures. Copy returned the complete Markdown table, verified by pasting into an unsent draft and clearing it. |

### Performance observations

Debug builds emit metadata-only `ConversationPerformance` unified logs with
read and preparation/application durations, summary counts and full-decode
counts. They contain no message text or identifiers. Filter with:

```sh
log stream --style compact --level debug \
  --predicate 'subsystem == "wovenmatter.desktop.dev" AND category == "ConversationPerformance"'
```

During the first twenty-command run in the existing approximately 1.96 GB
workspace database, 69 refresh samples showed:

| Measurement | Median | p95 | Maximum |
| --- | ---: | ---: | ---: |
| Compact read | 1.29 ms | 25.28 ms | 80.36 ms |
| Transcript preparation and state application | 1.36 ms | 4.23 ms | 5.42 ms |

Those compact refreshes decoded zero full activity payloads and retained up to
51 activity summaries. Visible disclosure reads are separate. These are pipeline
timings, not frame or paint latency. Sampling WovenMatter's main process also
identified the layout-driven active-row sweep; the canvas change addresses that
cost without changing its appearance. Whole-process CPU includes other windows,
rendering and shared-machine activity, so it is not a universal parity benchmark.

Provider-free regression coverage exercises the shared presentation and native
normalizers for the other harnesses, ownership fencing, plan replacement/merge/
clear, terminal deltas, paging, cache invalidation and canonical retention.
Live acceptance above covers the configured local Codex and Pi Durable routes.
Updated remote gateway code must run on a separately updated remote installation
to exercise those normalizers there; this PR does not deploy it.

### Observed upstream output limitation

The final Codex live check exposed an omission in the active Codex ACP 2.1.1
adapter: a command printed line 1 immediately, then lines 2–5 at two-second
intervals, but the ACP wire carried only lines 2–5. WovenMatter retained those
chunks exactly, including a separate exit-only update. The same command's native
Codex completion record contained all five lines.

The adapter's command reporter marks output as streamed after any delta. Its
standard renderer then suppresses the aggregated completion output for streamed
terminal commands. Thus the desktop cannot recover an omitted prefix from these
ACP events. This is a known limit of this configured adapter route, not evidence
that every upstream-native byte is present in the ACP capture.

Recovering settled output from Codex's native records would add another capture
source, requiring explicit session/item identity, local/remote boundaries and
incremental file cursors. It is separate work. This change does not patch installed
tools, replay the entire native history on every turn, or claim complete command
output when the adapter omitted bytes.
