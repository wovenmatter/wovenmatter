import {loadPyodide} from 'pyodide';
import createPyodideModule from 'pyodide/pyodide.asm.mjs';

// The entire engine is bundled. fetch is a closed asset map, never a network fallback.
const nativePost = self.postMessage.bind(self), waiting = new Map();
let started = false, nextCall = 0, runtimeFS;
const decode = base64 => Uint8Array.from(atob(base64), c => c.charCodeAt(0));
const encode = bytes => { let result = ''; for (let i=0;i<bytes.length;i+=32768) result += String.fromCharCode(...bytes.subarray(i,i+32768)); return btoa(result); };
self.onmessage = async event => {
  const request = event.data;
  if (request.type === 'reply') {
    const continuation = waiting.get(request.id); if (!continuation) return;
    waiting.delete(request.id);
    if (request.ok && request.files?.length) {
      try {
        // Native imports only explicitly approved, newly created artifact paths.
        // Never replace a file that generated Python has already changed.
        for (const file of request.files) {
          const path = '/workspace/' + file.path;
          if (runtimeFS.analyzePath(path).exists) throw new Error('An imported artifact conflicts with virtual workspace changes: ' + file.path);
          const parts = path.split('/'); parts.pop();
          runtimeFS.mkdirTree(parts.join('/'));
          runtimeFS.writeFile(path,decode(file.data));
        }
      } catch (error) {
        nativePost({type:'failure',message:String(error?.message || error)}); return;
      }
    }
    request.ok ? continuation.resolve(request.value) : continuation.reject(new Error(request.error)); return;
  }
  if (started || request.type !== 'run') return;
  for (const level of ["warn","error"]) console[level] = (...args) => nativePost({type:"output",stream:"stderr",text:args.map(String).join(" ")+"\n"});
  started = true;
  try {
    const assetRoot = 'https://woven-runtime.invalid/';
    const assets = new Map(Object.entries(request.assets).map(([name, base64]) => [assetRoot + name, decode(base64)]));
    self.fetch = async input => {
      const url = typeof input === 'string' ? input : (input.url ?? String(input));
      const bytes = assets.get(url);
      if (!bytes) throw new Error('Network and unbundled runtime assets are unavailable: ' + url);
      return new Response(bytes, {headers:{'Content-Type':url.endsWith('.wasm')?'application/wasm':'application/octet-stream'}});
    };
    const pyodide = await loadPyodide({indexURL:assetRoot, createPyodideModule,
      lockFileContents: request.lockfile, packages:[], enableRunUntilComplete:false,
      env:{HOME:'/workspace'}, jsglobals:Object.freeze({}),
      stdout: text => nativePost({type:'output',stream:'stdout',text:text+'\n'}),
      stderr: text => nativePost({type:'output',stream:'stderr',text:text+'\n'})});
    const fs = pyodide.FS; runtimeFS = fs;
    fs.mkdirTree('/workspace');
    for (const directory of request.directories) fs.mkdirTree('/workspace/' + directory);
    for (const file of request.files) {
      fs.mkdirTree('/workspace/' + file.path.split('/').slice(0,-1).join('/'));
      fs.writeFile('/workspace/' + file.path, decode(file.data));
    }
    const cwd = '/workspace/' + (request.workingDirectory || '');
    fs.chdir(cwd);
    pyodide.registerJsModule('woven_native', {command: argumentsJSON => new Promise((resolve,reject) => {
      const id = String(++nextCall); waiting.set(id,{resolve,reject});
      nativePost({type:'cli',id,argumentsJSON});
    })});
    // Byte writes include partial lines and flushes, without waiting for a newline.
    const stream = name => { const decoder = new TextDecoder(); return {write: bytes => {
      const text = decoder.decode(bytes,{stream:true}); if (text) nativePost({type:'output',stream:name,text});
      return bytes.length;
    }}; };
    pyodide.setStdout(stream('stdout')); pyodide.setStderr(stream('stderr'));
    fs.writeFile('/woven_commands.py',request.commands);
    pyodide.globals.set('_woven_argv_json',JSON.stringify(request.argv));
    pyodide.globals.set('_woven_stdin',request.stdin || '');
    nativePost({type:'ready'});
    const exitCode = await pyodide.runPythonAsync(`import sys, json\nsys.path.insert(0, '/')\nfrom woven_commands import execute\nawait execute(json.loads(_woven_argv_json), _woven_stdin)`);
    if (waiting.size) throw new Error('Await all native CLI calls before returning.');
    // Export regular files only. Symlinks could redirect subsequent native writes.
    const files = [], directories = []; let total = 0;
    const walk = path => {
      for (const name of fs.readdir(path)) {
        if (name==='.' || name==='..') continue;
        const child = path + '/' + name, relative = child.slice('/workspace/'.length), stat = fs.lstat(child);
        if (directories.length + files.length >= request.maxFiles) throw new Error('Workspace contains too many entries.');
        if (fs.isLink(stat.mode)) throw new Error('Workspace symbolic links are not supported: ' + relative);
        if (fs.isDir(stat.mode)) { directories.push(relative); walk(child); }
        else if (fs.isFile(stat.mode)) {
          total += stat.size;
          if (total > request.maxWorkspaceBytes || files.length >= request.maxFiles) throw new Error('Workspace exceeds configured resource budget.');
          files.push({path:relative,data:encode(fs.readFile(child))});
        } else throw new Error('Unsupported workspace entry: ' + relative);
      }
    };
    walk('/workspace');
    nativePost({type:'done',exitCode,files,directories});
  } catch(error) { nativePost({type:'failure',message:String(error?.stack || error)}); }
};
