import { dirname, isAbsolute } from 'node:path';

// Native user-message consumption advances the binding. Submission alone never
// changes it: queued steering must leave the running input's context intact.
export class SessionCLIContext {
  #pending = [];
  #active;
  #connection;

  reconnect(connection) {
    if (!connection || !isAbsolute(connection.executablePath ?? "")
      || (connection.socketPath && !isAbsolute(connection.socketPath))) throw new Error("Invalid CLI connection.");
    this.#connection = connection;
  }

  enqueue(context) {
    if (context && (!isAbsolute(context.executablePath ?? '') || !context.captureID
      || (context.socketPath && !isAbsolute(context.socketPath)))) throw new Error('Invalid session CLI binding.');
    if (context) this.reconnect(context);
    const entry = { context };
    this.#pending.push(entry);
    return () => { this.#pending = this.#pending.filter(item => item !== entry); };
  }

  consumed() { this.#active = this.#pending.shift()?.context; }
  finish() { this.#pending = []; }

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
