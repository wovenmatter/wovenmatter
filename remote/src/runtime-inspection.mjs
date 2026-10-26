import { execFile } from 'node:child_process'
import { basename } from 'node:path'
import { promisify } from 'node:util'

const execute = promisify(execFile)

// Collect executable names and resource counters only; never command arguments
// or environments. Attribute only descendants of this service's known owners.
export async function inspectProcesses(items) {
  try {
    const {stdout} = await execute('ps', ['-axo','pid=,ppid=,pcpu=,rss=,comm='], {
      timeout:2_000,maxBuffer:1024*1024,env:{PATH:'/usr/bin:/bin',LC_ALL:'C'},
    })
    return attachProcessSamples(items,stdout)
  } catch { return items }
}

export function attachProcessSamples(items, text) {
  const samples = text.split('\n').flatMap(line => {
    const match = line.trim().match(/^(\d+)\s+(\d+)\s+([\d.]+)\s+(\d+)\s+(.+)$/)
    return match ? [{pid:Number(match[1]),parent:Number(match[2]),cpu:Number(match[3]),
      bytes:Number(match[4])*1024,name:basename(match[5])}] : []
  })
  const owners = new Map(items.filter(item=>item.processID).map(item=>[item.processID,item]))
  const result = [...items]
  for(let depth=0;depth<16 && result.length<1000;depth++) {
    let added=false
    for(const sample of samples) {
      if(owners.has(sample.pid) || sample.name==='ps') continue
      const parent=owners.get(sample.parent)
      if(!parent) continue
      const item={id:`process:${sample.pid}`,parentID:parent.id,kind:'process',title:sample.name,
        state:'running',processID:sample.pid,nativeSessionID:parent.nativeSessionID}
      owners.set(sample.pid,item); result.push(item); added=true
      if(result.length>=1000) break
    }
    if(!added) break
  }
  const byPID=new Map(samples.map(sample=>[sample.pid,sample]))
  return result.map(item=>{
    const sample=byPID.get(item.processID)
    return sample ? {...item,cpuPercent:sample.cpu,residentBytes:sample.bytes} : item
  })
}
