# GitHub key and git identity

Settings → GitHub holds one SSH key and one commit identity (name and email)
for the user. Every git command Woven runs uses them: sessions on this Mac,
sessions on the user's other Macs, Linux workspaces and bots machines, and
bot containers. The user enters them once, on any Mac.

## What git sees

Each machine keeps a private (`0700`) directory with these files (`0600`):

| File | Present | Contents |
| --- | --- | --- |
| `ssh_config` | always | with a key: `Include github.conf`, then `Match host "!github.com,*"` with `~/.ssh/config` and `/etc/ssh/ssh_config`; without one, only those two |
| `known_hosts` | always | GitHub's published host keys (`https://api.github.com/meta`) |
| `github.conf` | with a key | `Host github.com`: `IdentityFile id_github`, `IdentitiesOnly yes`, `UserKnownHostsFile known_hosts`, `StrictHostKeyChecking yes` |
| `id_github`, `id_github.pub` | with a key | the key pair |
| `gitconfig` | with an identity | `[user] name`, `email` (only the fields that are set) |

Every session process gets a `GIT_CONFIG_COUNT` entry
`include.path=<dir>/gitconfig`, appended after any entries already present;
git ignores the include while there is no identity, and otherwise it outranks
a repository's own `user.*`. A process started while a key is saved also gets
`GIT_SSH_COMMAND="ssh -F <dir>/ssh_config"`, unless it already has
`GIT_SSH_COMMAND` or `GIT_SSH`. That variable outranks a repository's
`core.sshCommand`, which is why it is set only with a key. A running session
picks up a changed key, a removal or a new identity on its next git command; a
process started before the first key was saved gets the key when it next
starts (Linux hosts build the environment for every launch). With a key,
github.com gets it and nothing else, and every other host keeps the user's own
settings. Host keys are pinned, never trusted on first use. Bot containers
always get both variables: the container is Woven's.

The contents are identical in the three writers, which tests check:
`GitHubGitFiles` (Mac), `remote/src/github-identity.mjs` (Linux host) and
`bots/src/host/git.ts` (bot containers).

| Where | Directory | Environment |
| --- | --- | --- |
| Mac | `~/Library/Application Support/Woven Matter/GitHub` (Dev profiles: `GitHub <profile>`) | `WovenSessionEnvironment.apply` |
| Linux host | `<state directory>/github` (`~/.wovenmatter/github`) | `nonInteractiveSessionEnvironment`, mirrored in `wm-exec` |
| Bot container | `/home/bot/.woven-github`, a tmpfs owned by `bot` | the agent exec's `Env`, inherited by every command |

## Keys

Settings generates an Ed25519 key (`ssh-keygen -t ed25519`, comment
`woven-matter`) or takes a pasted OpenSSH private key, which `ssh-keygen -y`
must read without a passphrase: nobody may be at the machine to type one. The
fingerprint is SHA-256 of the public key blob, as GitHub shows it. Settings
shows the public key, its fingerprint, Copy public key and Add key on GitHub;
the private key is never shown again.

## This Mac

The background service owns the setting: Keychain item `global.github` under
`<Keychain namespace>.default-agent`, JSON `{key?, identity, revision}`, where
`revision` is milliseconds and orders changes across Macs. Settings forwards
`github.snapshot` and `github.command` (`generate`, `importKey`, `removeKey`,
`saveIdentity`) over the private backend transport. A save rewrites the files
and changes Pi Durable's credential revision, which sends the setting to Linux
hosts. An item this build cannot decode counts as nothing set, so Settings can
replace it; it never blocks Pi Durable's other credentials.

## The user's other Macs

Two paired-library tables carry the setting; every member's library holds them
(library schema step 2 adds them to a v0.4.3 library; a device still on
v0.4.3 keeps their records waiting until it updates):

- `github_identity_recipients(device_id, payload)`: each Mac's X25519 sealing
  key, `{device, key, signature}`, signed with its member key over the
  canonical encoding with domain `woven.github.recipient.v1`. The private half
  is Keychain item `global.github-sealing`.
- `github_identity(singleton, payload)`: `{version, revision, author, identity, key?
  {publicKey, fingerprint, type, comment}, sealed: [{device, recipient,
  ephemeral, box}], signature}`. Each sealed copy is the key's JSON in
  ChaCha20-Poly1305 under HKDF-SHA256 of an ephemeral X25519 agreement with
  that Mac's sealing key (salt: both public keys; info and associated data:
  `woven.github.identity.v1|<device>|<revision>`). The author signs the
  sorted-key JSON without `signature`, after the domain
  `woven.github.identity.v1` and a zero byte.

`version` is 1. A Mac leaves a record with a newer version alone and refuses
changes until it is updated. A recipient row counts only under the device its
signed payload names. A record or sealing key counts only when a current Mac member signed it.
Linux hosts and phones relay and store only ciphertext; a record they write
is ignored, and a Mac that holds the key writes its own back. After launch,
after every peer sync batch and after a local change, each Mac reconciles:

1. It publishes its sealing key if the table lacks it.
2. A verified record with a newer revision replaces this Mac's copy, once a
   copy sealed to this Mac's current sealing key is there; until then Settings
   says the key arrives when the other Mac is online.
3. A newer local copy (changed offline, or first shared after an update) is
   written as the record, sealed to every verified Mac.
4. A Mac holding the current key seals copies for Macs that have none, or whose
   sealing key changed (a reinstalled Mac), and signs the record again.

Changes and reconciles on one Mac run one at a time. While a newer key from
another Mac has not reached this one, saving only the identity is refused (it
would put this Mac's older key back everywhere); generating, pasting or
removing a key is the user's choice and goes ahead. Identities adopted from a
record are validated again. Concurrent edits on two Macs converge through the
library's own conflict rule; the losing Mac adopts the winner on its next
reconcile.

## Linux hosts

A Mac's Pi Durable configuration (`POST /v1/default-agent/configuration`)
carries `github: {sshKey: {privateKey, publicKey} | null, identity: {name,
email} | null, revision}` when the Mac has the setting (`withGitHub()`; a Mac
that never set it, or cannot read it, sends none). The host validates it and
applies it unless it already holds a higher revision (`.revision`), one
configuration at a time, then passes the rest to Pi Durable; a configuration
without `github` changes nothing. A Mac sends again when Pi Durable's revision
or the setting's revision changes. The host keeps the key as a private file, like `~/.ssh`; it is not in
Pi Durable's encrypted vault because ssh must read it after a restart. Local
Pi Durable, its helpers and the inference host never receive `github`: it is
not in the credential snapshot.

## Bots

`POST /v1/bots-host/git` returns the machine's setting in the same shape
(explicit nulls when nothing is set): a Mac answers from Keychain, a Linux
host from its files. The runtime asks at most once a minute, keeps the last
answer if the host is briefly unreachable (with no answer yet it writes
nothing), and writes the files into a bot's container as the bot user every
time its agent starts and, when the setting changed, before the bot's next
command. The files live on a tmpfs, so they never reach the container's disk,
the storage volume or an update's snapshot. A container created before this
setting existed has no tmpfs: an update clears the directory before taking
its snapshot (when the container is running) and the recreated container gets
the tmpfs. This is the one credential that enters a bot container, because git
runs there.

## Protection boundary

As for provider credentials (`DEFAULT_AGENT_CREDENTIALS.md`): Keychain on Macs,
private files on Linux hosts and in bot containers. Anything that can run
commands as the user, or as the bot, can read the key, as it can read
`~/.ssh`. A deploy key limits it to one repository.
