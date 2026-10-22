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

test('rejected and stopped steering cannot transfer CLI authority to a later accepted input', () => {
  const session = new SessionCLIContext(), child = new SessionCLIContext();
  const source = { PATH: '/usr/bin', WOVENMATTER_SOCKET: '/tmp/old.sock' };
  session.enqueue(input('active')); session.consumed();
  session.reconnect(input('connection-only'));
  const running = session.environment(source);
  const inherited = session.fork();
  assert.throws(() => inherited.reconnect(input('forbidden')), /cannot be changed/);
  assert.throws(() => inherited.enqueue(input('forbidden')), /cannot be changed/);
  inherited.consumed();
  const rollback = session.enqueue(input('rejected-steer')); rollback();
  session.enqueue(input('stopped-steer')); session.finish();
  assert.equal(session.environment(source).WOVENMATTER_CONTEXT_ID, 'active');
  session.enqueue({ ...input('accepted-next'), socketPath: '/tmp/new.sock' }); session.consumed();
  const next = session.environment(source);
  assert.equal(next.WOVENMATTER_CONTEXT_ID, 'accepted-next');
  assert.equal(next.WOVENMATTER_SOCKET, '/tmp/new.sock');
  assert.equal(running.WOVENMATTER_CONTEXT_ID, 'active');
  assert.equal(running.WOVENMATTER_SOCKET, '/tmp/bound.sock');
  assert.equal(child.environment(next).WOVENMATTER_CONTEXT_ID, undefined);
  assert.equal(inherited.environment(next).WOVENMATTER_CONTEXT_ID, 'active');
  assert.equal(inherited.environment(next).WOVENMATTER_SOCKET, '/tmp/bound.sock');
  session.consumed();
  assert.equal(session.environment(next).WOVENMATTER_CONTEXT_ID, undefined);
});
