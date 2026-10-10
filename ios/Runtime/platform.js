// Host capabilities for the bundled SDK. No Node process or downloaded code runs here.
export function nativeSync(operation, value) {
  const result = JSON.parse(globalThis.__wmNativeSync(operation, JSON.stringify(value)));
  if (!result.ok) { const error = new Error(result.error); error.code = result.errorCode; throw error; }
  return result.value;
}
if (!globalThis.queueMicrotask) globalThis.queueMicrotask = callback => Promise.resolve().then(callback);
if (!globalThis.structuredClone) globalThis.structuredClone = value => JSON.parse(JSON.stringify(value));
if (!globalThis.DOMException) globalThis.DOMException = class DOMException extends Error {
  constructor(message, name = 'Error') { super(message); this.name = name; }
};
if (!globalThis.AbortController) {
  class Signal {
    aborted = false; reason = undefined; listeners = new Map();
    addEventListener(type, listener, options) { if (type === 'abort') this.listeners.set(listener, options); }
    removeEventListener(type, listener) { if (type === 'abort') this.listeners.delete(listener); }
    throwIfAborted() { if (this.aborted) throw this.reason; }
    abort(reason = new DOMException('The operation was aborted', 'AbortError')) {
      if (this.aborted) return;
      this.aborted = true; this.reason = reason;
      for (const [listener, options] of [...this.listeners]) {
        if (options?.once) this.listeners.delete(listener);
        if (typeof listener === 'function') listener.call(this, {type:'abort',target:this});
        else listener.handleEvent({type:'abort',target:this});
      }
      this.onabort?.({type:'abort',target:this});
    }
    static abort(reason) { const signal = new Signal(); signal.abort(reason); return signal; }
    static any(signals) {
      const output = new Signal(); const listeners = [];
      for (const signal of signals) {
        if (signal.aborted) { output.abort(signal.reason); break; }
        const callback = () => output.abort(signal.reason);
        signal.addEventListener('abort', callback, {once:true}); listeners.push([signal,callback]);
      }
      const cleanup = () => { for (const [signal, callback] of listeners) signal.removeEventListener('abort',callback); };
      if (output.aborted) cleanup(); else output.addEventListener('abort', cleanup, {once:true});
      return output;
    }
    static timeout(ms) { const signal = new Signal(); setTimeout(() => signal.abort(new DOMException('Timed out', 'TimeoutError')),ms); return signal; }
  }
  globalThis.AbortSignal = Signal;
  globalThis.AbortController = class { signal = new Signal(); abort(reason) { this.signal.abort(reason); } };
}
if (!globalThis.crypto) globalThis.crypto = {
  getRandomValues(array) {
    if (!(ArrayBuffer.isView(array)) || array instanceof Float32Array || array instanceof Float64Array) throw new TypeError('Expected integer typed array');
    if (array.byteLength > 65536) throw new RangeError('Random request too large');
    new Uint8Array(array.buffer, array.byteOffset, array.byteLength).set(nativeSync('random',array.byteLength));
    return array;
  },
  randomUUID() { return nativeSync('uuid',null); },
};
if (!globalThis.TextEncoder) globalThis.TextEncoder = class {
  encoding = 'utf-8';
  encode(value = '') { return new Uint8Array(nativeSync('encode',String(value))); }
  encodeInto(value, destination) {
    let read = 0, written = 0;
    for (const character of value) {
      const bytes = this.encode(character); if (written + bytes.length > destination.length) break;
      destination.set(bytes,written); written += bytes.length; read += character.length;
    }
    return {read,written};
  }
};
if (!globalThis.TextDecoder) globalThis.TextDecoder = class {
  encoding = 'utf-8'; pending = []; first = true;
  constructor(label = 'utf-8', options = {}) {
    if (!['utf-8','utf8'].includes(label.toLowerCase())) throw new RangeError('Only UTF-8 is supported');
    this.fatal = !!options.fatal; this.ignoreBOM = !!options.ignoreBOM;
  }
  decode(input = new Uint8Array(), options = {}) {
    const view = input instanceof ArrayBuffer ? new Uint8Array(input) : new Uint8Array(input.buffer,input.byteOffset,input.byteLength);
    let bytes = this.pending.concat(Array.from(view)); this.pending = [];
    if (options.stream && bytes.length) {
      let start = bytes.length - 1;
      while (start > 0 && (bytes[start] & 0xc0) === 0x80) start--;
      const first = bytes[start]; const needed = first >= 0xf0 ? 4 : first >= 0xe0 ? 3 : first >= 0xc2 ? 2 : 1;
      if (bytes.length-start < needed) { this.pending = bytes.slice(start); bytes = bytes.slice(0,start); }
    }
    let text = nativeSync('decode',{bytes,fatal:this.fatal});
    if (this.first && text.length) { this.first = false; if (!this.ignoreBOM && text.charCodeAt(0) === 0xfeff) text = text.slice(1); }
    if (!options.stream) { this.pending = []; this.first = true; }
    return text;
  }
};
let nextTimer = 0;
const timers = new Map();
if (!globalThis.setTimeout) {
  globalThis.setTimeout = (callback, delay = 0, ...args) => {
    const id = ++nextTimer; timers.set(id, () => callback(...args)); globalThis.__wmScheduleTimer(id,Math.max(0,Number(delay)||0)); return id;
  };
  globalThis.clearTimeout = id => { timers.delete(id); globalThis.__wmCancelTimer(id); };
}
globalThis.__wmTimerFired = id => { const callback = timers.get(id); timers.delete(id); callback?.(); };
if (!globalThis.performance) globalThis.performance = {now:() => Date.now()};

// TypeBox resolves local JSON Schema references through URL. Foundation supplies parsing;
// there is no browser navigation, fetch, or access to arbitrary native objects here.
if (!globalThis.URL) globalThis.URL = class {
  constructor(input, base) { Object.assign(this,nativeSync('url',{input:String(input),base:base===undefined?null:String(base)})); }
  toString() { return this.href; }
  toJSON() { return this.href; }
  static canParse(input,base) { try { new this(input,base); return true; } catch { return false; } }
};
