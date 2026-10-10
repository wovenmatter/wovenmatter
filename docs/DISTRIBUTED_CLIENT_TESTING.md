# Distributed client testing

Use the Mac and mobile builds from the same PR revision. Start with the iPhone
simulator, then iPad layout, then physical devices and network transitions.
Keep UI fixtures separate from the devices used for real pairing.

## Isolated builds

```sh
scripts/build-companion-desktop.sh build
scripts/build-ios.sh
scripts/build-ios.sh --device-compile
```

The desktop helper builds a distinct signed **Woven Matter Companion Test.app**.
Its `run` mode opens a separate test workspace and leaves production data alone.
An already installed CMake can be selected with `WOVENMATTER_CMAKE`. Existing
Apple signing assets are required; these commands do not sign in to accounts.

For visual iteration, launch the iOS development app with
`WOVENMATTER_UI_FIXTURE=1` and a stable `WOVENMATTER_UI_FIXTURE_NAMESPACE`. Fixture
writing persists across rebuilds, but pairing and agent execution are disabled.
Use another simulator without these variables for connected acceptance.

## Phone UI, then iPad

- Home, Folders, Chats, Notes, Settings appear in that order on the phone.
  Open a folder, inspect its contents, then return to the folder list.
- Create and edit a note, dismiss its keyboard, change tabs, and reopen it.
  Check rich text, existing tables, linked documents, conflict recovery, and
  export. Unsupported document structures must retain their original data.
- Check chat scrolling, drafts, note references, execution workspace selection,
  pending approvals/questions, session settings, and Stop.
- Open Library, saved artifacts, Calendar, and Trash. Exercise rename, move,
  pin, trash, and restore on test content.
- Repeat on iPad in portrait, landscape, and a compact window. Confirm sidebar
  selection and editing survive layout changes. Both apps use the green cube.

## Central library and direct execution

1. In the isolated central Mac app, open **Settings → Devices**, start sharing,
   and create a pairing link. Pair each test client with its own fresh link
   while all devices are on the same Tailscale network.
2. Synchronize a note in both directions. Disconnect, edit on both sides, reopen
   the client, and reconnect. Resolve the visible conflict; no writing should
   disappear. Delete a central note that has unsynced client writing and verify
   recovery preserves that writing.
3. Authorize a Linux or secondary Mac workspace while the central Mac is online.
   Start and control a test conversation directly. Stop central sharing and
   continue controlling that workspace. Reconnect and compare the resulting
   transcript and activity from a second client.
4. Interrupt the response to a send, then reopen. Recover its existing receipt;
   do not create a second send to guess whether the first was accepted. Test
   Stop and approvals after switching the selected conversation.
5. Open an idle pre-existing remote conversation on the central Mac. Its native
   session is adopted by the direct workspace service. Existing active native
   work must finish before ownership transfers; a failed transfer stays fenced
   and retries the same adoption instead of starting another owner.
6. Save a workspace output to the shared library. Interrupt and resume its
   transfer, open it on another client, and compare contents. Repositories,
   ordinary workspace files, and runtime checkpoints remain on their owner.
7. Revoke a test device, including while a workspace is unreachable. Central
   access ends immediately; remote revocation remains visibly pending until
   acknowledged. Re-pair that same device and verify the old bearer remains
   rejected while the replacement works.

## Pi Durable on iPhone and iPad

Configure a supported API-key connection, or select an authorized inference
host with an existing provider account and model. Select **This iPhone** or
**This iPad** for execution. A subscription adapter performs inference only;
the agent loop, native tools, code execution, and checkpoints remain on iOS.

- Import a small text file; ask the agent to read it and create a local output.
  Exercise native note tools and save an output to the shared library.
- Select an image-capable model, import a disposable test image, and ask the
  on-device agent to describe it. The image-reading tool result goes only to
  that run’s selected cloud or Tailscale inference connection.
- Check permission prompts, a subagent, and code mode using only disposable test
  content. Stop while a tool is waiting for approval; cancelled work must not
  perform a later mutation.
- Background and reopen the app. Resume retained work explicitly. Repeat after
  terminating the app while a response is arriving. A stopped run must stay
  stopped after relaunch, including a Stop interrupted before acknowledgement.
- Stop central sharing while the chosen inference endpoint remains reachable.
  Continue locally, then reconnect and inspect the complete history elsewhere.
- Test the selected real provider account separately. Automated fixtures do not
  establish provider billing, subscription eligibility, or tailnet reachability.

The Debug-only `WOVENMATTER_DEVICE_RUNTIME_SMOKE=1` launch mode exercises the
actual bundled SDK, a controlled native inference stream, local file read/write,
checkpoint reopening, duplicate submission recovery, and isolated WebKit code
execution with persisted code state. It writes `Documents/runtime-smoke.json`
and uses neither network nor Keychain. Relaunch without that variable afterward.

## Secondary Mac

Pair from **Settings → Devices → Use another Mac’s central library**, then choose
**Use as client and restart**. Check offline notes and drafts, the same library
views, and direct execution. Optionally enable **Execution on this Mac** in client
Settings and configure its agents and connections. Sharing this execution
workspace is a separate explicit action.

Try returning to this Mac’s previous library and quitting with active work.
Unsafe transitions must be refused; failed transitions must restore access.
The original library and the paired replica remain separate throughout.

## Automated gates and remaining acceptance

`scripts/test-changes.sh --all` covers source checks, runtime and remote fixtures,
Swift packages, native builds, shared contracts, and mobile integration suites.
The fixtures exercise durable receipts, complete history/chunk replay, scoped
authorization, restart recovery, conflicts, cancellation, and artifact integrity.
They never consume provider services or modify a personal library.

Successful compilation, portable tests, and the runtime smoke are distinct from
app-hosted XCTest, real provider acceptance, and physical-device acceptance.
Record any toolchain test-runner failure explicitly. Do not infer unlimited iOS
background execution or working real network access from a simulator build.
