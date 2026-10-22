#!/usr/bin/env node
// Offline CPython/Pyodide resources from the current build installation.
import {createRequire} from 'node:module';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const source=path.join(root,'ios/EmbeddedRuntime'), output=path.join(root,'ios/Sources/EmbeddedExecution/Resources');
const digest=data=>createHash('sha256').update(data).digest('hex');
const inputs=['worker.js','commands.py','package.json','package-lock.json','licenses.json'];
const inputHashes=Object.fromEntries(await Promise.all(inputs.map(async name=>[name,digest(await readFile(path.join(source,name)))])));
if(process.argv.includes('--check')) {
  const provenance=JSON.parse(await readFile(path.join(output,'provenance.json'),'utf8'));
  if(JSON.stringify(inputHashes)!==JSON.stringify(provenance.sources)) throw Error('Embedded runtime sources changed; rebuild with node scripts/build-ios-embedded-runtime.mjs');
  for(const [name,hash] of Object.entries(provenance.resources)) if(digest(await readFile(path.join(output,name)))!==hash) throw Error('Embedded runtime resource mismatch: '+name);
  console.log(`Verified offline CPython ${provenance.pythonVersion} / Pyodide ${provenance.version} resources`); process.exit(0);
}
const require=createRequire(path.join(source,'package.json')), {build}=require('esbuild');
const packageRoot=path.dirname(require.resolve('pyodide/package.json'));
const manifest=JSON.parse(await readFile(path.join(packageRoot,'package.json'),'utf8'));
await mkdir(output,{recursive:true});
const bundle=await build({absWorkingDir:root,entryPoints:['ios/EmbeddedRuntime/worker.js'],bundle:true,platform:'browser',format:'iife',target:'es2022',external:['node:*'],legalComments:'linked',outfile:path.join(output,'worker.js'),write:false});
const resources={};
for(const file of bundle.outputFiles) { await writeFile(file.path,file.contents); resources[path.basename(file.path)]=digest(file.contents); }
for(const name of ['pyodide.asm.wasm','python_stdlib.zip']) {
  const bytes=await readFile(path.join(packageRoot,name));await writeFile(path.join(output,name),bytes);resources[name]=digest(bytes);
}
// Only the core/stdlib runtime is bundled. No third-party package catalog or CDN fallback is advertised.
const upstreamLock=JSON.parse(await readFile(path.join(packageRoot,'pyodide-lock.json'),'utf8'));
const offlineLock=Buffer.from(JSON.stringify({info:upstreamLock.info,packages:{}},null,2)+'\n');
await writeFile(path.join(output,'pyodide-lock.json'),offlineLock);resources['pyodide-lock.json']=digest(offlineLock);
const commands=await readFile(path.join(source,'commands.py'));await writeFile(path.join(output,'commands.py'),commands);resources['commands.py']=digest(commands);
for(const license of JSON.parse(await readFile(path.join(source,'licenses.json'),'utf8'))) {
  // Notices are checked in. Regeneration never silently changes upstream licensing.
  const bytes=await readFile(path.join(output,license.file));
  if(digest(bytes)!==license.sha256) throw Error('License notice mismatch: '+license.file);
  resources[license.file]=license.sha256;
}
const lock=JSON.parse(await readFile(path.join(source,'package-lock.json'),'utf8'));
await writeFile(path.join(output,'provenance.json'),JSON.stringify({runtime:'Pyodide',version:manifest.version,pythonVersion:upstreamLock.info.python,source:'https://github.com/pyodide/pyodide/tree/'+manifest.version,npmIntegrity:lock.packages['node_modules/pyodide'].integrity,sources:inputHashes,resources},null,2)+'\n');
console.log(`Bundled offline CPython ${upstreamLock.info.python} / Pyodide ${manifest.version}`);
