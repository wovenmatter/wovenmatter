# Executor apps

Woven Matter connects every supported agent to one managed
[Executor v2](https://v2.executor.sh/docs) runtime through its session-bound CLI.
An Executor **app** supplies capabilities backed by an API, one or more MCP
servers, or code. A saved **profile** chooses the accounts and configuration an
app uses. An app and an MCP server are not necessarily one-to-one.

## Setup

Open **Settings → Connections → Executor**. Choose **On this Mac**, then
**Install and start Executor**. Woven downloads the unchanged, pinned
`executor@2.0.0-beta.7` runtime and runs it alongside its background service.
Node is bundled; a separate Pi or Executor CLI installation is unnecessary.
Executor data and manager credentials live in Woven's private support directory,
separately from the workspace database. Installation progress and failures stay
visible in Connections, including after reopening the app.

For remote hosting, choose **On a Linux host** and select an existing discovered
machine or enter its SSH host and username. Use its private Tailscale HTTPS
origin, such as `https://machine.tailnet.ts.net:8443`. **Inspect host** uses
Woven's existing SSH inspection. An unprepared host requires explicit host
preparation; deployment rechecks it before proceeding.

**Deploy Executor** builds one standalone Docker container with persistent data,
a restart policy, and a private Tailscale Serve route on port 8443 to loopback
port 4312. It does not create an agent workspace. Existing unrelated containers,
ports and HTTPS routes are preserved. Docker and Tailscale must be available;
Woven's existing authorized preparation can install missing supported host
prerequisites. Woven does not expose Executor publicly through Funnel.

Both locations use the same Executor dashboard and account sign-in flow.
**Open dashboard** displays it inside Woven; **Open in browser** creates a fresh
paired browser session when a provider requires a normal browser. Sign in and
approve account consent yourself. The remote callback reaches the selected
Linux server's HTTPS origin; no headless account sign-in is required. Individual
providers may require that callback origin in their OAuth application settings.

Add apps and saved profiles in the dashboard, then **Refresh apps** in Woven.
Woven creates an explicit account-free profile for apps that require no account.
Apps requiring accounts become selectable after their profiles are configured.
Executor's bundled server-administration app is excluded: exposing it would let
an agent change its own app scope. Other Executor clients can connect separately
through the same dashboard; their scopes are independent of Woven conversations.

## Defaults and conversation controls

Executor starts **off**. Set the global default in Woven's Tools defaults, and
choose **Default apps for new conversations** in Connections. A new conversation
snapshots both settings. Changing defaults or adding apps does not grant them to
existing conversations.

In a conversation's composer, open **Tools → Executor** to turn access on or
off. Open **Apps** beside it to select apps, choose a saved profile when an app
has several, select all or deselect all, refresh the inventory, or open the
dashboard. Changes persist for that conversation and can be made between
messages. One saved profile per app is selected in this UI.

Whenever Executor is on, the agent can use its raw **Execute**, scoped tool
search and skills through the Woven CLI. Execute and search use only the selected
app profiles. Executor enforces the scope on each invocation, including guessed
or dynamically constructed tool names and actions resumed after approval. Full
access keeps the same scope. Turning Executor off blocks new CLI calls and
requests cancellation of active programs. Removing an app blocks subsequent
calls to that app; effects already completed cannot be undone.

These are capabilities enforced by Woven's CLI and Executor, not an operating
system sandbox against an agent or administrator with unrestricted access to the
host's credential files. Keep managed runtime data private and protect host
access as you would any other connected application's credentials.

## Approvals and requested input

Executor uses the conversation's confirmed permission mode:

- **Full access:** Woven accepts program and app-action approval requests without
  a notification. Explicit app-level denials remain denials.
- **Ask:** program approval and Executor app-action approval appear in the normal
  conversation request UI. Declining an action resumes the same program with
  that decision; Woven does not rerun its earlier steps.
- **Auto-edit or native smart review:** the harness keeps its native policy for
  its own tools. Executor's external actions use manual approval because that
  native reviewer cannot review an arbitrary gateway callback.
- **No-ask or genuinely read-only modes:** opaque Execute programs are denied.
  Scoped search and skills remain available. Codex's historical `read-only` wire
  value represents Woven's Ask preset and continues to request approval.

Forms and requested input always appear interactively, including in Full access.
Woven validates typed answers against the requested schema before resuming.
Changing permission mode while an Execute program is active cancels it rather
than continuing under a different policy. Stop uses the normal conversation
cancellation path. Cancellation is best effort for actions already dispatched;
check their external effects before starting a replacement program.

## Pi code mode

In **Settings → Built-in Agent → Pi code mode**, select:

- **On** (default): Pi code mode alongside the ordinary file, shell and web tools.
- **Only:** Pi presents ordinary tools through code mode.
- **Off:** the code mode tool is unavailable.

Code mode calls the same guarded tools, so nested shell and write calls retain
normal conversation approval. Woven still disables user Pi extensions and
supplies its own tool list. This setting applies to Built-in's Pi SDK and follows
its global/workspace inheritance; changes apply to subsequent turns. It does not
control Executor Execute, which belongs to the Executor conversation switch.

## CLI and recovery

Agents receive the same session-bound CLI across built-in and external harnesses,
including remote agent workspaces. Use `wovenmatter executor help` for commands.
A typical sequence is:

```sh
"$WOVENMATTER_CLI" executor search --query "capability to find"
"$WOVENMATTER_CLI" executor status JOB_ID
"$WOVENMATTER_CLI" executor execute --file /path/to/program.js
"$WOVENMATTER_CLI" executor status JOB_ID
```

Search and Execute return a job ID immediately; poll status until `completed`,
`cancelled` or `interrupted`. Search results contain exact callable paths and
signatures. Programs use Executor's sandbox, without imports, network globals or
host filesystem access. `completed` means the program finished: inspect
`result.execution.ok` and its result/error before treating it as successful.
Approvals and input are resumed by Woven; agents never receive continuation
credentials or a command to answer their own approval requests.

Reuse `--request-id UUID` with identical code after a lost receipt. Stored IDs
prevent replay across background-service restarts. An interrupted or uncertain
program may have completed earlier external actions: inspect those effects,
then explicitly start new work. In-memory Executor continuations do not survive
an Executor restart. Woven retains receipts, not durable program execution.
Older large output bodies may be retired while their replay-prevention IDs stay.

Woven's remote CLI relay still requires the Mac background service. Hosting
Executor on Linux does not remove that requirement. Separate clients using the
remote Executor endpoint directly can operate independently of Woven.

Executor Cloud authentication and Pi Durable are outside this integration.

## Validation

`scripts/test-changes.sh --all` covers native compilation, persisted defaults,
bound CLI identity, every harness's permission mapping, code mode's nested tool
approvals, manager receipts, typed input, and deterministic deployment fixtures.
CI additionally builds the standalone Linux image and runs
`scripts/test-support/test-executor-runtime.mjs` against its unchanged published
Executor binary. The fixture uses synthetic account-free apps and no provider
services. The same test runs on macOS with a published Executor entrypoint:

```sh
node scripts/test-support/test-executor-runtime.mjs /path/to/executor/bin.mjs
```

Before release, test local installation/dashboard and remote Linux deployment
with your real environment, finish account OAuth yourself, and exercise a read
and write with your chosen apps. Verify a deselected app is unavailable, Full
access skips action approvals, Ask prompts, requested input remains interactive,
and changes or Stop during a pending action do not execute it later. Repeat with
harnesses you use; provider entitlement and individual app behavior require live
acceptance beyond the provider-free fixtures.
