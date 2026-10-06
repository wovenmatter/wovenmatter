// Source-tree bridge. Installation replaces this with the self-contained module.
import { harnessResource } from '../harness-resources.mjs'
export const { binding, bindGeneration, connect, shellInput } = await import(harnessResource('cli/binding.mjs'))
