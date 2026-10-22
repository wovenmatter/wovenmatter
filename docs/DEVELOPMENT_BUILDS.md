# Development builds

`scripts/build_and_run.sh` is the only development launch entry point. Each
worktree gets a stable instance name, derived from its absolute path. Each mode
has its own bundle ID, app name, build cache, and preferences. Client replicas
have independent device credentials. Client and snapshot instances also have
independent data and process leases.
An explicit live host uses production's data and exclusive execution lease.

```sh
scripts/build_and_run.sh --mode client
scripts/build_and_run.sh --mode snapshot
scripts/build_and_run.sh --mode live
scripts/build_and_run.sh --mode client --instance chat-ui
scripts/build_and_run.sh --mode snapshot --instance migration-check
scripts/build_and_run.sh --plan
```

`run` is implicit; `debug`, `logs`, and `verify` retain their existing meanings.
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

Honor the user's explicit choice. Otherwise, agents should choose **client** for
desktop UI, harness adapters, tools, and scheduling assigned to the Dev execution
workspace. Choose **snapshot** for central-library migrations, persistence,
server/API changes, or testing that should not change shared content. State the
choice and reason briefly; do not stop to ask the user to choose. **Live** is only
for an explicit request to run the branch as the production database's host.

When no choice is passed, `auto` inspects committed and uncommitted changes against
`origin/main`, including untracked files. Known library-host and protocol paths
choose snapshot; other changes choose client. Auto never selects live.
This is a conservative fallback,
not semantic analysis. Agents should pass their chosen mode explicitly when a
change's intent is clearer than its file paths. `WOVENMATTER_DEV_MODE` and
`WOVENMATTER_DEV_INSTANCE` are equivalent environment defaults. The old
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

On the central Mac, enable **Devices → Allow local Dev clients** once. It is off
by default. After that, `scripts/build_and_run.sh --mode client` opens a Dev
client directly into the workspace. The client uses the private same-user Unix
socket to enroll automatically, waits for the host to become ready, and opens
the installed central app in the background if it is not running. Normal
foreground hosts and background execution hosts both support this flow; users
do not need to turn on background execution just to test a Dev client.

The central app must include this support and have its regular library service
available. Each instance receives an independent credential in its own Keychain
namespace. Rebuilds reuse the instance identity and revalidate host permission.
No pairing link, pending approval, or credential copying is involved. Other Macs
and ordinary clients retain the existing pairing and approval flow. Turning the
setting off blocks enrollment and revokes local Dev client grants.

This is an explicit same-macOS-user development trust boundary, not a remote
pairing shortcut. Clients never open production SQLite, replace the running
host, or fall back to snapshots. If the host is incompatible, development is
disabled, or startup fails, the launch must report that failure rather than
claiming a usable preview from a process check alone.

Shared edits and accepted commands are real changes. A new Dev instance does
not adopt existing production sessions or schedules. Closing an instance does
not move its work to production. Finish its active work before rebuilding.
Interface and execution code come from the branch; central-library operations
still run on the selected library host. Test changes to those operations with a
snapshot host.

## Snapshot mode

The first snapshot launch takes an online SQLite backup from
`~/Library/Application Support/Woven Matter`, including committed WAL data. Use
`--source DIRECTORY` for another local library/export directory. The source is
opened read-only. Required library files, message attachments, and managed data
are copied into the new profile; SQLite assets use online backup too. Project
repositories and external working directories are not cloned or reused.

The copy preserves content and history while removing connection grants, host
identity, native session bindings, and pending execution. Copied local agent records
remain available to history but are retired from the active catalog; startup creates
one local agent for each harness under the snapshot's new device identity. Existing task definitions
remain visible but have a detached owner; create a new schedule in the snapshot
to test execution. Active goals and session timers are paused. Old chats are history; create a new
session to test the branch's runtime. The snapshot is its own library host with
a fresh identity and no production connections or copied grants. Its separate
Device Connections endpoint can be paired explicitly to test host/API changes;
it never synchronizes back to production.

Subsequent launches reopen the same snapshot and preserve its edits. To test a
new migration against fresh production data, choose a new `--instance` name.
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
