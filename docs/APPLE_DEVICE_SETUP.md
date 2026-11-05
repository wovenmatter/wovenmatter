# Finding and setting up Macs

Settings → Apple Devices → Find devices lists other macOS peers reported by the
connected Tailscale client. Woven Matter does not need to be running or installed
on those Macs. Offline Macs remain visible. A successful search with no matching
peers shows **No Macs found**; Tailscale failures show an error instead.

Each online Mac is inspected through existing SSH access to show its installed
Woven Matter version and build. A failed inspection is **Installation status
unavailable**, never **Not installed**. Connection settings accepts an SSH config
alias and optional user, so existing identities and custom SSH ports still work.
The transport is always pinned to the peer's current Tailscale address using
`tailscale nc`; SSH config cannot redirect it onto a LAN or public connection.
Unknown host keys and unavailable credentials require the user to establish SSH
access outside the app. The app never requests a password or starts account login.

- **Pair** opens an installed app and starts the existing approval flow.
- **Download & pair** downloads and verifies the current published release,
  installs it, opens it, and starts pairing.
- **Update to [version]** installs a newer published version. Older installations
  offer **Update & pair** only when the published manifest advertises the remote
  pairing helper. Releases without that capability offer Download/Update and
  Open Woven Matter for manual pairing. The downloaded signed app is checked for
  that capability before replacement when a combined action was selected.

Either Mac can initiate pairing. Both continue running their full local desktop
app, preserve their existing libraries, and synchronize shared data after approval
on the other Mac. Pairing does not change a database role or restart into a node
interface. An already paired Mac can add another Mac or an iPhone/iPad; its new
connections and remote workspace inventory propagate to the other paired Macs.
Both Macs must advertise the paired-library protocol; older apps need updating.

Remote setup uses a short-lived, nonsecret intent in the SSH user's app preferences.
The receiving GUI consumes it after startup; pairing credentials stay in the
existing device-only vault. Both cold launch and an already running app are supported.

Each intent and status carries a request ID. Progress from an earlier request
does not complete a later attempt. Consuming an intent checks that a newer one
has not replaced it during a restart or shutdown. Snapshot builds identify their
isolated database explicitly in the pairing confirmation.

## Download and update boundary

The published `latest-mac.json` supplies the version, build, exact GitHub release
asset URL and SHA-256. Downloads use HTTPS, verify that hash, verify the complete
app signature against `wovenmatter.desktop` and publisher team `3M84Q9NAMN`, and
pass Gatekeeper assessment before replacing any installed app. The candidate's
version and build must match the reviewed release. A newer installed build is
never downgraded. The current release supports Apple Silicon and macOS 26+.

Installation uses a private temporary mount and a staged copy next to the target.
An unwritable system Applications folder uses the user's Applications folder for
a first installation. Existing installations are updated in place only when the
SSH user has permission. A failed replacement restores the previous app. No sudo,
credential copying, public sharing, or forced process termination is used.
An owned process lock serializes installations. Signal handlers clean up interrupted
attempts and release the lock; a stale process lock can be reclaimed on retry.

New versions prepare their own shutdown using the same write-flushing and backend
handoff used for desktop updates. Legacy apps receive an ordinary Quit request;
if an old background server remains running, the row asks the user to stop it on
that Mac and retry. Setup requires that the SSH user is also the signed-in console
user so the app can open in the correct desktop session.

## Validation

Provider-free fixtures cover Tailscale inventory, offline/empty/error states,
stopped/missing/uninspectable installations, transport pinning, release validation,
setup expiry, and remote error propagation. A real Mac inspection can verify the
installed version without launching or modifying its app. Downloading, updating,
or pairing a user's actual Mac is a separate explicit action, never part of an
automatic discovery check.
