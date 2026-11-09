# Quick Chat lifecycle

Quick Chat is a small foreground conversation feature on iPhone and iPad,
powered by Pi Durable running in the app process. It edits notes, searches and
reads the public web, answers simple questions, and sets timers, reminders and
calendar events. Model connections and search keys are signed in on the device.
It has no shell, file tools, Python/WASM, code mode, MCP code executor, subagents,
goals, browser automation or computer control. New chats start in Full Access;
Ask for Approval remains a per-chat choice.

## Web search

`web_search` and `web_read` use whichever search provider the user connected
under Settings → Connections → Web search: Exa, Brave Search or Firecrawl. Request
shapes match `default-agent/src/search.mjs`. Brave can search but not read pages,
so reads use the next connected provider that can. With several connected, the
user picks which one searches first. Keys are separate device-only Keychain
items, like the model connections; there is no separate data-sharing prompt.
Page reads never target local, link-local or Tailnet hosts.

## Timers and reminders

`woven_timers_*` are this phone's timers and reminders. A timer fires once; the
phone rejects `every` and offers a scheduled task on a Mac or Linux workspace for
recurring agent work. Each timer:

1. Is mirrored as a regular calendar event, so it synchronizes with the library
   through the calendar outbox and appears on every device's calendar. Deleting
   that event elsewhere removes the timer; a delivered timer keeps its event.
2. Becomes a local notification (`UNUserNotificationCenter`) that fires even when
   the app is closed. Tapping it opens the chat that set the timer.
3. Reaches its chat when the app is next in the foreground: the timer's text is
   submitted through the durable inbox and the agent acts then. iOS does not run
   the agent in the background.

The phone never runs calendar tasks. Earlier phone-owned scheduled tasks stay
visible; saving one with a Mac or Linux agent retires it and creates a replacement
without a device owner, keeping deleted and already-run occurrences out of it.

## Backgrounding

When the app backgrounds, a short `UIApplication` allowance lets it save and
interrupt an in-flight response. Saved request identities and receipts survive
reopening. Resume is explicit and cannot race interruption cleanup. There is no
continued-processing task registration or background agent promise.

Earlier device-agent conversations are retained as history. Their saved runtime
checkpoints are not opened or resumed as Quick Chat; their saved files stay
readable and exportable. Other devices see a phone's Quick Chats as read-only
synced history and cannot run or steer them.

## Validation

Package tests cover the Quick Chat tool boundary, the three search providers with
fixture transports, timer-to-calendar mirroring and notification planning, and
backup flags. App-hosted tests cover permission defaults, retained history and
routing. The Debug-only `WOVENMATTER_DEVICE_RUNTIME_SMOKE=1` mode runs the bundled
SDK with synthetic inference and an isolated local note store, and writes its
report to `Documents/runtime-smoke.json`. Notification delivery while the app is
closed, real sign-ins and physical-device network transitions remain manual checks.
