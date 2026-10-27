# Development builds

`scripts/build_and_run.sh` is the only development launch entry point. Each
worktree gets a stable instance name, derived from its absolute path. Each mode
has its own bundle ID, app name, build cache, and preferences. Client replicas
have independent device credentials. Client and snapshot instances also have
independent data and process leases.
An explicit live host uses production's data and exclusive execution lease.

```sh
scripts/build_and_run.sh
scripts/build_and_run.sh --mode snapshot
scripts/build_and_run.sh --mode client
scripts/build_and_run.sh --mode live
scripts/build_and_run.sh --mode snapshot --instance chat-ui
scripts/build_and_run.sh --mode snapshot --instance migration-check
scripts/build_and_run.sh --plan
```

`run` is implicit. `debug` opens LLDB; `logs` opens the app and streams its logs.
`verify` launches and checks the exact executable, leaving it open for inspection.
The `--debug`, `--logs`, and `--verify` aliases are also accepted. Every normal
launch waits for the expected app to stay running; this verifies process startup,
not library connectivity or provider readiness.
The launcher requests a normal quit from only the exact app being rebuilt, before
replacing its executable. Active work or unsaved writing may refuse the quit;
finish that work before rebuilding. It never force-kills another Dev app or the
production app. Concurrent builds of the same profile are rejected; other
client/snapshot profiles can build and run independently. Only one host may own
the production library, regardless of its instance name.

## Choosing a mode

Agents understand ordinary wording: "build this as a client" means `--mode client`;
"build this from a snapshot" or "use a snapshot" means `--mode snapshot`.
"Build the live database" or "host the production database directly" means `--mode live`.
"Live client" or "use live data" still means client; the named `live` mode means the actual host.

Normal development builds use **snapshot** mode: the actual desktop app,
including its workspace, sidebars, settings, and execution engine, backed by an
isolated copy of the library. They do not depend on production being reachable.
Use **client** only when explicitly testing a connected library client. Use
**live** only when explicitly asked to host the production database.

With no mode supplied, `auto` selects snapshot. It never changes an explicit
client request into a snapshot after a connection failure. `WOVENMATTER_DEV_MODE`
and `WOVENMATTER_DEV_INSTANCE` are equivalent environment defaults. The old
`WOVENMATTER_DEV_VARIANT` remains an instance-name alias.

## Client mode

A client instance connects to the production library host using the regular
desktop workspace surface. It synchronizes
shared notes, folders, calendar, library artifacts, and conversation history,
and runs its own branch's native execution engine for its assigned sessions.
Foreign conversations remain owned by their original execution workspace; their
controls route to that owner. New local sessions use this instance's execution
storage and working directories. A shared folder without a local execution root
cannot silently become a local project: create a folder in the Dev workspace or
use All Workspaces for a new scratch directory.

On the same Mac, initial connection uses production's private, same-user Unix
socket. The production host must include the development-connect endpoint from
this change, have background execution enabled (or be a running live Dev host), and have its central library
available through the existing Tailscale connection. It provisions an independent,
revocable Dev device identity. Credentials are saved directly to this instance's
Keychain namespace; the launcher never reads or copies production credentials.

When that local endpoint is unavailable, the app opens the existing Device
Connections setup with the failure reason. Pairing to another Mac uses the normal
approved pairing flow. An agent must not operate account authentication or
device-authorization UI to recover access. The instance never falls back to
opening production SQLite or starting a replacement central library.

Shared edits and accepted commands are real changes. A new Dev instance does
not adopt existing production sessions or schedules. Closing an instance does
not move its work to production. Finish its active work before rebuilding.
Interface and execution code come from the branch; central-library operations
still run on the selected library host. Test changes to those operations with a
snapshot host.

## Snapshot mode

Snapshot and live profiles launch a separate headless background server using
the profile's own executable, socket, and execution lease. The window process is
a frontend. Closing it leaves that profile's work running; Settings → Background
Server can stop or restart it. Development servers never install login jobs.

The first snapshot launch takes an online SQLite backup from
`~/Library/Application Support/Woven Matter`, including committed WAL data. Use
`--source DIRECTORY` for another local library/export directory. The source is
opened read-only. Required library files, message attachments, and managed data
are copied into the new profile; SQLite assets use online backup too. Project
repositories and external working directories are not cloned or reused. Source-local
folders retain their identities and content relationships, with new blank project
directories and a new owner inside the snapshot's isolated execution home. Production
reference-directory bindings are not made executable in the copy. Other workspace
ownership is retained without copying its connection grants.

The copy preserves content and history while removing connection grants, host
identity, native session bindings, and pending execution. Captured chat workspace
ownership and roots remain as history metadata; an explicit retained-history state
makes copied chats read-only independently of their ownership. Copied local agent records
remain available to history but are retired from the active catalog; startup creates
one local agent for each harness under the snapshot's new device identity. Existing task definitions
remain visible but have a detached owner; create a new schedule in the snapshot
to test execution. Active goals and session timers are paused. Old chats are history; create a new
session to test the branch's runtime. The snapshot is its own library host with
a fresh identity and no production connections or copied grants. Its separate
Device Connections endpoint can be paired explicitly to test host/API changes;
it never synchronizes back to production.

Snapshots are disposable development environments. They never merge changes back
into the source library, and all their data may be discarded when the instance is
removed. Subsequent launches reuse the same instance; use a new `--instance` for a
fresh snapshot. Existing snapshots are not repaired or migrated by the launcher.
The launcher refuses to overwrite an existing snapshot. It publishes a newly
created snapshot only after backup, isolation, asset-copy, and integrity checks
succeed. Symlinked assets and overlapping source/destination paths are rejected.

## Live host mode

`--mode live` runs the branch as the main host of the actual production library
in `~/Library/Application Support/Woven Matter`. It does not make a copy or act
as a client. It retains production's identity, history, execution bindings,
schedules, and working directories; its writes and migrations affect production.
It requires an existing production database and is never selected automatically.

Before launching, stop the existing production host, including its background
execution service. Startup acquires the same `workspace-owner.lock` used by the
production app and backend before opening the database. If another host owns it,
the live build refuses to open it. Different live instance names do not bypass
that lock. The launcher only requests a normal quit of the exact Dev executable
being rebuilt, so it does not terminate production for you.

The live host serves regular library clients and the same-user development
connection endpoint while its app is running. It keeps execution in its own
process, so quit it gracefully before returning ownership to production.

## Validation

Launcher fixtures use fake build/signing tools and disposable SQLite databases.
They cover profile separation, explicit mode overrides, automatic selection,
committed WAL data, source preservation, snapshot restart protection, and failed
copy cleanup. Swift fixtures cover client projection, execution ownership,
credentials, and synchronization without invoking providers.

The acceptance workflow is production plus two client instances, distinct assigned
execution, a single-owner schedule, shared edits, reconnect, and an independent
rebuild; then a disconnected snapshot with preserved content. Live-host fixtures
verify production path selection and cross-process lease exclusion without
opening production data. Real provider and
production pairing checks must be reported separately from fixture results.
