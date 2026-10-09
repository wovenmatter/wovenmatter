import { dirname, isAbsolute } from 'node:path';

// Native user-message consumption advances the binding. Submission alone never
// changes it: queued steering must leave the running input's context intact.
export class SessionCLIContext {
  #pending = [];
  #active;
  #connection;
  #inherited = false;

  reconnect(connection) {
    if (this.#inherited) throw new Error('An inherited CLI binding cannot be changed.');
    if (!connection || !isAbsolute(connection.executablePath ?? "")
      || (connection.socketPath && !isAbsolute(connection.socketPath))) throw new Error("Invalid CLI connection.");
    this.#connection = Object.freeze({ ...connection });
  }

  enqueue(context) {
    if (this.#inherited) throw new Error('An inherited CLI binding cannot be changed.');
    if (context && (!isAbsolute(context.executablePath ?? '') || !context.captureID
      || (context.socketPath && !isAbsolute(context.socketPath)))) throw new Error('Invalid session CLI binding.');
    const entry = { context: context ? Object.freeze({ ...context }) : undefined };
    this.#pending.push(entry);
    return () => { this.#pending = this.#pending.filter(item => item !== entry); };
  }

  consumed() {
    if (this.#inherited) return;
    this.#active = this.#pending.shift()?.context;
    if (this.#active) this.#connection = this.#active;
  }
  finish() { this.#pending = []; }

  // A child receives exactly the authority of the input which spawned it.
  // Later steering, reconnects and child messages cannot retarget that capture.
  // This binding stays in memory; it must not enter native/archive metadata.
  fork() {
    const child = new SessionCLIContext();
    child.#inherited = true;
    child.#active = this.#active ? Object.freeze({ ...this.#active }) : undefined;
    child.#connection = this.#connection ? Object.freeze({ ...this.#connection }) : undefined;
    return child;
  }

  environment(base) {
    const env = { ...base };
    delete env.WOVENMATTER_CONTEXT_ID;
    delete env.WOVENMATTER_NOTE_ID;
    delete env.WOVENMATTER_SOCKET;
    delete env.WOVENMATTER_CLI;
    if (!this.#active) return env;
    const { captureID } = this.#active;
    const { executablePath, socketPath } = this.#connection;
    env.WOVENMATTER_CLI = executablePath;
    env.WOVENMATTER_CONTEXT_ID = captureID;
    // The remote CLI locates its own sibling socket.
    if (socketPath) env.WOVENMATTER_SOCKET = socketPath;
    env.PATH = dirname(executablePath) + ':' + (env.PATH ?? '');
    return env;
  }
}
