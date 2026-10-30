# Embedded execution test package

This package is retained for isolated runtime tests and is **not linked or bundled
in the iPhone/iPad app**. Quick Chat has no command or Python execution.

`EmbeddedExecution` embeds **real CPython 3.14.2 via Pyodide 314.0.7 / WebAssembly**
inside an independently terminable WebKit worker. It executes without a Mac,
inference service, network connection, installation step, or runtime download.
Pi Durable still owns the agent loop; this is a tool execution environment.

## Commands and Python

The API accepts an argv array, stdin, an optional workspace-relative current
directory, and a stable command UUID. It deliberately does not claim a POSIX shell:
there is no `sh`, process spawning, command substitution, or shell pipe grammar.

`python` / `python3` run `-c SOURCE`, `-m MODULE`, or a script file, with arguments.
The real bundled standard library includes JSON, CSV, SQLite, regular expressions,
statistics, decimal arithmetic, archives, file operations, asyncio, and unittest.
Top-level `await` is supported for scripts and `-c`; for example:

```python
import csv, io, json, sqlite3
rows = list(csv.DictReader(io.StringIO("name,count\nA,2\nB,3\n")))
with sqlite3.connect("report.sqlite") as db:
    db.execute("create table if not exists counts(name text, count integer)")
    db.executemany("insert into counts values (?, ?)", [(r["name"], int(r["count"])) for r in rows])
print(await woven_mcp("woven_notes_list", {}))
```

Other bundled commands are implemented using those standard-library operations:
`pwd`, `ls [-a]`, `cat`, `mkdir [-p]`, `cp [-r]`, `mv`, `rm [-rf]`, `find`,
`grep [-in]`, and `sqlite3 DATABASE SQL`. `help` returns the exact accepted syntax.
Python can await `woven_mcp(name, arguments)` to invoke a focused Woven tool.
The tool name and structured arguments use the same shared MCP catalog as other
harnesses; there is no `wovenmatter` command or argv tool bridge. These filesystem
builtins are not imported Unix binaries or aliases to a remote Mac.

There is no arbitrary native executable, native Python extension installation,
package download, raw socket, browser cookie, Keychain, or host filesystem access.
Pure Python modules placed in the workspace can be imported. The underlying WASM
runtime is portable between physical iOS and Apple Silicon Simulator; it has no
CPU-specific native binary dependency.

## Isolation, persistence, and cancellation

- A job snapshots only regular workspace files. No host filesystem mount exists.
  The worker has a separate virtual `/workspace` plus bundled Python system files.
- CSP blocks network and frame loads. Pyodide asset requests resolve from an exact,
  bundled byte map; there is no CDN fallback. Focused native MCP tool calls are the sole bridge.
- Note operations and Executor programs use typed inline arguments. Python can
  read its own virtual files and supply that content explicitly; no tool accepts
  a host path to read.
- A native library read can explicitly return newly created artifact paths through
  the host's `importFiles` callback. Only those named files are loaded into Python
  and added to the original snapshot baseline; unrelated native edits still cause
  a conflict, and existing virtual files cannot be overwritten by an import.
- Native code validates every returned path, rejects symlinks and reserved metadata
  names, and enforces workspace byte/entry budgets. It checks the workspace again
  before applying a result, rejecting concurrent changes without partial writes.
- A staging directory receives all changes and the durable result receipt, then
  `renameatx_np(RENAME_SWAP)` atomically publishes the complete result. Only one
  command per workspace runs at a time. Native app writes must continue using
  their normal serialized workspace ownership; a separate process holding an open
  file descriptor cannot be governed by an in-process lock.
- A durable acceptance marker precedes execution. If a process dies or is cancelled
  without a completed receipt, reusing that ID refuses to rerun the script: native
  effects may already have committed. Inspect the saved output and intentionally
  create a new job after reviewing those effects.
- Replaying a completed command UUID and arguments returns its receipt without
  repeating mutations. Each nested MCP call derives a stable UUID from the job and
  its call ordinal, so tool receipts can deduplicate committed work.
- Stop/cancellation terminates the worker independently of Python's interpreter.
  Uncommitted virtual file changes are discarded. Already committed native tool
  effects are governed by operation receipts; they are not rolled back.
- Execution has no blanket wall-clock deadline. A 90-second startup watchdog
  detects a runtime that fails to initialize. iOS can still interrupt WebKit or
  suspend the app; failures never imply arbitrary instruction-level resumability.
- Full stdout/stderr stream to `.woven-execution/<job UUID>/stdout.txt` and
  `stderr.txt`. Responses contain a bounded preview and explicitly indicate when
  full output requires those files. Resource budgets are configured in Swift
  (`EmbeddedExecutionLimits`); exceeding a budget fails the job explicitly.
- This is a single-worker WASM environment. Python OS processes and native thread
  behavior are unavailable. Memory pressure can terminate the WebKit process;
  native code reports that interruption and keeps prior workspace files intact.

## Pi Durable code mode scheduling and watchdog

Code mode forwards awaited native calls as Pi Durable SDK-owned tool tasks. There
is no custom numeric tool-call concurrency ceiling in the worker, native bridge,
or SDK adapter, and no total tool-call budget. Independent calls can run together
using `Promise.all`; the SDK retains validation, hooks, task ownership, cancellation,
and recovery. Model tool rounds retain the SDK's native parallel/sequential policy.
Existing serialization for whole-conversation code checkpoints and per-workspace
file publication protects shared state; it is not a global tool concurrency cap.
Old saved `concurrentTools` values are ignored and are no longer written.

The JavaScript code worker has a **120-second responsiveness watchdog**. Its timer
resets on worker heartbeats; waiting for native tools, approvals, or inference is
not a two-minute task deadline. Long synchronous computations can keep running by
periodically calling `await yield_control()`. Explicit Stop still cancels work.
Saved watchdog values below 120 seconds are upgraded, and longer saved values are
retained. The separate Python startup watchdog above is unchanged.

**Decision to revisit:** 120 seconds is the current chosen responsiveness budget,
not a settled performance requirement. Reassess it using physical iPhone/iPad
measurements of long computations, false interruptions, cancellation latency,
battery and thermal behavior. iOS suspension and WebKit process termination remain
separate lifecycle constraints; this watchdog does not grant background runtime.

## Reproducibility and licensing

```sh
npm ci --ignore-scripts --prefix ios/EmbeddedRuntime
node scripts/build-ios-embedded-runtime.mjs
node scripts/build-ios-embedded-runtime.mjs --check
```

The npm lockfile pins upstream package integrity; `Resources/provenance.json`
records source/resource SHA-256 values, the upstream source tag and npm integrity.
Checked-in resources make native builds independent of a runtime CDN. The bundled
lock metadata deliberately contains an empty third-party package catalog: no
optional downloads are advertised or permitted. MPL-2.0,
PSF, libffi, hiwire, Emscripten, XZ and Zstandard notices are included in the app's
resource bundle; `licenses.json` pins the source URLs and notice hashes. SQLite is
public domain. No downloaded package files are modified; the generated JavaScript
bundle includes the unchanged upstream modules and our bridge.

## Validation

`EmbeddedExecutionTests` covers native path/resource validation, conflict rejection,
atomic result/receipt publication, and deterministic native MCP operation identities.

The standalone simulator harness exercises the actual WebKit worker, rather than
substituting desktop Python or a mocked interpreter:

```sh
scripts/test-ios-embedded-runtime.sh <booted-simulator-uuid>
```

It installs a separate test bundle (`com.wovenmatter.embedded-smoke`), with synthetic
files and an in-memory MCP stub. It does not touch the Woven Matter app or providers.
The report covers CPython/CSV/JSON/SQLite, persistence between commands, native
bridging, receipt replay, stopping an infinite Python loop, refusing interrupted
script replay, concurrent edit preservation, file-backed output previews, actual
Python unittest execution, structured tool inputs, library-file import into Python,
continued conflict protection during imports, and symlink rejection.
