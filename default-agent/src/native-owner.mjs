import lockfile from 'proper-lockfile';

// The SDK requires one store owner. Atomic lock-directory acquisition protects
// separate runtimes; the library owns heartbeat expiry and compromise checks.
export const ownNativeStore = (root, onCompromised) => lockfile.lock(root, {
  realpath: false, retries: 0, stale: 120000, update: 10000, onCompromised,
});
