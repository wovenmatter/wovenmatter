import test from 'node:test'
import assert from 'node:assert/strict'
import {attachProcessSamples} from '../src/runtime-inspection.mjs'

test('inspection attributes descendants, inherits chat binding, and excludes unrelated processes',()=>{
  const result=attachProcessSamples([
    {id:'server',kind:'service',processID:10},
    {id:'agent',kind:'runtime',processID:20,nativeSessionID:'native-chat'},
  ],'10 1 2.0 100 /usr/bin/node\n20 10 3.0 200 /usr/bin/pi\n30 20 4.0 300 /bin/bash\n40 30 0.5 400 /usr/bin/git\n50 1 9.0 500 /bin/unrelated\n60 10 0.1 20 /bin/ps')
  assert.equal(result.length,4)
  assert.equal(result.find(item=>item.processID===40).nativeSessionID,'native-chat')
  assert.equal(result.find(item=>item.processID===30).parentID,'agent')
  assert.equal(result.find(item=>item.processID===20).residentBytes,200*1024)
  assert.equal(result.find(item=>item.processID===20).cpuPercent,3)
  assert.equal(result.find(item=>item.processID===50),undefined)
})
