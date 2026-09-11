# OpenCode v2 test handoff

Build this PR with the usual entrypoint. An optional variant keeps Woven Matter's Dev database and process separate from another Dev build:

```sh
WOVENMATTER_DEV_VARIANT=OpenCode \
WOVENMATTER_DEV_CACHE_DIR=/private/tmp/wovenmatter-opencode-dev \
  scripts/build_and_run.sh
```

The app is `Woven Matter OpenCode Dev.app` under that cache's `DerivedData/Build/Products/Debug` folder. The variant isolates only Woven Matter's database/settings; it connects to the standard local OpenCode service and data, not an isolated OpenCode test server.

## Test

1. In Settings → Local Agent Workspace, an absent v2 CLI should show **Download**. It installs `@opencode/cli@0.0.0-beta-19278` and changes to **Enable**, without enabling automatically. Existing installations show Enable/Disable. OpenCode and OpenClaw both have **More** to the left of Show/Hide.
2. Enable OpenCode, then open More or Settings → OpenCode (below OpenClaw). Connect reuses the standard local service or starts it if absent. **Open in browser** opens that service without a manual sign-in prompt. Configure provider accounts in OpenCode itself.
3. Use New Chat → OpenCode. The session must use the Woven Matter workspace root (`~/.woven-matter` by default). The default model must appear before the first message.
4. Check model and thinking selectors in compact and expanded composers. Select a model and supported reasoning variant before sending. Changing models must not retain an unsupported variant. In Manage models, deselect models and confirm they disappear from Woven Matter's choices; checked models sort above unchecked models. Existing chats retain their selected model.
5. Verify General/agent, Queue/Steer, Session, and Browse controls are absent. There are no remote-server, registration-path, workspace-path, or service-password fields.
6. Send a message in a disposable session. Open the same backend session in the browser. Verify both clients' text, tool activity, attachments, permissions, and question replies appear. Include a conditional multi-select question. Avoid sending from both clients simultaneously when checking model selection.
7. Disable OpenCode: Woven Matter disconnects and the browser remains connected. Enable again: Woven Matter reconnects. **Stop server** disconnects all clients and keeps Woven Matter from automatically restarting it; **Restart server** restores the connection. Stop active work before testing these shared server controls.
8. With **Start on launch** off, quit Woven Matter and stop the server separately, then reopen: it must stay stopped until Connect. With the option on and OpenCode enabled, reopening starts the server. With **Stop on quit** off, normal quit preserves the server; with it on, normal quit waits for the server to stop. Force Quit cannot run shutdown handlers. Restore the preferred settings afterward.
9. Scroll a long conversation to load older messages, including while new messages arrive. Reconnect after edits from the browser. Confirm no duplicate prompt submission after an interrupted request. Historical v1 and earlier custom-server transcripts remain readable; new work requires new local v2 chats.

Provider-backed testing is human acceptance and must not be included in automated tests. The installed OpenCode desktop client must itself support v2 to validate shared v2 sessions; a v1 desktop is not a substitute.

See [PARITY.md](PARITY.md) for the implementation boundary and persistence contract.
