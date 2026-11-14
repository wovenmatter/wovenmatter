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
   - **Download & pair** when it isn't installed, or **Update & pair** when it
     is too old. Woven Matter downloads and verifies the current release on that
     Mac first.
   - **Update to** a version number to install a newer release on that Mac.
   - **Download** or **Open Woven Matter** when its version can't be paired
     from here. Finish pairing in Apple Devices on that Mac instead.
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
synchronize after approval.

## Remove a device

Under **Paired devices**, choose **Unpair device**. Removal is signed by this
Mac, and every device applies it as soon as it synchronizes. Until every
workspace has received it, the device stays under **Pending revocations** with
the workspaces it is **Waiting for**. Unpairing on an iPhone or iPad removes
it the same way, through any of your Macs it can reach.

## Keep your library in sync

Paired devices synchronize only when they run matching versions, because their
libraries must use the same format. When a device falls behind, **Apple Devices**
shows **Versions don't match**, and **Synchronization needs attention** names the
device that needs updating. Your own writing is saved while synchronization
waits.

Choose **Versions don't match** to open Settings → Updates, then **Update
everything**. It updates this Mac first when a newer release is out, then each
Linux host, your other Macs, and every harness. You can also update a single
device or harness on its own. See [Updates](updates.md).

## iPhone (beta)

The iPhone app is a beta available through TestFlight, not yet generally
available. It pairs by scanning a QR code from **Show a QR code or link** on a
Mac, and then works with your own Macs and Linux hosts over your own tailnet.
Its Quick Chat runs Pi Durable on the phone.

To try it, email trey@wovenmatter.com with the email address to add as a
TestFlight tester.

Next: [Remote workspaces](remote-workspaces.md) or [Bots](bots.md).
