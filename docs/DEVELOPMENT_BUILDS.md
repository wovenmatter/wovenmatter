# Development builds

`scripts/build_and_run.sh` is the only development launch entry point. Each
worktree gets a stable instance name, derived from its absolute path. Its live
and snapshot builds have different bundle IDs, app names, build caches, preferences,
client credentials, process leases, and application-support directories.

```sh
scripts/build_and_run.sh --mode live
scripts/build_and_run.sh --mode snapshot
scripts/build_and_run.sh --mode live --instance chat-ui
scripts/build_and_run.sh --mode snapshot --instance migration-check
scripts/build_and_run.sh --plan
```

`run` is implicit; `debug`, `logs`, and `verify` retain their existing meanings.
The launcher requests a normal quit from only the exact app being rebuilt, before
replacing its executable. Active work or unsaved writing may refuse the quit;
finish that work before rebuilding. It never force-kills another Dev app or the
production app. Concurrent builds of the same profile are rejected; other
profiles can build and run independently.

## Choosing a mode

Honor the user's explicit choice. Otherwise, agents should choose **live** for
desktop UI, harness adapters, tools, and scheduling assigned to the Dev execution
workspace. Choose **snapshot** for central-library migrations, persistence,
server/API changes, or testing that should not change shared content. State the
choice and reason briefly; do not stop to ask the user to choose.

When no choice is passed, `auto` inspects committed and uncommitted changes against
`origin/main`, including untracked files. Known library-host and protocol paths
choose snapshot; other changes choose live. This is a conservative fallback,
not semantic analysis. Agents should pass their chosen mode explicitly when a
change's intent is clearer than its file paths. `WOVENMATTER_DEV_MODE` and
`WOVENMATTER_DEV_INSTANCE` are equivalent environment defaults. The old
`WOVENMATTER_DEV_VARIANT` remains an instance-name alias.

## Live clients

A live instance uses the regular desktop workspace surface. It synchronizes
shared notes, folders, calendar, library artifacts, and conversation history,
and runs its own branch's native execution engine for its assigned sessions.
Foreign conversations remain owned by their original execution workspace; their
controls route to that owner. New local sessions use this instance's execution
storage and working directories. A shared folder without a local execution root
cannot silently become a local project: create a folder in the Dev workspace or
use All Workspaces for a new scratch directory.

On the same Mac, initial connection uses production's private, same-user Unix
socket. The production host must include the development-connect endpoint from
this change, have background execution enabled, and have its central library
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

## Snapshots

The first snapshot launch takes an online SQLite backup from
`~/Library/Application Support/Woven Matter`, including committed WAL data. Use
`--source DIRECTORY` for another local library/export directory. The source is
opened read-only. Required library files, message attachments, and managed data
are copied into the new profile; SQLite assets use online backup too. Project
repositories and external working directories are not cloned or reused.

The copy preserves content and history while removing connection grants, host
identity, native session bindings, and pending execution. Existing task definitions
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

## Validation

Launcher fixtures use fake build/signing tools and disposable SQLite databases.
They cover profile separation, explicit mode overrides, automatic selection,
committed WAL data, source preservation, snapshot restart protection, and failed
copy cleanup. Swift fixtures cover client projection, execution ownership,
credentials, and synchronization without invoking providers.

The acceptance workflow is production plus two live instances, distinct assigned
execution, a single-owner schedule, shared edits, reconnect, and an independent
rebuild; then a disconnected snapshot with preserved content. Real provider and
production pairing checks must be reported separately from fixture results.
