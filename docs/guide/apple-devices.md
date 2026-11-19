# Apple devices

Pair your Macs so they share one library. Each Mac keeps a complete copy of your
notes, chats, Library files, settings, and connections, and can add workspaces
or more devices. No single Mac has to stay on: changes made offline synchronize
when the Macs reconnect.

Paired devices reach each other directly over your own Tailscale network. Each
device has its own signing key, and every request between devices is signed
with it. Linux machines are added separately, in Settings → Workspaces; see
[Remote workspaces](remote-workspaces.md).

## Pair a Mac

Both Macs need Tailscale connected to the same tailnet. Open **Settings → Apple
Devices** and use one of the options under **Pair a device**.

### Find on your network

1. Open **Find on your network** and choose **Find devices**. It lists the other
   Macs on your tailnet, even when Woven Matter is closed or not installed on
   them.
2. Choose the action the row offers:
   - **Pair** when Woven Matter is installed.
   - **Download & pair** when it isn't installed. Woven Matter downloads and
     verifies the current release on that Mac first.
   - **Update to** a version number to install a newer release on that Mac.
3. Woven Matter opens on the other Mac and sends a pairing request. Approve it
   under **Pairing requests** on this Mac.

Checking, downloading, and opening the app on the other Mac uses this Mac's
existing SSH access over Tailscale. If the row shows **Installation status
unavailable**, open **Connection settings** to enter an SSH host alias or user,
then choose **Check installation**. Woven Matter never asks for a password; set
up SSH access on the other Mac first if it is missing.

### Use a link or QR code

1. On one Mac, open **Show a QR code or link** and choose **Create QR code or
   link**. Choose **Copy pairing link** to copy it. The code expires; choose
   **New code** for a fresh one.
2. On the other Mac, open **Paste a pairing link**, paste the link, and choose
   **Pair Mac**.
3. Approve the request under **Pairing requests** when it appears. **Decline**
   refuses it.

Either Mac can start pairing. Both keep their existing libraries and
synchronize after approval. Each Mac then lists the other under **Remote
workspaces** in the sidebar, with its agents and folders; see
[Workspaces and storage](workspaces.md).

## Remove a device

Under **Paired devices**, choose **Unpair device**. Removal is signed by this
Mac, and every device applies it as soon as it synchronizes. Unpairing on an
iPhone or iPad removes it the same way, through any of your Macs it can reach.

## After an update resets pairing

Some updates change how devices recognize each other. After one, each device
forgets its pairings and you pair them again. Nothing else changes: your
chats, notes, folders, and workspaces stay where they are.

- **On each Mac**, Settings → Apple Devices shows **Pairing was reset by this
  update** and lists no paired devices. Update every Mac first, then pair them
  again from either one, as in [Pair a Mac](#pair-a-mac). You don't need to
  unpair anything. Until two Macs are paired again, each still lists the
  other's workspace in the sidebar, marked as not recognizing this Mac.
- **On iPhone and iPad**, Home shows **Pair again**. Scan a new code from any
  Mac. Everything on the device is kept.
- **Linux hosts** need nothing from you. The Mac that set a host up connects
  it again once both are updated.
- **Your GitHub key** is shared again by the Mac that holds it once your
  devices are paired.

## Keep your library in sync

Keep every paired device on the same version of Woven Matter, and update them
together. While one device is still waiting for its update, **Apple Devices**
shows **Versions don't match**, and changes that device can't use yet are
kept and appear on it once it is updated; **Synchronization needs attention**
says how many are waiting. Nothing is lost, and your own writing is saved
meanwhile.

Choose **Versions don't match** to open Settings → Updates, then **Update
everything**. It updates this Mac first when a newer release is out, then each
Linux host, your other Macs, and every harness. You can also update a single
device or harness on its own. See [Updates](updates.md).

## iPhone (beta)

The iPhone app is a beta available through TestFlight, not yet generally
available. It pairs by scanning a QR code from **Show a QR code or link** on a
Mac, and then works with your own Macs and Linux hosts over your own tailnet.
Its Quick Chat runs Pi Durable on the phone. Pages are fully editable on iPhone
and iPad, by hand or through Quick Chat; see [Pages](../PAGES.md).

To try it, email trey@wovenmatter.com with the email address to add as a
TestFlight tester.

Next: [Remote workspaces](remote-workspaces.md) or [Bots](bots.md).
