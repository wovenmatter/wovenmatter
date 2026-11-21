import { isAbsolute } from 'node:path';

// The folder the server gives this process: `pi-durable.sqlite` and caches.
export function dataDirectory() {
  const value = process.env.WOVEN_PI_DATA;
  if (!value || !isAbsolute(value)) throw new Error('WOVEN_PI_DATA must name an absolute directory.');
  return value;
}
