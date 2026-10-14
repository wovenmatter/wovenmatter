import { readFileSync } from 'node:fs';

// Managed SDK generations relocate src. The bundled worker supplies the one
// authoritative app resource before importing a generation's session engine.
const resource = process.env.WOVENMATTER_INSTRUCTIONS_FILE
  ?? new URL('../../harnesses/woven-instructions.txt', import.meta.url);
export const wovenInstructions = readFileSync(resource, 'utf8').trim();
