# GitHub key and git identity

Settings → GitHub holds one SSH key and one commit identity (name and email)
for the user. The user enters them once, on any Mac, and manages them from any
Mac. Every Mac and Linux host stores the key; agents and bots never get it.
They get only a socket to a signing agent that holds it (the SSH agent
protocol, like 1Password's SSH agent), and the agent signs for a place only
while that place is on. Turning a place off stops it at its next git command,
and there is no copy to take back. The identity goes everywhere.

## Boundary

The goal is that agents use the key through the agent and that turning a place
off reliably stops them, not to defeat a determined agent: a leaked GitHub key
is replaced, not a disaster.

- **Macs** keep the key in Keychain, which agents cannot read.
- **Linux hosts** keep it in their library's sealed copy, opened by the
  library host and held in the Woven server's memory. Agents run as the same
  user, so one that went looking could in principle reach the library host's
  secret store; that is accepted.
- **Bot containers** never hold it.
- Between devices it travels sealed to each machine in the library record, so
  phones and other relays hold only ciphertext.

## What git sees

Each machine keeps a private (`0700`) directory with these files (`0600`):

| File | Present | Contents |
| --- | --- | --- |
| `ssh_config` | always | while the place is on: `Include github.conf`, then `Match host "!github.com,*"` with `~/.ssh/config` and `/etc/ssh/ssh_config`; otherwise only those two |
| `known_hosts` | always | GitHub's published host keys (`https://api.github.com/meta`) |
| `github.conf` | while on | `Host github.com`: `IdentityAgent <agent socket>`, `IdentityFile id_github.pub`, `IdentitiesOnly yes`, `UserKnownHostsFile known_hosts`, `StrictHostKeyChecking yes` |
| `id_github.pub` | while on | the public key (the private key is never written) |
| `gitconfig` | with an identity, or while on | `[user] name`, `email` (the fields that are set); while on, `[url "git@github.com:"] insteadOf = https://github.com/`, so HTTPS GitHub remotes use the key too |

Every session process gets a `GIT_CONFIG_COUNT` entry
`include.path=<dir>/gitconfig`, appended after any entries already present, and
`GIT_SSH_COMMAND="ssh -F <dir>/ssh_config"`, key or not, unless it already has
`GIT_SSH_COMMAND` or `GIT_SSH`. Without a key `ssh_config` holds only the user's
own settings, so ssh behaves as before, except that the variable outranks a
repository's `core.sshCommand`. Setting it always means a process started
before the key was saved (Pi Durable's worker on a Linux host, OpenCode's
service, a long build) uses the key on its next git command. github.com gets
the key and nothing else. Host keys are pinned, never trusted on first use.

The contents are identical in the three writers, which tests check:
`GitHubGitFiles` (Mac), `remote/src/github-identity.mjs` (Linux host) and
`bots/src/host/git.ts` (bot containers).

| Where | Directory | Agent socket | Environment |
| --- | --- | --- | --- |
| Mac | `~/Library/Application Support/Woven Matter/GitHub` (Dev profiles: `GitHub <profile>`) | `agent.sock` there, or `$TMPDIR/woven-github-<hash>.sock` when that path would pass Darwin's 104-byte limit | `WovenSessionEnvironment.apply` |
| Linux host | `<state directory>/github` (`~/.wovenmatter/github`) | `agent.sock` there | `nonInteractiveSessionEnvironment`, mirrored in `wm-exec` |
| Bot container | `/dev/shm/woven-github`, in the container's memory, owned by `bot` | `agent.sock` there, the relay's | the container's `Env` and the agent exec's |

## The signing agent

`SSHSigningAgent` (Swift) and `remote/src/ssh-agent.mjs` answer
`SSH_AGENTC_REQUEST_IDENTITIES` with the key (or nothing while the place is off)
and `SSH_AGENTC_SIGN_REQUEST` for that key's blob, with `rsa-sha2-256` and
`rsa-sha2-512` for RSA; everything else fails. They sign Ed25519, ECDSA
(P-256, P-384, P-521) and RSA keys in OpenSSH's unencrypted format. Settings
saves every key in that format (`ssh-keygen -p` rewrites a pasted PEM or
PKCS #8 key) and refuses one it cannot sign with. The socket is `0600`, and on
a Mac it accepts only this user's processes.

On/off is checked at every request: a Mac's agent signs while
`access.allows(<this Mac's device ID>)`; a Linux host's while
`access.allows(<its device ID>)`; a bot's request is answered while its machine
and the bot are both on.

## Where the key goes

The page lists every machine Settings → Bots knows (This Mac first, then the
other Macs, then Linux workspaces), each with its bots indented beneath it, and
a switch for each, This Mac included. `access` (`GitHubAccess`) records the
choices: `{newPlaces, places: {id: Bool}}`, where an ID is a machine's member
device ID or a bot's ID, and a place never switched follows `newPlaces` ("New
places get the key", on by default). Turning New places off first records every
listed place as it is, so only places added later follow it. A machine turned
off turns off its bots. A bot can be off while its machine is on. Any Mac can
change any place, since every Mac holds the key. A place that is offline stops
when it next syncs the record, from any device.

## This Mac

This Mac's place in the list is its member device ID, read from the library
itself, so whether it is on never waits for peer sync or sharing to start. The
background service owns the setting: Keychain item `global.github` under
`<Keychain namespace>.default-agent`, JSON `{key?, identity, revision, access}`,
where `revision` is milliseconds and orders changes across Macs. Settings
forwards `github.snapshot` and `github.command` (`generate`, `importKey`,
`removeKey`, `saveIdentity`, `setPlace`, `setNewPlaces`) over the private backend
transport. After any change, here or from another Mac, the service rewrites
the files and the agent's key (`GitHubSettingsModel.refreshAgent`); it checks
every minute that the agent's socket is still there. An item that cannot be
decoded counts as nothing set, so Settings can replace it; it never blocks Pi
Durable's other credentials.

## Sharing between machines

Two paired-library tables carry the setting; every member's library holds
them:

- `github_identity_recipients(device_id, payload)`: each Mac's and Linux host's
  X25519 sealing key, `{device, key, signature}`, signed with its member key
  over the canonical encoding with domain `woven.github.recipient`. The
  private half is Keychain item `global.github-sealing` on a Mac and the same
  item in the library host's secret store on Linux. A phone's row is ignored.
- `github_identity(singleton, payload)`: `{revision, author, identity,
  key? {publicKey, fingerprint, type, comment}, access?, sealed: [{device,
  recipient, ephemeral, box}], signature}`. Each sealed copy is the key's JSON
  in ChaCha20-Poly1305 under HKDF-SHA256 of an ephemeral X25519 agreement with
  that machine's sealing key (salt: both public keys; info and associated data:
  `woven.github.identity|<device>|<key fingerprint>`, so a copy stays valid
  when only the list or the identity changes). The author signs the
  sorted-key JSON without `signature`, after the domain
  `woven.github.identity` and a zero byte.

A record or recipient row that does not verify is not converted. A pairing
reset ([Woven everywhere](WOVEN_EVERYWHERE.md), "Pairing reset") deletes the
record and every recipient row from the device's library, without sending a
deletion, and keeps the device's own copy of the key and its sealing key.
Once devices are paired again each publishes its sealing key, and the Mac
that holds the key writes the record again through the reconcile below, so
the other machines get their copies with no step in Settings.

A recipient row counts only under the
device its signed payload names, and only for a current Mac or Linux member. A
record counts only when a current Mac member signed it; a record a Linux host
or phone writes is ignored, and a Mac that holds the key writes its own back.
After launch, after every peer sync batch and after a local change, each Mac
reconciles:

1. It publishes its sealing key if the table lacks it.
2. A verified record with a newer revision replaces this Mac's copy. Without a
   copy sealed to this Mac's current sealing key it still takes the record's
   list and identity: it keeps its key if the record has the same one (and seals
   itself a copy), and otherwise drops its older key and keeps its older
   revision, so the newer key is adopted once a copy arrives; Settings then says
   the key arrives when the other Mac is online.
3. A local copy newer than the record, or with no record to compare (changed
   offline, or after a pairing reset removed the record), is written as the
   record, sealed to every verified Mac and Linux host.
4. A Mac holding the current key seals copies for machines that have none, or
   whose sealing key changed (a reinstalled machine), and signs the record
   again.

Changes and reconciles on one Mac run one at a time. A change first catches up
with a newer record (as in step 2), so it never puts back what another Mac
changed, a removed key included. A Mac that does not hold the record's key yet
can still change the list or the identity: it writes the record with every
sealed copy carried over. Generating, pasting or removing a key is the user's
choice and goes ahead from any Mac. Identities
adopted from a record are validated again. Concurrent edits on two Macs
converge through the library's own conflict rule; the losing Mac adopts the
winner on its next reconcile.

## Linux hosts

The library host publishes the host's sealing key and opens its copy on request
(`GET /github` on its local socket, `GitHubIdentitySync.hostCopy`):
`{deviceID, sshKey: {privateKey, publicKey} | null, identity, access, revision}`.
The key is null until a Mac has sealed a copy to this host. The Woven server
asks every 5 seconds and when the library starts (`createGitHubService`), holds
the key in memory, serves the agent socket, and rewrites the files. A library
that is briefly unavailable leaves the last copy in place. No Mac needs to be
online: the copy arrives with library sync from any device, and the list does
too.

## Bots

`POST /bots-host/git` with `{botID}` returns `{publicKey, identity}`: the
public key while the bot's machine and the bot are on, otherwise null. The
runtime asks at most once a minute per bot, keeps the bot's last answer if the
host is briefly unreachable, and writes the files into the bot's container as
the bot user every time its agent starts and, when the answer changed, before
the bot's next command.

Before writing the files, the runtime makes sure the bot's relay
(`helper/ssh-agent.mjs`, as the bot user over a Docker exec) is listening on the
container's agent socket. Without a listening relay it writes the files without
the public key, so the container keeps the user's own SSH settings and HTTPS
remotes as they are; a relay that stops is started again before the bot's next
command (a failed start is retried after a minute). The relay passes each
request over its stdio to the runtime, which sends it to
`POST /bots-host/ssh-agent` (`{botID, message}` → `{message}`, base64
agent messages). The machine's agent answers it, checking the machine and the
bot each time. The key never enters the container. The files live in the
container's `/dev/shm`, so they never reach its disk or an update's snapshot.
Until they are written, the container's `GIT_SSH_COMMAND` runs plain ssh rather
than failing on a missing file. The relay is not counted as work when a bot
is checked for idleness.
