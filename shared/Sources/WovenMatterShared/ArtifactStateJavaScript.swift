import Foundation

/// The saved-Artifact bridge only transports this Artifact's JSON state. It has
/// no file, SQL, network, agent, or general application-command entry point.
public enum ArtifactStateJavaScript {
    public static let bootstrap = #"""
    (() => {
      'use strict';
      const config = window.__wovenArtifactConfiguration;
      if (!config || window.wovenArtifact) return;
      const clone = value => JSON.parse(JSON.stringify(value));
      const own = (target, key, value) => Object.defineProperty(target, key, {value, enumerable: true, writable: true, configurable: true});
      // Object key order carries no meaning here, so it cannot count as a change.
      const canonical = value => JSON.stringify(value ?? null, (_, item) => item && typeof item === 'object' && !Array.isArray(item)
        ? Object.fromEntries(Object.keys(item).sort().map(key => [key, item[key]])) : item);
      let versions = clone(config.state.versions || {});
      let committed = clone(config.state.values || {});
      let shadow = clone(committed);
      let sequence = 0;
      let tail = Promise.resolve();
      let pausedError = null;
      let resolveReady;
      const ready = new Promise(resolve => { resolveReady = resolve; });
      const pending = new Map();
      const lastRequests = new Map();
      const unsaved = new Map();
      const listeners = new Set();
      const validKey = key => {
        if (typeof key !== 'string' || !key.length || key.length > 256) throw new Error('Use a state key of 1–256 characters.');
        return 'app:' + key;
      };
      const appValues = () => {
        const values = Object.create(null);
        for (const [key, value] of Object.entries(shadow)) if (key.startsWith('app:')) values[key.slice(4)] = clone(value);
        return values;
      };
      // Interfaces redraw from these events, so saving or echoing the same values stays silent.
      let notified = canonical(appValues());
      let deliveredData = canonical(window.wovenMatterData);
      const notify = () => {
        const values = appValues(), current = canonical(values);
        if (current === notified) return;
        notified = current;
        for (const listener of listeners) { try { listener(values); } catch (_) {} }
        window.dispatchEvent(new CustomEvent('wovenartifactchange', {detail: values}));
      };
      const errorEvent = message => window.dispatchEvent(new CustomEvent('wovenartifacterror', {detail: {message}}));
      const applyKey = (key, version, incoming) => {
        own(versions, key, version);
        if (Object.hasOwn(incoming.values || {}, key)) own(committed, key, clone(incoming.values[key]));
        else delete committed[key];
      };
      // Each key only moves forward, so a snapshot delayed behind a newer save cannot
      // rewind it. A snapshot that omits a key can only have evicted its tombstone: live
      // keys are never dropped, so omitting one means the snapshot predates that key.
      // Once a key is settled here its last request says nothing about the next edit,
      // and native must not chain that edit to the older result. A key with an unsaved
      // edit keeps its chain, so that edit stays ordered behind its own writes.
      const applyCanonical = incoming => {
        const incomingVersions = incoming.versions || {};
        for (const key of new Set([...Object.keys(versions), ...Object.keys(incomingVersions)])) {
          if (Object.hasOwn(incomingVersions, key)) {
            if (incomingVersions[key] < (versions[key] || 0)) continue;
            applyKey(key, incomingVersions[key], incoming);
          } else {
            if (Object.hasOwn(committed, key)) continue;
            delete versions[key];
          }
          if (!unsaved.has(key)) lastRequests.delete(key);
        }
      };
      window.__wovenArtifactStateReply = (token, requestID, payload) => {
        if (token !== config.token) return;
        const waiter = pending.get(requestID);
        if (!waiter) return;
        pending.delete(requestID);
        if (payload.state) {
          const incoming = payload.state;
          if (payload.error) applyCanonical(incoming);
          else if (Object.hasOwn(incoming.versions || {}, waiter.key)) {
            const version = incoming.versions[waiter.key];
            if (version >= (versions[waiter.key] || 0)) applyKey(waiter.key, version, incoming);
          }
        }
        if (payload.error) waiter.reject(new Error(payload.error));
        else waiter.resolve();
      };
      const save = (key, value, removing = false) => {
        if (!config.editable) return Promise.reject(new Error('This Artifact is read only.'));
        // Validate/copy now, before user code can mutate the supplied object.
        let copied;
        try { copied = removing ? null : clone(value); } catch (_) { return Promise.reject(new Error('Artifact state must be JSON.')); }
        if (removing) delete shadow[key]; else own(shadow, key, copied);
        const operation = {value: copied, removing};
        unsaved.set(key, operation);
        notify();
        const run = async () => {
          if (pausedError) throw pausedError;
          const requestID = String(++sequence);
          await new Promise((resolve, reject) => {
            pending.set(requestID, {resolve, reject, key});
            try {
              const edit = {action: removing ? 'remove' : 'set', key, expectedVersion: versions[key] ?? null};
              if (!removing) edit.value = copied;
              const previousRequestID = lastRequests.get(key) || null;
              lastRequests.set(key, requestID);
              window.webkit.messageHandlers.wovenArtifactState.postMessage({token: config.token, requestID, previousRequestID, edit});
            } catch (error) { pending.delete(requestID); reject(error); }
          });
          if (unsaved.get(key) === operation) { unsaved.delete(key); project(); }
        };
        // Post each input immediately. The native host owns sequencing, so all
        // accepted keystrokes survive the WebView closing before an earlier ack.
        const result = run();
        tail = Promise.allSettled([tail, result]).then(() => {});
        result.catch(error => { pausedError = error; errorEvent(error.message); });
        return result;
      };
      const flush = async () => { await tail; if (pausedError) throw pausedError; };
      const retry = async () => {
        await tail;
        pausedError = null;
        for (const [key, operation] of Array.from(unsaved)) {
          lastRequests.delete(key);
          await save(key, operation.value, operation.removing);
        }
        await flush();
      };
      function project() {
        const next = clone(committed);
        for (const [key, operation] of unsaved) {
          if (operation.removing) delete next[key];
          else own(next, key, operation.value);
        }
        shadow = next;
        restore(document);
        notify();
      }
      Object.defineProperty(window, 'wovenArtifact', {value: Object.freeze({
        get: (key, fallback = null) => Object.hasOwn(shadow, validKey(key)) ? clone(shadow[validKey(key)]) : fallback,
        getAll: () => Object.fromEntries(Object.entries(shadow).filter(([key]) => key.startsWith('app:')).map(([key, value]) => [key.slice(4), clone(value)])),
        set: (key, value) => save(validKey(key), value),
        remove: key => save(validKey(key), null, true),
        flush,
        retry,
        subscribe: listener => { listeners.add(listener); return () => listeners.delete(listener); },
        ready
      }), writable: false, configurable: false});
      window.__wovenArtifactRetry = retry;
      // Native data refreshes do not reload the document or discard unsaved UI.
      // `dataChanged` says whether `data` is a refresh. A caller that omits it gets a comparison.
      window.__wovenArtifactUpdate = (token, state, data, dataChanged) => {
        if (token !== config.token) return;
        applyCanonical(state);
        const refreshed = dataChanged == null ? canonical(data) !== deliveredData : Boolean(dataChanged);
        if (refreshed) {
          deliveredData = canonical(data);
          window.wovenMatterData = data;
        }
        project();
        if (refreshed) window.dispatchEvent(new CustomEvent('wovenmatterdatachange', {detail: data}));
      };
      // Read-only text stays a managed control after it stops being contenteditable,
      // so later refreshes still reach it and duplicate keys keep their positions.
      const readOnlyText = 'data-woven-readonly-text';
      const controlSelector = 'input,textarea,select,[contenteditable="true"][data-woven-key]' + (config.editable ? '' : ',[' + readOnlyText + '][data-woven-key]');
      function controlKey(element) {
        if (!element || !element.matches || element.closest('[data-woven-persist="false"]')) return null;
        if (!element.matches(controlSelector)) return null;
        const type = (element.type || element.tagName).toLowerCase();
        if (['password','file','hidden','button','submit','reset','image'].includes(type)) return null;
        const identity = element.getAttribute('data-woven-key') || element.id || element.name;
        if (!identity) return null;
        // Duplicate names (for example radio groups) remain distinct controls.
        const peers = Array.from(document.querySelectorAll(controlSelector))
          .filter(peer => (peer.getAttribute('data-woven-key') || peer.id || peer.name) === identity && (peer.type || peer.tagName).toLowerCase() === type);
        return 'form:' + type + ':' + identity + ':' + peers.indexOf(element);
      }
      function readControl(element) {
        if (element.type === 'checkbox' || element.type === 'radio') return element.checked;
        if (element.tagName === 'SELECT' && element.multiple) return Array.from(element.selectedOptions).map(option => option.value);
        return element.isContentEditable ? element.textContent : element.value;
      }
      function writeControl(element, value) {
        if (element.type === 'checkbox' || element.type === 'radio') { if (typeof value === 'boolean') element.checked = value; }
        else if (element.tagName === 'SELECT' && element.multiple) { if (Array.isArray(value)) for (const option of element.options) option.selected = value.includes(option.value); }
        else if (typeof value === 'string') {
          if (element.isContentEditable || element.matches('[' + readOnlyText + ']')) { if (element.textContent !== value) element.textContent = value; }
          else if (element.value !== value) element.value = value;
        }
      }
      // A read-only preview freezes only what it would otherwise save. Buttons, opted-out
      // and unidentified controls stay usable, because nothing they do is persisted.
      function freeze(element) {
        if (element.matches('[contenteditable="true"]')) {
          element.setAttribute(readOnlyText, '');
          element.contentEditable = 'false';
        } else if (!element.matches('[' + readOnlyText + ']')) element.disabled = true;
      }
      function restore(root) {
        const elements = root.querySelectorAll ? Array.from(root.querySelectorAll(controlSelector)) : [];
        if (root.matches && root.matches(controlSelector)) elements.unshift(root);
        for (const element of elements) {
          const key = controlKey(element);
          if (!key) continue;
          if (Object.hasOwn(shadow, key)) writeControl(element, shadow[key]);
          if (!config.editable) freeze(element);
        }
      }
      const input = event => {
        const key = controlKey(event.target);
        if (key && config.editable) {
          if (event.target.type === 'radio' && event.target.name) {
            for (const radio of document.querySelectorAll('input[type="radio"]')) {
              if (radio.type !== 'radio' || radio.name !== event.target.name || radio.form !== event.target.form) continue;
              const radioKey = controlKey(radio);
              if (radioKey && shadow[radioKey] !== radio.checked) save(radioKey, radio.checked).catch(() => {});
            }
            return;
          }
          const value = readControl(event.target);
          if (JSON.stringify(shadow[key]) !== JSON.stringify(value)) save(key, value).catch(() => {});
        }
      };
      document.addEventListener('input', input, true);
      document.addEventListener('change', input, true);
      const start = () => {
        restore(document);
        resolveReady();
        new MutationObserver(records => { for (const record of records) for (const node of record.addedNodes) restore(node); })
          .observe(document.body, {childList: true, subtree: true});
      };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, {once: true}); else start();
    })();
    """#
}
