import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';

// Exercise the exact JavaScript embedded by the native renderer, without
// WebKit, a provider, or a separately maintained implementation of the bridge.
const source = readFileSync(new URL('../../shared/Sources/WovenMatterShared/ArtifactStateJavaScript.swift', import.meta.url), 'utf8');
const script = source.split('public static let bootstrap = #"""')[1].split('"""#')[0];
const tick = () => new Promise(resolve => setImmediate(resolve));
const plain = value => JSON.parse(JSON.stringify(value));

// Selectors are evaluated rather than stubbed, so a control the bridge must
// leave alone is really out of reach, as it would be in WebKit.
const element = {
  getAttribute(name) { return name === 'type' ? this.type ?? null : this.attributes[name] ?? null; },
  setAttribute(name, value) { this.attributes[name] = String(value); },
  matches(selector) {
    return selector.split(',').some(part => {
      const [, tag, conditions] = part.trim().match(/^([a-z]*)(.*)$/);
      if (tag && this.tagName.toLowerCase() !== tag) return false;
      return [...conditions.matchAll(/\[([\w-]+)(?:="([^"]*)")?\]/g)].every(([, name, value]) =>
        value === undefined ? this.getAttribute(name) !== null : this.getAttribute(name) === value);
    });
  },
  closest() { return this.optedOut ? this : null; }
};

function control(type, identity, value = '') {
  return {
    ...element, type, id: identity, name: '', tagName: { textarea: 'TEXTAREA', button: 'BUTTON' }[type] ?? 'INPUT',
    value, checked: false, multiple: false, isContentEditable: false,
    attributes: {}, optedOut: false
  };
}

function editableText(key, text = '') {
  return {
    ...element, id: '', name: '', tagName: 'DIV', textContent: text, optedOut: false,
    attributes: { contenteditable: 'true', ...(key ? { 'data-woven-key': key } : {}) },
    get isContentEditable() { return this.attributes.contenteditable === 'true'; },
    set contentEditable(value) { this.attributes.contenteditable = value; }
  };
}

function harness({ snapshot = { values: {}, versions: {} }, controls = [], autoReply = true, editable = true, data } = {}) {
  const requests = [], listeners = new Map(), writes = new Map();
  const window = new EventTarget();
  if (data !== undefined) window.wovenMatterData = plain(data);
  let saved = plain(snapshot), injectedError;
  const document = {
    readyState: 'complete', body: {},
    querySelectorAll(selector) { return controls.filter(item => item.matches(selector)); },
    addEventListener(name, callback) { listeners.set(name, callback); }
  };
  const context = vm.createContext({
    window, document, console,
    CustomEvent: class extends Event { constructor(type, options) { super(type); this.detail = options?.detail; } },
    MutationObserver: class { observe() {} },
    setTimeout, clearTimeout
  });
  window.__wovenArtifactConfiguration = { token: 'document-token', state: plain(snapshot), editable };
  const reply = (request, error = null) => window.__wovenArtifactStateReply('document-token', request.requestID, { state: plain(saved), error });
  window.webkit = { messageHandlers: { wovenArtifactState: { postMessage(raw) {
    const request = plain(raw); requests.push(request);
    if (!autoReply) return;
    const { edit } = request;
    let error = injectedError;
    injectedError = undefined;
    // As in enqueueArtifactInput: a chained write takes its expected version from
    // its predecessor's result, and fails with that predecessor.
    const predecessor = request.previousRequestID && writes.get(request.previousRequestID);
    if (predecessor) {
      error ||= predecessor.error;
      edit.expectedVersion = predecessor.version ?? null;
    }
    if (!error && (edit.expectedVersion ?? null) !== (saved.versions[edit.key] ?? null)) error = 'state conflict';
    if (!error) {
      saved.versions[edit.key] = (saved.versions[edit.key] ?? 0) + 1;
      if (edit.action === 'remove') delete saved.values[edit.key]; else saved.values[edit.key] = edit.value;
    }
    writes.set(request.requestID, { error, version: saved.versions[edit.key] });
    queueMicrotask(() => reply(request, error));
  } } } };
  vm.runInContext(script, context);
  return {
    window, requests,
    saved: () => plain(saved),
    setSaved(value) { saved = plain(value); },
    failNext(message) { injectedError = message; },
    input(element, event = 'input') { listeners.get(event)?.({ target: element }); },
    reply,
    update(state, data, ...dataChanged) { window.__wovenArtifactUpdate('document-token', plain(state), plain(data), ...dataChanged); },
    events() {
      const counts = { data: 0, app: 0, subscriber: 0 };
      window.addEventListener('wovenmatterdatachange', () => { counts.data += 1; });
      window.addEventListener('wovenartifactchange', () => { counts.app += 1; });
      window.wovenArtifact.subscribe(() => { counts.subscriber += 1; });
      return counts;
    }
  };
}

test('custom state waits for durable acknowledgement and preserves JSON null, arrays and deletion versions', async () => {
  const h = harness();
  await h.window.wovenArtifact.ready;
  await h.window.wovenArtifact.set('planner', { days: ['Monday'], done: false, amount: 1.5 });
  assert.deepEqual(plain(h.window.wovenArtifact.get('planner')), { days: ['Monday'], done: false, amount: 1.5 });
  await h.window.wovenArtifact.set('nullable', null);
  assert.equal(h.window.wovenArtifact.get('nullable', 'missing'), null);
  await h.window.wovenArtifact.remove('nullable');
  assert.equal(h.window.wovenArtifact.get('nullable', 'missing'), 'missing');
  await h.window.wovenArtifact.set('nullable', 'restored');
  assert.equal(h.requests.at(-1).edit.expectedVersion, 2);
  assert.equal(h.saved().values['app:nullable'], 'restored');
  assert.ok(h.requests.every(r => !Object.hasOwn(r, 'noteID') && !Object.hasOwn(r, 'html')));
});

test('a write promise stays pending until the host acknowledges its save', async () => {
  const h = harness({ autoReply: false });
  let completed = false;
  const saving = h.window.wovenArtifact.set('x', 42).then(() => { completed = true; });
  await tick();
  assert.equal(completed, false);
  h.setSaved({ values: { 'app:x': 42 }, versions: { 'app:x': 1 } });
  h.reply(h.requests[0]);
  await saving;
  assert.equal(completed, true);
});

test('standard form inputs and checkbox changes survive closing and reopening the Artifact', async () => {
  const name = control('text', 'name'), done = control('checkbox', 'done');
  const h = harness({ controls: [name, done] });
  name.value = 'A saved trip'; h.input(name);
  done.checked = true; h.input(done, 'change');
  await h.window.wovenArtifact.flush();
  const reopenedName = control('text', 'name'), reopenedDone = control('checkbox', 'done');
  const reopened = harness({ snapshot: h.saved(), controls: [reopenedName, reopenedDone] });
  await reopened.window.wovenArtifact.ready;
  assert.equal(reopenedName.value, 'A saved trip');
  assert.equal(reopenedDone.checked, true);
});

test('data refresh updates custom subscribers without overwriting pending user input', async () => {
  const field = control('text', 'title');
  const h = harness({ controls: [field], autoReply: false });
  field.value = 'Still typing'; h.input(field);
  await tick();
  h.update({ values: { 'form:text:title:0': 'Old saved value', 'app:count': 7 }, versions: { 'form:text:title:0': 1, 'app:count': 1 } }, { rows: [[42]] });
  assert.equal(field.value, 'Still typing');
  assert.equal(h.window.wovenArtifact.get('count'), 7);
  assert.deepEqual(plain(h.window.wovenMatterData), { rows: [[42]] });
  h.setSaved({ values: { 'form:text:title:0': 'Still typing' }, versions: { 'form:text:title:0': 2 } });
  h.reply(h.requests[0]);
  await h.window.wovenArtifact.flush();
});

test('save failure retains visible input, pauses queued writes, and explicit retry uses current key versions', async () => {
  const h = harness();
  h.setSaved({ values: { 'app:x': 'Other editor' }, versions: { 'app:x': 2 } });
  await assert.rejects(h.window.wovenArtifact.set('x', 'My input'), /state conflict/);
  assert.equal(h.window.wovenArtifact.get('x'), 'My input');
  await assert.rejects(h.window.wovenArtifact.set('y', 'Queued input'), /state conflict/);
  assert.equal(h.requests.length, 1);
  await h.window.wovenArtifact.retry();
  assert.equal(h.saved().values['app:x'], 'My input');
  assert.equal(h.saved().values['app:y'], 'Queued input');
  assert.equal(h.requests[1].edit.expectedVersion, 2);
});

test('passwords, files, hidden controls and opted-out values are excluded from automatic persistence', async () => {
  const controls = ['password', 'file', 'hidden'].map(type => control(type, type, 'private'));
  const ignored = control('text', 'ignored', 'temporary'); ignored.optedOut = true; controls.push(ignored);
  const unnamed = control('text', '', 'no stable identifier'); controls.push(unnamed);
  const h = harness({ controls });
  for (const field of controls) h.input(field);
  await tick();
  assert.equal(h.requests.length, 0);
});

test('invalid reply tokens cannot acknowledge a write from another document generation', async () => {
  const h = harness({ autoReply: false });
  let saved = false;
  const pending = h.window.wovenArtifact.set('x', 1).then(() => { saved = true; });
  await tick();
  h.window.__wovenArtifactStateReply('old-document-token', h.requests[0].requestID, { state: { values: {}, versions: {} } });
  await tick();
  assert.equal(saved, false);
  h.reply(h.requests[0]);
  await pending;
});

test('changing a radio choice persists the unchecked sibling as well as the selected choice', async () => {
  const first = control('radio', 'first'), second = control('radio', 'second');
  first.name = second.name = 'choice';
  const h = harness({ controls: [first, second] });
  first.checked = true; h.input(first); await h.window.wovenArtifact.flush();
  first.checked = false; second.checked = true; h.input(second); await h.window.wovenArtifact.flush();
  const reopenedFirst = control('radio', 'first'), reopenedSecond = control('radio', 'second');
  reopenedFirst.name = reopenedSecond.name = 'choice';
  const reopened = harness({ snapshot: h.saved(), controls: [reopenedFirst, reopenedSecond] });
  await reopened.window.wovenArtifact.ready;
  assert.equal(reopenedFirst.checked, false);
  assert.equal(reopenedSecond.checked, true);
});

test('read-only previews restore saved inputs and reject edits instead of accepting transient values', async () => {
  const field = control('text', 'title');
  const h = harness({ controls: [field], editable: false,
    snapshot: { values: { 'form:text:title:0': 'Saved on Mac', 'app:x': 1 }, versions: { 'form:text:title:0': 1, 'app:x': 1 } } });
  await h.window.wovenArtifact.ready;
  assert.equal(field.value, 'Saved on Mac');
  assert.equal(field.disabled, true);
  assert.equal(h.window.wovenArtifact.get('x'), 1);
  await assert.rejects(h.window.wovenArtifact.set('x', 2), /read only/);
  assert.equal(h.requests.length, 0);
});

test('rapid typing transfers every input to the native host before waiting for a prior acknowledgement', async () => {
  const field = control('text', 'title');
  const h = harness({ controls: [field] });
  for (const text of ['a', 'ab', 'abc']) { field.value = text; h.input(field); }
  assert.equal(h.requests.length, 3);
  assert.equal(h.requests[1].previousRequestID, h.requests[0].requestID);
  assert.equal(h.requests[2].previousRequestID, h.requests[1].requestID);
  const reopenedField = control('text', 'title');
  const reopened = harness({ snapshot: h.saved(), controls: [reopenedField] });
  assert.equal(reopenedField.value, 'abc');
  await h.window.wovenArtifact.flush();
});

test('an edit after an observed external update uses its version, without chaining to the earlier save', async () => {
  const h = harness();
  await h.window.wovenArtifact.set('x', 'mine');
  const external = { values: { 'app:x': 'From another editor' }, versions: { 'app:x': 5 } };
  h.setSaved(external);
  h.update(external, null, false);
  assert.equal(h.window.wovenArtifact.get('x'), 'From another editor');
  await h.window.wovenArtifact.set('x', 'next edit');
  const next = h.requests.at(-1);
  assert.equal(next.previousRequestID, null);
  assert.equal(next.edit.expectedVersion, 5);
  assert.equal(h.saved().values['app:x'], 'next edit');
  assert.equal(h.saved().versions['app:x'], 6);
});

test('an external update keeps the chain and the visible input of a key with an unsaved edit', async () => {
  const field = control('text', 'title');
  const key = 'form:text:title:0';
  const h = harness({ controls: [field], autoReply: false });
  field.value = 'typ'; h.input(field);
  h.update({ values: { [key]: 'From another editor' }, versions: { [key]: 5 } }, null, false);
  assert.equal(field.value, 'typ');
  field.value = 'typing'; h.input(field);
  assert.equal(h.requests[1].previousRequestID, h.requests[0].requestID);
  assert.equal(h.requests[1].edit.expectedVersion, 5);
  h.setSaved({ values: { [key]: 'typing' }, versions: { [key]: 7 } });
  h.reply(h.requests[0]);
  h.reply(h.requests[1]);
  await h.window.wovenArtifact.flush();
  assert.equal(field.value, 'typing');
});

test('an external update only clears the chain of the keys that have no unsaved edit', async () => {
  const h = harness({ autoReply: false });
  const settled = h.window.wovenArtifact.set('settled', 1);
  h.setSaved({ values: { 'app:settled': 1 }, versions: { 'app:settled': 1 } });
  h.reply(h.requests[0]);
  await settled;
  h.window.wovenArtifact.set('typing', 'a');
  h.update({ values: { 'app:settled': 1, 'app:typing': 'b' }, versions: { 'app:settled': 2, 'app:typing': 2 } }, null, false);
  h.window.wovenArtifact.set('settled', 3);
  h.window.wovenArtifact.set('typing', 'c');
  const [settledEdit, typingEdit] = h.requests.slice(-2);
  assert.equal(settledEdit.previousRequestID, null);
  assert.equal(settledEdit.edit.expectedVersion, 2);
  assert.equal(typingEdit.previousRequestID, h.requests[1].requestID);
});

test('a delayed snapshot cannot rewind a key, while newer keys in it still apply', async () => {
  const h = harness({ autoReply: false, snapshot: {
    values: { 'app:ahead': 'current', 'app:behind': 'old', 'app:live': 'kept' },
    versions: { 'app:ahead': 5, 'app:behind': 1, 'app:live': 2, 'app:removed': 3 }
  } });
  h.update({ values: { 'app:ahead': 'stale', 'app:behind': 'newer' }, versions: { 'app:ahead': 3, 'app:behind': 2 } }, null, false);
  assert.equal(h.window.wovenArtifact.get('ahead'), 'current');
  assert.equal(h.window.wovenArtifact.get('behind'), 'newer');
  assert.equal(h.window.wovenArtifact.get('live'), 'kept');
  for (const key of ['ahead', 'behind', 'live', 'removed']) h.window.wovenArtifact.set(key, 'edit');
  assert.deepEqual(h.requests.map(request => request.edit.expectedVersion), [5, 2, 2, null]);
});

test('the snapshot in a failed save cannot rewind another key, and retry uses the failed key version', async () => {
  const h = harness({ autoReply: false, snapshot: {
    values: { 'app:x': 'current', 'app:y': 'old' }, versions: { 'app:x': 5, 'app:y': 1 }
  } });
  const failed = h.window.wovenArtifact.set('y', 'mine');
  h.setSaved({ values: { 'app:x': 'stale', 'app:y': 'other' }, versions: { 'app:x': 3, 'app:y': 2 } });
  h.reply(h.requests[0], 'state conflict');
  await assert.rejects(failed, /state conflict/);
  const retried = h.window.wovenArtifact.retry();
  await tick();
  assert.equal(h.requests[1].previousRequestID, null);
  assert.equal(h.requests[1].edit.expectedVersion, 2);
  h.setSaved({ values: { 'app:x': 'stale', 'app:y': 'mine' }, versions: { 'app:x': 3, 'app:y': 3 } });
  h.reply(h.requests[1]);
  await retried;
  assert.equal(h.window.wovenArtifact.get('x'), 'current');
  assert.equal(h.window.wovenArtifact.get('y'), 'mine');
});

test('a state-only update leaves linked data alone and emits no data event', async () => {
  const data = { rows: [[1]] };
  const h = harness({ data });
  const events = h.events();
  h.update({ values: { 'app:x': 1 }, versions: { 'app:x': 1 } }, null, false);
  assert.equal(events.data, 0);
  assert.deepEqual(plain(h.window.wovenMatterData), data);
  assert.equal(h.window.wovenArtifact.get('x'), 1);
  assert.equal(events.app, 1);
  assert.equal(events.subscriber, 1);
});

test('saving emits one app event: neither the acknowledgement nor its native echo repeats it', async () => {
  const h = harness({ data: { rows: [[1]] } });
  const events = h.events();
  await h.window.wovenArtifact.set('x', { b: 1, a: [2] });
  assert.equal(events.app, 1);
  h.update(h.saved(), null, false);
  h.update({ values: { 'app:x': { a: [2], b: 1 } }, versions: h.saved().versions }, { rows: [[1]] });
  await h.window.wovenArtifact.set('x', { a: [2], b: 1 });
  assert.deepEqual(events, { data: 0, app: 1, subscriber: 1 });
  await h.window.wovenArtifact.set('x', { a: [3], b: 1 });
  assert.deepEqual(events, { data: 0, app: 2, subscriber: 2 });
});

test('a form value changed elsewhere reaches its control without an app or data event', async () => {
  const field = control('text', 'title');
  const key = 'form:text:title:0';
  const h = harness({ controls: [field], snapshot: { values: { [key]: 'Old' }, versions: { [key]: 1 } } });
  const events = h.events();
  h.update({ values: { [key]: 'From Mac' }, versions: { [key]: 2 } }, null, false);
  assert.equal(field.value, 'From Mac');
  assert.deepEqual(events, { data: 0, app: 0, subscriber: 0 });
});

test('a data refresh delivers its data and one event, whether named by native or detected', async () => {
  const state = { values: {}, versions: {} };
  const h = harness({ data: { rows: [[1]] } });
  const events = h.events();
  h.update(state, { rows: [[2]] }, true);
  assert.equal(events.data, 1);
  assert.deepEqual(plain(h.window.wovenMatterData), { rows: [[2]] });
  h.update(state, { rows: [[2]] });
  assert.equal(events.data, 1);
  h.update(state, { rows: [[3]] });
  assert.equal(events.data, 2);
  assert.deepEqual(plain(h.window.wovenMatterData), { rows: [[3]] });
  assert.equal(events.app, 0);
});

test('without a data link, a three-argument update reports no data change', async () => {
  const h = harness();
  const events = h.events();
  h.update({ values: {}, versions: {} }, null);
  assert.equal(events.data, 0);
});

test('a data refresh does not discard pending input', async () => {
  const field = control('text', 'title');
  const h = harness({ controls: [field], autoReply: false, data: { rows: [[1]] } });
  const events = h.events();
  field.value = 'Still typing'; h.input(field);
  h.update({ values: {}, versions: {} }, { rows: [[2]] }, true);
  assert.equal(field.value, 'Still typing');
  assert.equal(events.data, 1);
});

test('read-only previews freeze only the controls that would be saved', async () => {
  const title = control('text', 'title');
  const text = editableText('summary');
  const filter = control('text', 'filter'); filter.optedOut = true;
  const search = control('text', '');
  const secret = control('password', 'secret');
  const run = control('button', 'run');
  const inputButton = control('submit', 'send');
  const scratch = editableText(null, 'Scratch');
  const h = harness({ editable: false, controls: [title, text, filter, search, secret, run, inputButton, scratch], snapshot: {
    values: { 'form:text:title:0': 'Saved title', 'form:div:summary:0': 'Saved summary' },
    versions: { 'form:text:title:0': 1, 'form:div:summary:0': 1 }
  } });
  await h.window.wovenArtifact.ready;
  assert.equal(title.value, 'Saved title');
  assert.equal(title.disabled, true);
  assert.equal(text.textContent, 'Saved summary');
  assert.equal(text.isContentEditable, false);
  for (const free of [filter, search, secret, run, inputButton]) assert.notEqual(free.disabled, true);
  assert.equal(scratch.isContentEditable, true);
  assert.equal(scratch.textContent, 'Scratch');
  search.value = 'Local only'; h.input(search);
  filter.value = 'Also local'; h.input(filter);
  assert.equal(h.requests.length, 0);
  assert.equal(search.value, 'Local only');
});

test('read-only text keeps following saved state, and duplicate keys keep their own values', async () => {
  const first = editableText('note'), second = editableText('note');
  const [firstKey, secondKey] = ['form:div:note:0', 'form:div:note:1'];
  const h = harness({ editable: false, controls: [first, second], snapshot: {
    values: { [firstKey]: 'One', [secondKey]: 'Two' }, versions: { [firstKey]: 1, [secondKey]: 1 }
  } });
  await h.window.wovenArtifact.ready;
  assert.deepEqual([first.textContent, second.textContent], ['One', 'Two']);
  h.update({ values: { [firstKey]: 'One updated', [secondKey]: 'Two updated' }, versions: { [firstKey]: 2, [secondKey]: 2 } }, null, false);
  assert.deepEqual([first.textContent, second.textContent], ['One updated', 'Two updated']);
  assert.equal(first.isContentEditable, false);
  assert.equal(second.isContentEditable, false);
});
