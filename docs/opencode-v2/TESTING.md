# OpenCode v2 test handoff

Build this PR with the usual entrypoint. An optional variant keeps Woven Matter's Dev database and process separate from another Dev build:

```sh
WOVENMATTER_DEV_VARIANT=OpenCode \
WOVENMATTER_DEV_CACHE_DIR=/private/tmp/wovenmatter-opencode-dev \
  scripts/build_and_run.sh
```

The app is `Woven Matter OpenCode Dev.app` under that cache's `DerivedData/Build/Products/Debug` folder. The variant isolates only Woven Matter's database/settings; it connects to the standard local OpenCode service and data, not an isolated OpenCode test server.

## Test

1. Install the supported OpenCode v2 CLI (`@opencode/cli@0.0.0-beta-19278`, executable `opencode2`) if it is not already installed. Configure provider accounts in OpenCode itself.
2. In Woven Matter, open Settings → Local Agent Workspace. OpenCode should show only its local connection status and **Connect**. Connect should discover the existing standard service or start it automatically.
3. Use the usual New Chat → OpenCode flow. The new session must use the Woven Matter workspace root (`~/.woven-matter` with the normal configuration).
4. Check the model and thinking selectors inside the existing composer, including compact and expanded layouts. Select a model and one of its supported reasoning variants. Switching to another model must not retain an unsupported variant.
5. Verify that General/agent, Queue/Steer, Session, and Browse controls are absent. There are no remote-server, registration-path, workspace-path, or service-password fields in the OpenCode settings card.
6. Send a message. Open the same backend session through a v2-capable OpenCode client connected to the standard service. Verify changes from both clients appear, including tool activity and permission/question replies.
7. Quit/reopen Woven Matter. It should reconnect to the same service without terminating it. If the service is absent, connecting or creating a chat should start it. Use a disposable session to test connection loss during execution and confirm there is no duplicate prompt submission.
8. Scroll through a long conversation to load older messages. Check attachment presentation. Historical v1 and earlier custom-test-server transcripts remain readable; start a new local v2 chat for new work.

Provider-backed testing is human acceptance and must not be included in automated tests. The installed OpenCode desktop client must itself support v2 to validate shared v2 sessions; a v1 desktop is not a substitute.

See [PARITY.md](PARITY.md) for the implementation boundary and persistence contract.
