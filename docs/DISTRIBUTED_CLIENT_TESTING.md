# Distributed client acceptance

Manual acceptance for Macs, Linux hosts, and the iPhone app (beta) working
together. Use Mac, Linux host, and iOS builds from the same revision: peers
must have matching library schemas to sync, and updating one device does not
update the others. Start with two Macs and a Linux host, then add an iPhone,
then iPad layout and real network transitions.

## Build and automation

See [build and run](../README.md#build-and-run) for the Mac and
[iOS setup](../ios/README.md) for the phone. User acceptance uses the normal Dev
app and the user's existing data; disposable tests use a distinct `--instance`.
Never pair or unpair a user's device as part of a build or install. Users
complete provider sign-in themselves.

`scripts/test-changes.sh --all` runs source checks, native, runtime, and remote
fixtures, Swift packages, builds, integration tests, and iPhone/iPad app-hosted
UI tests. `--cross-device` and `--cross-device-desktop` run the cross-device
integration suites. Fixtures use synthetic libraries and providers. Compilation
and fixtures do not prove UI, Tailscale, or real-account acceptance.

## Membership and pairing

1. On a Mac, open **Settings → Apple Devices → Pair a device**. Pair a second
   Mac through **Find on your network** (**Pair**, or **Download & pair** when
   Woven Matter is not installed there), by approving a request under
   **Pairing requests** on the other Mac, and with **Paste a pairing link**.
   Discovery alone grants no access. Both Macs keep their full app and
   existing library.
2. Repeat lost confirmation, restart during setup, an expired link, a duplicate
   request, and pairing with a Mac of a different library. A pending pairing
   must not appear paired or grant data access. Interrupted setup must leave
   the installed app and both libraries intact.
3. Add a Linux host from either Mac in **Settings → Workspaces**. Then manage it
   from the other Mac under **From other devices**: refresh status, restart,
   update, and logs must work without the installing Mac online.
4. Pair an iPhone with any Mac. Confirm it appears as a member on every Mac and
   the Linux host after they sync.
5. Use **Unpair device** on one Mac. Reachable devices must refuse the removed
   device's requests as soon as they sync; a device that was offline must apply
   the revocation when it returns. Ordinary network loss must not remove anyone.
   Re-pairing must add the device again with its current key.

## Library sync

- Create notes, folders, and calendar events on each device while the others
  are offline; reopen the app, reconnect, and verify they converge. Edit while
  an earlier change is still in flight.
- Edit the same note on two Macs while disconnected, then reconnect. Both
  versions must remain, with a **Recovered edit** copy. Deleting an item never
  resurrects its identity. One conflict or an interrupted file transfer must not
  block other changes.
- Save an artifact, interrupt its transfer, reconnect, and verify exact bytes.
  Workspace files and runtime checkpoints stay with their owner.
- Run devices on different versions. Each must show which part needs updating
  and link to Settings → Updates, whose **Update everything** brings every
  device up to date; after updating, sync resumes.
- With the iPhone's paired Mac offline, the phone must sync with another Mac or
  the Linux host. Nothing on the phone should wait for its paired Mac.

## Sessions across machines

1. For each harness, create, send, reopen, change model, effort, and tools,
   answer approvals and questions, and Stop, on a local workspace, another Mac,
   and the Linux host. New chats keep the right workspace root, their own
   scratch directory, and a fixed owner after send. Archived chats from retired
   harnesses stay readable and cannot run.
2. Open a session on another machine. The reply must stream live, and
   questions, approvals, and setting changes must arrive without polling.
   Close it and confirm its history still arrives through library sync.
3. Take a machine offline. Its sessions must show saved history marked offline,
   and the stream must reconnect by itself when it returns.
4. With every Mac but one offline, have an agent on the Linux host create,
   message, and stop a session on another workspace through Woven MCP.
5. Interrupt an accepted command's reply and restart either side. The original
   receipt must be recovered without duplicate execution. A stale Stop or
   approval must never affect a newer run.

## iPhone app (beta)

- Check Home, Folders, Chats, Notes, and Settings; opening a folder stays inside
  Folders with Back, and Trash sits at the bottom of Folders. Home leads to
  Calendar, Scheduled tasks, Library, Databases, and Usage once paired.
- Unpaired, the app must work on its own: Quick Chat, notes, folders, calendar,
  timers and reminders, and dictation, with **Connect your Mac** in Settings and
  no connection banner. Pairing later must keep everything local.
- Add a provider connection and a web search key in Settings. Test sign-in
  cancellation, invalid or expired credentials, persistence, and token refresh.
  Keys and tokens stay on the device and never appear in logs or synced data.
- Run Quick Chat with other devices disconnected: notes, web search and read,
  questions, timers and reminders, calendar, Stop, and explicit resume after
  backgrounding. Model selection must survive catalog outages. Quick Chats
  appear on other devices as read-only history.
- Start and control sessions on a Mac and on the Linux host from the phone.
  Closing the phone must not stop them.
- Exercise rotation, iPad sidebar and compact windows, Markdown, and collapsed
  tools. The keyboard opens on field tap and dismisses on outside tap without
  discarding writing.

## Acceptance boundary

Automated tests cover persistence, receipts, signed authorization, history
replay, conflicts, cancellation, and artifact integrity. Real provider plans and
sign-in, Tailscale ACLs, multi-Mac behavior, physical iPad layout, and
notifications while the app is closed need the corresponding devices and
accounts. Record those results in the PR description, separate from build and
fixture success.
