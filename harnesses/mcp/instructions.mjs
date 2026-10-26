import { readFileSync } from 'node:fs';
export const wovenInstructions = readFileSync(new URL('../woven-instructions.txt', import.meta.url), 'utf8').trim();
export const appendWovenInstructions = text => [typeof text === 'string' ? text.replaceAll(wovenInstructions, '').trim() : '', wovenInstructions].filter(Boolean).join('\n\n');
