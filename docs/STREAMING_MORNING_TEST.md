# Morning streaming acceptance pass

Use **Woven Matter streaming-parity-review snapshot Dev** for this pass.
It is the isolated snapshot for [PR #176](https://github.com/wovenmatter/wovenmatter/pull/176).
The original `streaming-parity` instance contains preserved active work.

Use the rebuilt review snapshot containing the authenticated-test follow-up
fixes. The earlier `ec0d36db` build does not contain those fixes.
[Verification evidence](STREAMING_VERIFICATION.md) records the T3 comparison,
automated coverage, screenshots and remaining limits.

## Setup and coverage

Authenticate the agents yourself in the **review snapshot's** Settings. For Pi
Durable, also enable models and choose a default; confirm the new-chat model
selector is populated. Select models advertised by each harness's own catalog.

Run the three prompts below in a new All Workspaces scratch chat for each row.
Name chats `Streaming QA / harness / model` so comparisons are easy to find.
Use two different model families/labs in OpenCode and Pi Durable, rather than
only two sizes of the same model. Include exposed reasoning and summary-capable
models where available. Record the selected thinking level.

| Harness | Model / thinking level | Text / Markdown | Tools / order | Reasoning | Stop / retry | Scroll / reopen | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Codex | | | | | | | |
| Claude Code | | | | | | | |
| Grok | | | | | | | |
| OpenCode: family A | | | | | | | |
| OpenCode: family B | | | | | | | |
| Pi Durable: family A | | | | | | | |
| Pi Durable: family B | | | | | | | |

Mark results Pass, Fail or N/A. For reasoning, note trace, summary or none exposed.
Reasoning text is evaluated only when the provider supplies it. Codex ACP drops
the distinction between summary and raw reasoning parts upstream; that documented
limit should not be mistaken for missing text that the adapter actually supplied.

## 1. Text, Markdown and Unicode

```text
Write a roughly 600-word guide to organizing a small personal library.
Use three sections with headings and several paragraphs, a numbered list,
a three-row comparison table, and one short fenced Python example.
Include these exact strings naturally: café, é, 👩🏽‍💻, 🇺🇸, हिन्दी.
Do not use tools or delegate. Finish with the sentence: Streaming check complete.
```

Check that the answer grows during the turn, with readable Markdown and stable
text color. Complete paragraphs/blocks can arrive together; token cadence need
not be identical between providers. The final sentence and final list/table/code
content must remain after completion, with no doubled or missing text. Copy the
settled answer and check the Unicode strings and final sentence.

## 2. Tools, commentary and reasoning

```text
Work only in this chat's scratch directory. Do not delegate or create background jobs.
Create streaming-qa.txt with two short lines. Read it with a tool, append a third
line, then read it again with a separate tool call. Run one read-only command
that lists this scratch directory. Give a brief progress update between phases.
Finish with a heading and bullet list describing the observed file contents
and completed actions. Do not modify anything outside this scratch directory.
```

Check the specific live tool label and static icon, incremental arguments/output
when supplied, and chronological placement of progress text, tools and answer.
Each tool call should append its own row during the live tool phase. When a new
thinking block, assistant message, or other standalone event arrives, only the
preceding tool list should condense into a reopenable group. Thinking and agent
messages must remain visible in order, including after the final answer arrives.
Reopen each earlier tool group and verify that all its calls remain available.
The final answer should close the last tool list as soon as its text appears,
without waiting for the run to finish. Supplied subagent names and statuses
should appear at their event position.
There should be no tool/reasoning spinner, duplicated answer or successful-looking
failed/cancelled call.

Live tools should follow only at the conversation's bottom. An expanded older
tool group should preserve its reading position through updates and reopening.
For a naturally long trace, try Earlier/Later/Latest reasoning. An earlier page
must stay fixed while new text arrives; leave the chat and return to verify the
same page and scroll position. Latest reasoning should resume following from
its live edge. Long-trace storage and Unicode boundaries also have automated
stress coverage; do not request hidden reasoning to force this case.

## 3. Stop, partial output and the next turn

```text
Run a foreground command that prints one numbered progress line per second
for twelve seconds, then report its result. Do not delegate, schedule work,
or start a background job.
```

Press **Stop** after two or three progress lines. Partial output should remain
readable, the run should settle, and unfinished work should not appear successful.
Then send:

```text
Do not use tools. Reply with one short paragraph ending exactly: Fresh turn works.
```

The new reply should stream normally without stale output or a stuck busy state.
Also stop a longer text-only answer mid-paragraph and check that its partial
text remains visible. After a settled turn, close/reopen the chat and relaunch
the review frontend once; completed output should remain intact without replayed
or duplicated work.

## Visual pass and reporting

Use Dark for the full matrix, then repeat a representative tool-heavy chat in
Green and Cognac and at a narrow window width. Check wrapping, readable ink,
reasoning navigation, expanded tool output and the final answer's placement.

Generate an inline HTML chart, then scroll the conversation with the pointer
over its center and beside it. Both should move the chat. Include a trackpad
gesture with momentum. The expanded visual reply keeps its own WebKit scrolling;
horizontal and modified chart gestures retain their normal interaction.

Send a new prompt while settings/runtime inventory is refreshing. Your saved
prompt should appear promptly and response updates should continue. If anything
is blank, record whether your own prompt is missing too and the approximate time.

For a failure, record:

```text
Harness / exact model / thinking level:
Prompt and step:
Expected behavior:
Observed behavior:
Relevant screenshot or short transcript excerpt:
Does reopening the chat change it?:
```

Post findings on PR #176 or in this chat. Live Pi/OpenCode family acceptance is
still pending this authenticated pass. iPhone/iPad simulator execution is also
unpassed because of the recorded Xcode service-hub failure; desktop testing does
not mark that platform check complete.
