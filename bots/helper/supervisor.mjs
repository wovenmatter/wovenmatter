// Woven bot supervisor: the main process of every bot container (under tini). It keeps the bot's
// restart list running (services the bot registered with `keep_running`), restarting each on exit
// and on every container start, and owns the bot's browser process. It answers control requests
// on a Unix socket, one JSON line each way. State lives in the bot's storage (/workspace/.woven),
// so it survives stops, updates and rebuilds. It holds no credentials.
import { spawn } from "node:child_process";
import { createWriteStream } from "node:fs";
import { mkdir, open, readFile, rename, rm, stat } from "node:fs/promises";
import { createServer } from "node:net";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const STATE = process.env.WOVEN_STATE_DIR ?? "/workspace/.woven";
const SOCKET = process.env.WOVEN_CONTROL_SOCKET ?? "/tmp/woven-bot/control.sock";
const SERVICES = join(STATE, "services.json");
const LOGS = join(STATE, "logs");
const BROWSER_STATE = join(STATE, "browser");
const HERE = dirname(fileURLToPath(import.meta.url));
const NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const MAX_LOG = 5 * 1024 * 1024;
const MAX_SERVICES = 50;

/** name → { spec, child, restarts, startedAt, lastExit, timer, stopping } */
const running = new Map();
let shuttingDown = false;

function log(message) {
  process.stderr.write(`woven supervisor: ${message}\n`);
}

/** Replace `path` atomically, synced first: the container can lose power (a VM reboot) any time. */
async function writeJSON(path, value) {
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.tmp`;
  const file = await open(temporary, "w");
  try {
    await file.writeFile(`${JSON.stringify(value, null, 2)}\n`);
    await file.sync();
  } finally {
    await file.close();
  }
  await rename(temporary, path);
}

async function readServices() {
  try {
    const list = JSON.parse(await readFile(SERVICES, "utf8"));
    return Array.isArray(list) ? list.filter((item) => NAME.test(item?.name ?? "") && typeof item.command === "string") : [];
  } catch {
    return [];
  }
}

async function logStream(name) {
  await mkdir(LOGS, { recursive: true });
  const path = join(LOGS, `${name}.log`);
  const info = await stat(path).catch(() => undefined);
  if (info && info.size > MAX_LOG) await rename(path, `${path}.1`).catch(() => {});
  return createWriteStream(path, { flags: "a" });
}

function backoff(restarts) {
  return Math.min(60_000, 1000 * 2 ** Math.min(restarts, 6));
}

async function startService(spec) {
  if (shuttingDown) return;
  const state = running.get(spec.name) ?? { spec, restarts: 0 };
  state.spec = spec;
  state.stopping = false;
  running.set(spec.name, state);
  const out = await logStream(spec.name);
  out.write(`\n--- ${new Date().toISOString()} starting: ${spec.command}\n`);
  const child = spawn("bash", ["-lc", spec.command], {
    cwd: spec.cwd || "/workspace",
    detached: true,
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, WOVEN_SERVICE: spec.name },
  });
  state.child = child;
  state.startedAt = Date.now();
  child.stdout.pipe(out, { end: false });
  child.stderr.pipe(out, { end: false });
  child.on("error", (error) => out.write(`--- failed to start: ${error.message}\n`));
  child.on("exit", (code, signal) => {
    out.write(`--- ${new Date().toISOString()} exited (${signal ?? code})\n`);
    out.end();
    if (state.child !== child) return;
    state.child = undefined;
    state.lastExit = { code, signal, at: Date.now() };
    if (state.stopping || shuttingDown) return;
    // A service that stayed up a minute starts its backoff over.
    if (Date.now() - state.startedAt > 60_000) state.restarts = 0;
    const delay = backoff(state.restarts++);
    state.timer = setTimeout(() => {
      state.timer = undefined;
      if (running.get(spec.name) === state && !state.stopping) void startService(state.spec);
    }, delay);
  });
}

function stopService(name, wait = 5000) {
  const state = running.get(name);
  if (!state) return Promise.resolve();
  state.stopping = true;
  if (state.timer) clearTimeout(state.timer);
  const child = state.child;
  if (!child) return Promise.resolve();
  return new Promise((resolve) => {
    const done = () => resolve();
    child.once("exit", done);
    try {
      process.kill(-child.pid, "SIGTERM");
    } catch {
      return done();
    }
    setTimeout(() => {
      try {
        process.kill(-child.pid, "SIGKILL");
      } catch {
        // Already gone.
      }
    }, wait).unref();
  });
}

/** Bring running services in line with services.json. */
async function reconcile() {
  const wanted = await readServices();
  const names = new Set(wanted.map((spec) => spec.name));
  for (const name of [...running.keys()]) {
    if (!names.has(name)) {
      await stopService(name);
      running.delete(name);
    }
  }
  for (const spec of wanted) {
    const current = running.get(spec.name);
    if (current && current.spec.command === spec.command && current.spec.cwd === spec.cwd && (current.child || current.timer)) continue;
    if (current) await stopService(spec.name);
    if (current) current.restarts = 0;
    await startService(spec);
  }
}

function describe(spec) {
  const state = running.get(spec.name);
  return {
    name: spec.name,
    command: spec.command,
    cwd: spec.cwd || "/workspace",
    running: Boolean(state?.child),
    ...(state?.child ? { pid: state.child.pid, since: new Date(state.startedAt).toISOString() } : {}),
    restarts: state?.restarts ?? 0,
    ...(state?.lastExit ? { lastExit: { code: state.lastExit.code, signal: state.lastExit.signal, at: new Date(state.lastExit.at).toISOString() } } : {}),
  };
}

async function tail(name, lines) {
  const text = await readFile(join(LOGS, `${name}.log`), "utf8").catch(() => "");
  const all = text.split("\n");
  return all.slice(-Math.min(Math.max(lines, 1), 2000) - 1).join("\n").slice(-200_000);
}

// --- browser ----------------------------------------------------------------------------------

let browser; // { child, pending: Map, next, ready: Promise }

function startBrowser() {
  if (browser) return browser;
  const child = spawn(process.execPath, [join(HERE, "browser.mjs")], {
    stdio: ["ignore", "inherit", "inherit", "ipc"],
    env: { ...process.env, WOVEN_BROWSER_STATE: BROWSER_STATE },
  });
  const entry = { child, pending: new Map(), next: 1 };
  entry.ready = new Promise((resolve, reject) => {
    child.once("message", (message) => (message?.ready ? resolve() : reject(new Error(message?.error ?? "browser failed to start"))));
    child.once("exit", () => reject(new Error("the browser exited")));
  });
  entry.ready.catch(() => {});
  child.on("message", (message) => {
    const waiter = entry.pending.get(message?.id);
    if (!waiter) return;
    entry.pending.delete(message.id);
    if (message.error) waiter.reject(new Error(message.error));
    else waiter.resolve(message.value);
  });
  child.on("exit", (code) => {
    for (const waiter of entry.pending.values()) waiter.reject(new Error(`the browser exited (${code})`));
    if (browser === entry) browser = undefined;
  });
  browser = entry;
  return entry;
}

async function browserCall(method, args, timeoutMs = 90_000) {
  const entry = startBrowser();
  await entry.ready;
  const id = entry.next++;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      entry.pending.delete(id);
      reject(new Error(`browser ${method} timed out`));
    }, timeoutMs);
    entry.pending.set(id, {
      resolve: (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      reject: (error) => {
        clearTimeout(timer);
        reject(error);
      },
    });
    entry.child.send({ id, method, args });
  });
}

async function stopBrowser() {
  const entry = browser;
  if (!entry) return;
  await browserCall("shutdown", {}, 15_000).catch(() => {});
  entry.child.kill("SIGTERM");
}

/** Reopen saved tabs after a container start, in the background. */
async function restoreBrowser() {
  try {
    const saved = JSON.parse(await readFile(join(BROWSER_STATE, "tabs.json"), "utf8"));
    if (Array.isArray(saved?.tabs) && saved.tabs.length) await browserCall("ping", {});
  } catch {
    // No saved tabs: the browser starts on first use.
  }
}

// --- control socket ---------------------------------------------------------------------------

async function handle(method, args) {
  switch (method) {
    case "ping":
      return { ok: true, pid: process.pid, services: running.size, browser: Boolean(browser) };
    case "services.list":
      return (await readServices()).map(describe);
    case "services.add": {
      const name = String(args.name ?? "");
      const command = String(args.command ?? "");
      const cwd = String(args.cwd ?? "/workspace");
      if (!NAME.test(name)) throw new Error("name: letters, digits, '.', '_' and '-' (max 64)");
      if (!command.trim() || command.length > 4000) throw new Error("command is required (max 4000 characters)");
      if (!cwd.startsWith("/")) throw new Error("cwd must be an absolute path");
      const list = (await readServices()).filter((spec) => spec.name !== name);
      if (list.length >= MAX_SERVICES) throw new Error(`at most ${MAX_SERVICES} services`);
      list.push({ name, command, cwd });
      await writeJSON(SERVICES, list);
      await reconcile();
      return describe({ name, command, cwd });
    }
    case "services.remove": {
      const name = String(args.name ?? "");
      const list = await readServices();
      if (!list.some((spec) => spec.name === name)) throw new Error(`no service "${name}"`);
      await writeJSON(SERVICES, list.filter((spec) => spec.name !== name));
      await reconcile();
      return { removed: name };
    }
    case "services.restart": {
      const name = String(args.name ?? "");
      const spec = (await readServices()).find((item) => item.name === name);
      if (!spec) throw new Error(`no service "${name}"`);
      await stopService(name);
      const state = running.get(name);
      if (state) state.restarts = 0;
      await startService(spec);
      return describe(spec);
    }
    case "services.logs": {
      const name = String(args.name ?? "");
      if (!NAME.test(name)) throw new Error("invalid service name");
      return { name, text: await tail(name, Number(args.lines) || 200) };
    }
    case "browser.stop":
      await stopBrowser();
      return { stopped: true };
    default:
      if (method.startsWith("browser.")) return browserCall(method.slice("browser.".length), args);
      throw new Error(`unknown control ${method}`);
  }
}

// sun_path holds 108 bytes on Linux and 104 on macOS, NUL included. Node 26 on macOS
// accepts a longer path without binding it, so check the length here.
const SUN_PATH_MAX = process.platform === "linux" ? 107 : 103;

async function main() {
  if (Buffer.byteLength(SOCKET) > SUN_PATH_MAX) {
    throw new Error(`control socket path is ${Buffer.byteLength(SOCKET)} bytes, over the ${SUN_PATH_MAX}-byte limit: ${SOCKET}`);
  }
  await mkdir(dirname(SOCKET), { recursive: true });
  await rm(SOCKET, { force: true });
  const server = createServer((socket) => {
    let buffer = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => {
      buffer += chunk;
      const newline = buffer.indexOf("\n");
      if (newline < 0) return;
      const line = buffer.slice(0, newline);
      buffer = "";
      let request;
      try {
        request = JSON.parse(line);
      } catch {
        socket.end(`${JSON.stringify({ error: "invalid request" })}\n`);
        return;
      }
      handle(String(request.method), request.args ?? {}).then(
        (value) => socket.end(`${JSON.stringify({ value: value ?? null })}\n`),
        (error) => socket.end(`${JSON.stringify({ error: error instanceof Error ? error.message : String(error) })}\n`),
      );
    });
    socket.on("error", () => {});
  });
  // A socket that cannot be bound must end the supervisor with a reason, never leave it
  // running without one (ctl and the agent would wait for it until they time out).
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(SOCKET, () => {
      server.off("error", reject);
      resolve();
    });
  });
  await reconcile().catch((error) => log(`restart list: ${error.message}`));
  void restoreBrowser();
  const shutdown = async () => {
    if (shuttingDown) return;
    shuttingDown = true;
    server.close();
    await Promise.allSettled([stopBrowser(), ...[...running.keys()].map((name) => stopService(name))]);
    process.exit(0);
  };
  process.on("SIGTERM", () => void shutdown());
  process.on("SIGINT", () => void shutdown());
}

void main().catch((error) => {
  log(error.stack ?? String(error));
  process.exit(1);
});
