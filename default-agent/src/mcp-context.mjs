// A queued input cannot change the authority of a tool which is already running.
// Only native user-message consumption advances this binding. Child contexts
// keep the exact input which spawned them, independently of later steering.
export function validateMCPConnection(connection) {
  if (!connection || typeof connection.endpointURL !== 'string'
      || typeof connection.bearerToken !== 'string' || !connection.bearerToken
      || /[\r\n]/.test(connection.bearerToken)) throw new Error('Invalid Woven MCP connection.');
  const endpoint = new URL(connection.endpointURL);
  if (endpoint.username || endpoint.password || endpoint.hash
      || endpoint.protocol !== 'https:' && !(endpoint.protocol === 'http:'
        && ['127.0.0.1', '[::1]', 'localhost'].includes(endpoint.hostname))) {
    throw new Error('Woven MCP requires HTTPS or a loopback HTTP endpoint.');
  }
  if (connection.captureID !== undefined && connection.captureID !== null && typeof connection.captureID !== 'string') {
    throw new Error('Invalid Woven MCP input binding.');
  }
  if (connection.sessionID !== undefined && connection.sessionID !== null && typeof connection.sessionID !== 'string') {
    throw new Error('Invalid Woven MCP session binding.');
  }
  return Object.freeze({ endpointURL: endpoint.href, bearerToken: connection.bearerToken,
    ...(connection.sessionID ? { sessionID: connection.sessionID } : {}),
    ...(connection.captureID ? { captureID: connection.captureID } : {}) });
}

export class SessionMCPContext {
  #pending = [];
  #active;
  #connection;
  #inherited = false;
  #renewConnection;
  #origin;

  reconnect(connection) {
    if (this.#inherited) throw new Error('An inherited MCP binding cannot be changed.');
    this.#connection = validateMCPConnection(connection);
  }

  enqueue(context) {
    if (this.#inherited) throw new Error('An inherited MCP binding cannot be changed.');
    const entry = { context: context ? validateMCPConnection(context) : undefined };
    this.#pending.push(entry);
    return () => { this.#pending = this.#pending.filter(item => item !== entry); };
  }

  consumed() {
    if (this.#inherited) return;
    this.#active = this.#pending.shift()?.context;
    if (this.#active) this.#connection = this.#active;
  }

  finish() { this.#pending = []; }

  fork() {
    const child = new SessionMCPContext();
    child.#inherited = true;
    child.#active = this.#active;
    child.#connection = this.#connection;
    child.#origin = this.origin();
    if (child.#origin) child.#renewConnection = () => this.discoveryConnection();
    return child;
  }

  // Only noncredential input provenance may enter the native ChildContext.
  origin() {
    if (this.#inherited) return this.#origin;
    if (!this.#active?.captureID || !this.#active.sessionID) return undefined;
    return Object.freeze({ captureID: this.#active.captureID, sessionID: this.#active.sessionID });
  }

  static restore(origin, currentConnection) {
    const child = new SessionMCPContext(); child.#inherited = true;
    if (typeof origin?.captureID === 'string' && origin.captureID
        && typeof origin.sessionID === 'string' && origin.sessionID) {
      child.#origin = Object.freeze({ captureID: origin.captureID, sessionID: origin.sessionID });
      child.#renewConnection = currentConnection;
    }
    return child;
  }

  // Discovery can use the session connection before a first input is consumed.
  discoveryConnection() { return this.#connection; }

  connection() {
    if (this.#inherited && this.#renewConnection) {
      const current = this.#renewConnection();
      if (!current || current.sessionID !== this.#origin.sessionID) {
        throw new Error('The child\'s originating Woven session is unavailable. Reconnect that session before continuing.');
      }
      return Object.freeze({ ...validateMCPConnection(current), captureID: this.#origin.captureID });
    }
    if (this.#inherited && !this.#active) {
      throw new Error('This child has no original Woven MCP input binding. Start a new child from an authorized Woven input.');
    }
    if (!this.#active || !this.#connection) throw new Error('This input has no Woven MCP connection.');
    return Object.freeze({ endpointURL: this.#connection.endpointURL, bearerToken: this.#connection.bearerToken,
      ...(this.#active.captureID ? { captureID: this.#active.captureID } : {}) });
  }
}
