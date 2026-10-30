import { createHash, randomBytes, createCipheriv, createDecipheriv, randomUUID } from 'node:crypto'

const fail = (statusCode, message) => Object.assign(new Error(message), { statusCode })
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value)
const hash = value => createHash('sha256').update(value).digest('hex')
const sameArtifact = (a,b) => ['id','workspaceID','title','mediaType','byteCount','sha256','deleted'].every(key=>a[key]===b[key])

// This is an origin outbox, not a client relay. Its only source is the service's
// own SQLite journal. Publication failures never control agent execution.
export function createClientExecutionPublisher({ db, identity, secret, events, flush = () => {}, fetchImpl = globalThis.fetch, intervalMilliseconds = 5000 }) {
  db.exec(`CREATE TABLE IF NOT EXISTS central_publication (id INTEGER PRIMARY KEY CHECK(id=1), envelope TEXT NOT NULL, acknowledged INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS retained_publication_receipts (event_id TEXT PRIMARY KEY);
    CREATE TABLE IF NOT EXISTS central_publication_lanes (name TEXT PRIMARY KEY, failures INTEGER NOT NULL DEFAULT 0, next_attempt INTEGER NOT NULL DEFAULT 0, last_success TEXT, last_error_code TEXT);
    INSERT OR IGNORE INTO central_publication_lanes(name) VALUES ('journal'),('artifacts');
    CREATE TABLE IF NOT EXISTS saved_execution_artifacts (id TEXT PRIMARY KEY, manifest TEXT NOT NULL, bytes BLOB NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0);`)
  const key = typeof secret === 'string' && secret.length >= 16 ? createHash('sha256').update('wovenmatter-workspace-publisher-v1\0'+secret).digest() : null
  let inFlight, stopped = false, timer
  const controllers = new Set()
  const retryBase = intervalMilliseconds > 0 ? intervalMilliseconds : 5000
  const retryMaximum = 300000
  const laneRow = name => db.prepare('SELECT * FROM central_publication_lanes WHERE name=?').get(name)
  function grant() {
    const row = db.prepare('SELECT envelope FROM central_publication WHERE id=1').get()
    if (!row || !key) return null
    try {
      const saved = JSON.parse(row.envelope), own = identity()
      const decipher = createDecipheriv('aes-256-gcm',key,Buffer.from(saved.iv,'base64'))
      decipher.setAAD(Buffer.from(JSON.stringify([own.libraryID,own.id,own.executionDeviceID])))
      decipher.setAuthTag(Buffer.from(saved.tag,'base64'))
      return JSON.parse(Buffer.concat([decipher.update(Buffer.from(saved.ciphertext,'base64')),decipher.final()]).toString('utf8'))
    } catch { return null }
  }
  function configure(value) {
    const own = identity()
    let endpoint
    try { endpoint = new URL(value.endpoint) } catch { throw fail(400,'Invalid central publisher endpoint.') }
    if (!key || !uuid(value.grantID) || value.libraryID !== own.libraryID || value.workspaceID !== own.id || value.executionDeviceID !== own.executionDeviceID
      || typeof value.token !== 'string' || value.token.length < 32 || value.token.length > 256 || endpoint.protocol !== 'https:' || !endpoint.hostname.endsWith('.ts.net')
      || endpoint.username || endpoint.password || endpoint.search || endpoint.hash) throw fail(400,'The publisher must match this execution owner and its private central endpoint.')
    const iv = randomBytes(12), cipher = createCipheriv('aes-256-gcm',key,iv)
    cipher.setAAD(Buffer.from(JSON.stringify([own.libraryID,own.id,own.executionDeviceID])))
    const ciphertext = Buffer.concat([cipher.update(JSON.stringify(value),'utf8'),cipher.final()])
    const envelope = JSON.stringify({iv:iv.toString('base64'),ciphertext:ciphertext.toString('base64'),tag:cipher.getAuthTag().toString('base64')})
    db.prepare('INSERT INTO central_publication(id,envelope) VALUES (1,?) ON CONFLICT(id) DO UPDATE SET envelope=excluded.envelope').run(envelope)
    db.prepare('UPDATE central_publication_lanes SET failures=0,next_attempt=0,last_error_code=NULL').run()
    schedule(0)
    return status()
  }
  function status() {
    const value = grant(), row = db.prepare('SELECT acknowledged FROM central_publication WHERE id=1').get()
    const lane = name => { const item=laneRow(name);return {failureCount:item.failures,nextAttemptAt:item.next_attempt,
      ...(item.last_success?{lastSuccessAt:item.last_success}:{}),...(item.last_error_code?{lastErrorCode:item.last_error_code}:{})} }
    return {configured:!!value,...(value?{grantID:value.grantID}:{}),acknowledgedOriginSequence:row?.acknowledged??0,
      pendingArtifacts:db.prepare('SELECT count(*) AS count FROM saved_execution_artifacts WHERE uploaded=0').get().count,
      journal:lane('journal'),artifacts:lane('artifacts')}
  }
  async function post(value, path, body) {
    if (stopped) throw fail(503,'The workspace publisher is stopped.')
    const controller = new AbortController();controllers.add(controller)
    const timeout = setTimeout(()=>controller.abort(),10000); timeout.unref()
    try {
      const response = await fetchImpl(value.endpoint.replace(/\/$/,'')+'/v1/federation/publisher/'+path, {
        method:'POST',redirect:'error',signal:controller.signal,
        headers:{authorization:'Bearer '+value.token,'content-type':'application/json','x-woven-protocol':'3','x-woven-workspace':value.libraryID},body:JSON.stringify(body)})
      if (!response.ok) throw fail(response.status,'The central library did not accept this workspace publication.')
      return await response.json()
    } finally { clearTimeout(timeout); controllers.delete(controller) }
  }
  async function settleRetainedRuns(value) {
    let sent=false
    for(;;) {
      const rows=db.prepare(`SELECT body FROM events WHERE json_extract(body,'$.retainedExecution') IS NOT NULL
        AND json_extract(body,'$.eventID') NOT IN (SELECT event_id FROM retained_publication_receipts) ORDER BY sequence LIMIT 100`).all()
      const entries=[];let bytes=0
      for(const row of rows) {const size=Buffer.byteLength(row.body);if(entries.length&&bytes+size>4*1024*1024)break;entries.push(JSON.parse(row.body));bytes+=size}
      if(!entries.length)return sent
      const result=await post(value,'retained/settle',{libraryID:value.libraryID,entries})
      const ids=entries.map(entry=>entry.eventID)
      if(result.libraryID!==value.libraryID||!Array.isArray(result.acceptedEventIDs)||result.acceptedEventIDs.length!==ids.length
        ||new Set(result.acceptedEventIDs).size!==ids.length||!ids.every(id=>result.acceptedEventIDs.includes(id)))throw fail(409,'The central library returned an incomplete retained-run receipt.')
      if(stopped)return sent
      for(const id of ids)db.prepare('INSERT OR IGNORE INTO retained_publication_receipts VALUES (?)').run(id)
      sent=true
    }
  }
  async function publishJournal(value) {
    flush()
    let sent = await settleRetainedRuns(value)
    let acknowledged = db.prepare('SELECT acknowledged FROM central_publication WHERE id=1').get().acknowledged
    for (;;) {
      const page = events(acknowledged)
      if (!page.entries.length) break
      if (page.entries.some(entry=>entry.workspaceID!==value.workspaceID)) throw fail(409,'Foreign workspace records cannot enter this publisher.')
      const result = await post(value,'journal',{libraryID:value.libraryID,entries:page.entries})
      sent = true
      const ids = page.entries.map(entry=>entry.eventID)
      if (result.libraryID!==value.libraryID || !Array.isArray(result.acceptedEventIDs) || result.acceptedEventIDs.length!==ids.length
        || new Set(result.acceptedEventIDs).size!==ids.length || !ids.every(id=>result.acceptedEventIDs.includes(id))
        || !Number.isSafeInteger(result.cursor) || result.cursor<0) throw fail(409,'The central library returned an incomplete publication receipt.')
      if (stopped) return
      acknowledged = page.cursor
      // Only this exact accepted origin batch advances the durable origin cursor.
      db.prepare('UPDATE central_publication SET acknowledged=max(acknowledged,?) WHERE id=1').run(acknowledged)
      if (!page.hasMore) break
    }
    return sent
  }
  async function publishArtifacts(value) {
    let sent = false
    for (const row of db.prepare('SELECT id,manifest,bytes FROM saved_execution_artifacts WHERE uploaded=0 ORDER BY id').all()) {
      const manifest = JSON.parse(row.manifest), bytes = Buffer.from(row.bytes)
      let transfer = await post(value,'artifacts/register',{manifest})
      sent = true
      const check = () => { if (!sameArtifact(transfer.manifest,manifest) || !Number.isSafeInteger(transfer.manifest.revision) || transfer.manifest.revision<1
        || !Number.isSafeInteger(transfer.nextOffset) || transfer.nextOffset<0 || transfer.nextOffset>bytes.length || (transfer.complete && transfer.nextOffset!==bytes.length)) throw fail(409,'Invalid saved artifact receipt.') }
      check()
      while (!transfer.complete && transfer.nextOffset<bytes.length) {
        const offset=transfer.nextOffset, data=bytes.subarray(offset,offset+1048576)
        transfer=await post(value,'artifacts/chunk',{id:manifest.id,revision:transfer.manifest.revision,offset,data:data.toString('base64')});check()
        if(transfer.nextOffset!==offset+data.length)throw fail(409,'Saved artifact acknowledgement did not advance by its submitted bytes.')
      }
      const committed=transfer.complete?transfer.manifest:await post(value,'artifacts/commit',{id:manifest.id,revision:transfer.manifest.revision})
      if(!sameArtifact(committed,manifest)||committed.revision!==transfer.manifest.revision)throw fail(409,'Saved artifact commit did not match its source.')
      if(stopped)return
      db.prepare('UPDATE saved_execution_artifacts SET manifest=?,uploaded=1 WHERE id=?').run(JSON.stringify(committed),manifest.id)
    }
    return sent
  }
  async function runLane(name, operation, automatic) {
    const prior=laneRow(name)
    if(automatic && prior.next_attempt>Date.now())return
    try {
      const sent=await operation()
      if(stopped)return
      db.prepare('UPDATE central_publication_lanes SET failures=0,next_attempt=?,last_error_code=NULL,last_success=COALESCE(?,last_success) WHERE name=?')
        .run(Date.now()+retryBase,sent?new Date().toISOString():null,name)
    } catch(error) {
      if(!stopped) {
        const failures=Math.min(prior.failures+1,2147483647)
        const delay=Math.min(retryMaximum,retryBase*2**Math.min(failures-1,20))
        const code=Number.isInteger(error.statusCode)?'http_'+error.statusCode:'transport_failure'
        db.prepare('UPDATE central_publication_lanes SET failures=?,next_attempt=?,last_error_code=? WHERE name=?').run(failures,Date.now()+delay,code,name)
      }
      throw error
    }
  }
  async function publish(automatic) {
    const value=grant();if(!value||stopped)return
    const results=await Promise.allSettled([
      runLane('journal',()=>publishJournal(value),automatic),
      runLane('artifacts',()=>publishArtifacts(value),automatic)
    ])
    const failure=results.find(result=>result.status==='rejected')
    if(failure)throw failure.reason
  }
  function syncNow({automatic=false}={}) {
    if (inFlight) return inFlight
    inFlight=publish(automatic).finally(()=>{inFlight=undefined})
    return inFlight
  }
  function schedule(milliseconds) {
    if(stopped || intervalMilliseconds<=0)return
    clearTimeout(timer)
    const next=Math.min(laneRow('journal').next_attempt,laneRow('artifacts').next_attempt)
    const delay=milliseconds??(grant()?Math.max(1,next-Date.now()):intervalMilliseconds)
    timer=setTimeout(()=>{void syncNow({automatic:true}).catch(()=>{}).finally(()=>schedule())},delay);timer.unref()
  }
  function saveArtifact({id=randomUUID(),title,mediaType,data}) {
    const own=identity(), bytes=Buffer.from(data)
    if(!uuid(id)||typeof title!=='string'||!title||Buffer.byteLength(title)>4096||typeof mediaType!=='string'||!mediaType||mediaType.length>256||bytes.length>256*1024*1024)throw fail(400,'Invalid explicitly saved artifact.')
    const manifest={id,workspaceID:own.id,title,mediaType,byteCount:bytes.length,sha256:hash(bytes),revision:0,deleted:false}
    const old=db.prepare('SELECT manifest FROM saved_execution_artifacts WHERE id=?').get(id)
    if(old){const previous=JSON.parse(old.manifest);if(!sameArtifact(previous,manifest))throw fail(409,'Saved artifact ID was reused with different content.');return previous}
    const total=db.prepare('SELECT coalesce(sum(length(bytes)),0) AS bytes FROM saved_execution_artifacts').get().bytes
    if(total+bytes.length>1024*1024*1024)throw fail(413,'The saved artifact store is full.')
    db.prepare('INSERT INTO saved_execution_artifacts(id,manifest,bytes) VALUES (?,?,?)').run(id,JSON.stringify(manifest),bytes)
    schedule(0);return manifest
  }
  schedule(0)
  async function resolveRetainedAssociation(request) {
    const value=grant();if(!value||!uuid(request?.runID))return null
    try { return await post(value,'association',request) } catch(error) { if(error.statusCode===404)return null;throw error }
  }
  return {configure,status,syncNow,saveArtifact,resolveRetainedAssociation,async close(){stopped=true;clearTimeout(timer);for(const controller of controllers)controller.abort();await inFlight?.catch(()=>{})}}
}
