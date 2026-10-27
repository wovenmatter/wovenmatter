import { Client, StreamableHTTPClientTransport } from '@modelcontextprotocol/client';
import { randomUUID } from 'node:crypto';
import { Type } from 'typebox';
import { validateMCPConnection } from './mcp-context.mjs';
import { prepareHTMLTool } from './html-resources.mjs';

// App connection material is supplied by the native execution owner, never by
// model arguments, workspace configuration, shell environment or saved history.
export class WovenMCPClient {
  #clients = new Map();
  #generation = 0;

  async #client(connection) {
    const bound = validateMCPConnection(connection);
    const key = JSON.stringify([bound.endpointURL, bound.bearerToken]);
    if (!this.#clients.has(key)) {
      const generation = this.#generation;
      const pending = (async () => {
        const client = new Client({ name: 'woven-pi-durable', version: '1' }, { capabilities: {} });
        try {
          await client.connect(new StreamableHTTPClientTransport(new URL(bound.endpointURL), {
            requestInit: { headers: { authorization: `Bearer ${bound.bearerToken}` }, redirect: 'error' },
          }));
          if (generation !== this.#generation) throw new Error('The Woven MCP connection closed.');
          return client;
        } catch (error) { await client.close().catch(() => {}); this.#clients.delete(key); throw error; }
      })();
      this.#clients.set(key, pending);
    }
    return this.#clients.get(key);
  }

  async listTools(connection, signal) {
    const client = await this.#client(connection), tools = [], names = new Set(), cursors = new Set();
    let cursor;
    do {
      signal?.throwIfAborted();
      const page = await client.listTools(cursor ? { cursor } : {}, { signal, timeout: 30000 });
      for (const tool of page.tools ?? []) {
        if (!/^woven_[a-z0-9_]+$/.test(tool.name) || names.has(tool.name) || tool.inputSchema?.type !== 'object') {
          throw new Error('Woven MCP returned an invalid or duplicate tool definition.');
        }
        names.add(tool.name); tools.push(tool);
      }
      cursor = page.nextCursor;
      if (cursor && cursors.has(cursor)) throw new Error('Woven MCP returned a repeated tools cursor.');
      if (cursor) cursors.add(cursor);
      if (tools.length > 512) throw new Error('Woven MCP returned too many tools.');
    } while (cursor);
    return tools;
  }

  async callTool(connection, name, input, signal) {
    const bound = validateMCPConnection(connection);
    signal?.throwIfAborted();
    const requestID = input.requestID ?? randomUUID();
    const client = await this.#client(bound);
    signal?.throwIfAborted();
    // Explicit request identity is distinct from MCP's transport request id.
    // The backend returns it in structured results for deliberate retry.
    const prepared = await prepareHTMLTool(name, input);
    const params = { name, arguments: { ...prepared.arguments, requestID },
      _meta: { ...(bound.captureID ? { wovenContextID: bound.captureID } : {}),
        ...(prepared.missingImages ? { wovenHTMLMissingImages: prepared.missingImages } : {}) } };
    try {
      return await client.callTool(params, { signal, timeout: 24 * 60 * 60 * 1000, maxTotalTimeout: 24 * 60 * 60 * 1000 });
    } catch (error) {
      if (signal?.aborted && ['woven_browser_use', 'woven_computer_use', 'woven_html_preview'].includes(name)) {
        // Cancellation is scoped to the already accepted operation and uses
        // the exact input authority captured before the original network call.
        await client.callTool({ name: name === 'woven_html_preview' ? 'woven_html_cancel' : `${name}_cancel`, arguments: { id: requestID },
          ...(bound.captureID ? { _meta: { wovenContextID: bound.captureID } } : {}) },
        { signal: AbortSignal.timeout(3000), timeout: 3000 }).catch(() => {});
      }
      throw error;
    }
  }

  async close() {
    this.#generation++;
    const pending = [...this.#clients.values()]; this.#clients.clear();
    await Promise.allSettled(pending.map(async item => (await item).close()));
  }
}

export function wovenMCPTools(definitions, client, connection) {
  return definitions.map(definition => ({
    name: definition.name, label: definition.title ?? definition.name,
    description: definition.description ?? '', parameters: Type.Unsafe(definition.inputSchema),
    // Only server-declared reads can replay after interrupted native execution.
    replay: definition.annotations?.readOnlyHint === true && definition.annotations?.idempotentHint !== false ? 'safe' : 'unsafe',
    execute: async (_id, input, signal) => {
      const bound = connection();
      const result = await client.callTool(bound, definition.name, input, signal);
      return { content: result.content ?? [], isError: result.isError === true,
        ...(result.structuredContent === undefined ? {} : { structuredContent: result.structuredContent }),
        details: { ...(result.structuredContent === undefined ? {} : { structuredContent: result.structuredContent }) } };
    },
  }));
}
