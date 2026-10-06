import test from 'node:test';
import assert from 'node:assert/strict';
import { SessionCLIContext } from '../src/cli-context.mjs';

const input = captureID => ({ executablePath: '/app/bin/wovenmatter', socketPath: '/tmp/bound.sock', captureID });

test('consumed inputs change future shells without retargeting existing or other-session shells', () => {
  const session = new SessionCLIContext(), other = new SessionCLIContext();
  const base = { PATH: '/usr/bin', PI_SESSION_ID: 'native', WOVENMATTER_NOTE_ID: 'stale-note' };
  session.enqueue(input('first')); session.consumed();
  const runningShell = session.environment(base);
  session.enqueue(input('second'));
  assert.equal(session.environment(base).WOVENMATTER_CONTEXT_ID, 'first');
  assert.equal(other.environment(base).WOVENMATTER_CONTEXT_ID, undefined);
  session.consumed();
  assert.equal(session.environment(base).WOVENMATTER_CONTEXT_ID, 'second');
  assert.equal(runningShell.WOVENMATTER_CONTEXT_ID, 'first');
  assert.equal(runningShell.PI_SESSION_ID, 'native');
  assert.equal(runningShell.WOVENMATTER_NOTE_ID, undefined);
  assert.equal(runningShell.PATH, '/app/bin:/usr/bin');
  // Unbound native input must clear, never inherit, the previous capture.
  session.consumed();
  assert.equal(session.environment(runningShell).WOVENMATTER_CONTEXT_ID, undefined);
});

test('rejected and cancelled inputs cannot become the next message binding', () => {
  const session = new SessionCLIContext();
  session.enqueue(input('first')); session.consumed();
  const reject = session.enqueue(input('rejected')); reject();
  session.enqueue(input('cancelled')); session.finish();
  session.enqueue({ ...input('next'), socketPath: undefined }); session.consumed();
  assert.equal(session.environment({}).WOVENMATTER_CONTEXT_ID, 'next');
  assert.equal(session.environment({ WOVENMATTER_SOCKET: 'old' }).WOVENMATTER_SOCKET, undefined);
});


test('reconnecting preserves the active capture and existing shell snapshots', () => {
  const session = new SessionCLIContext();
  session.enqueue(input('active')); session.consumed();
  const prior = session.environment({});
  session.reconnect({ ...input(''), socketPath: '/tmp/new.sock' });
  assert.equal(session.environment({}).WOVENMATTER_CONTEXT_ID, 'active');
  assert.equal(session.environment({}).WOVENMATTER_SOCKET, '/tmp/new.sock');
  assert.equal(prior.WOVENMATTER_SOCKET, '/tmp/bound.sock');
});
