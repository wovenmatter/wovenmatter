import { randomUUID } from 'node:crypto'
const fail = message => Object.assign(new Error(message), {statusCode:409})
const now = () => (Date.now()/1000)-978307200 // Swift Codable Date
export const goalGuidance = '\n<wovenmatter-goals>\nWhen the user explicitly requests a goal, use `woven_goals_set` with objective and a stable requestID. Read `woven_goals_get`. Report verified completion with complete, useful unfinished progress with checkpoint, and blockers with block; supply id, evidence and a stable requestID. Never complete because a turn or budget ended. Set, pause, resume and clear only when requested. Do not start a provider-native goal loop.\n</wovenmatter-goals>'
export const goalPrompt = goal => `Continue the Woven Matter goal in this conversation:\n${goal.objective}\n\nGoal ID: ${goal.id}\nRead woven_goals_get. Respect new user instructions and existing permissions. Before ending, call woven_goals_complete with id ${goal.id}, evidence describing verification results, and a stable requestID if achieved; otherwise checkpoint with evidence of useful progress and the next step, or block with the blocker. Never mark complete because a turn or budget ended. Pause, resume, clear and set only when requested.`
// Dates use the same reference epoch as Swift Codable Date.
export function setGoalStatus(goal, status, at = now()) {
  if (goal.status === status) return
  if (goal.status === 'active' && goal.activeSince != null) {
    goal.activeSeconds = (goal.activeSeconds ?? 0) + Math.max(0, at - goal.activeSince)
  }
  if (status === 'active') {
    goal.activeSeconds ??= 0
    goal.activeSince = at
  } else delete goal.activeSince
  goal.status = status
}
export function validateGoal(objective,tokens,turns) {
  if(typeof objective!=='string'||!objective.trim()||objective.includes('\0')||Buffer.byteLength(objective)>16384)throw fail('A goal needs an objective of at most 16 KiB.')
  for(const [value,max] of [[tokens,1e9],[turns,10000]])if(value!=null&&(!Number.isSafeInteger(value)||value<1||value>max))throw fail('Goal budgets must be positive whole numbers within the supported limits.')
}
export function mutateGoal(record,mutation,currentRunID) {
  const entries=Object.entries(mutation??{})
  if(entries.length!==1)throw fail('Invalid goal change.')
  const [action,options]=entries[0],old=record.goal
  if(action==='set') {
    validateGoal(options.objective,options.tokenBudget,options.turnBudget)
    if(old&&old.status!=='complete')throw fail('Clear or edit the existing goal first.')
    record.goal={id:randomUUID(),sessionID:record.conversation.id,objective:options.objective,status:'active',...(options.tokenBudget!=null?{tokenBudget:options.tokenBudget}:{}),...(options.turnBudget!=null?{turnBudget:options.turnBudget}:{}),completedTurns:0,activeSeconds:0,activeSince:now(),createdAt:now(),updatedAt:now(),baselineRunSequence:0,observedRunSequence:0,enrolledRunSequence:0,progressRevision:0,pendingProgressRevision:0}
    record.goalBaseCompletedTurns=0;record.goalBaseTokensUsed=0;record.goalRuns={};if(currentRunID)record.goalRuns[currentRunID]={settled:false}
    return
  }
  if(!old||options.id!==old.id)throw fail('This goal has changed. Refresh before updating it.')
  if(action==='edit') {
    validateGoal(options.objective,options.tokenBudget,options.turnBudget)
    record.goal={...old,id:randomUUID(),objective:options.objective,tokenBudget:options.tokenBudget??null,turnBudget:options.turnBudget??null}
    setGoalStatus(record.goal,'paused')
  } else if(action==='pause'){if(old.status==='complete')throw fail('Set a new goal after completion.');setGoalStatus(old,'paused')}
  else if(action==='resume') {
    if(old.status==='complete')throw fail('Set a new goal after completion.')
    if(old.status!=='active') {
      if(old.tokenBudget!=null&&goalUsageUnavailable(record,currentRunID))throw fail('Token usage is unavailable; remove the token budget before resuming.')
      if(budgetReached(old))throw fail('Increase or remove the budget before resuming.')
      setGoalStatus(old,'active');delete old.evidence;delete old.pendingDeliveryID;old.pendingProgressRevision=old.progressRevision-1
      if(currentRunID)(record.goalRuns??={})[currentRunID]??={settled:false}
    }
  } else if(action==='clear'){delete record.goal;return}
  else if(['complete','block','checkpoint'].includes(action)) {
    if(old.status!=='active')throw fail('Only active goals can report progress.')
    if(typeof options.evidence!=='string'||!options.evidence.trim()||Buffer.byteLength(options.evidence)>4096)throw fail('Provide evidence of at most 4 KiB.')
    const changed=old.evidence!==options.evidence.trim();old.evidence=options.evidence.trim()
    if(action==='checkpoint'){if(changed)old.progressRevision++}
    else setGoalStatus(old,action==='complete'?'complete':'blocked')
  } else throw fail('Unsupported goal operation.')
  if(record.goal.status!=='active')delete record.goal.pendingDeliveryID
  record.goal.updatedAt=now()
}
export function settleGoal(record,runID,succeeded,tokens) {
  const run=record.goalRuns?.[runID],goal=record.goal
  if(!goal||!run||run.settled)return
  run.settled=true;run.succeeded=succeeded;if(Number.isSafeInteger(tokens)&&tokens>=0)run.tokens=tokens
  const runs=Object.values(record.goalRuns).filter(item=>item.settled)
  goal.completedTurns=(record.goalBaseCompletedTurns??0)+runs.filter(item=>item.succeeded).length
  if(runs.every(item=>item.tokens!=null)&&((record.goalBaseCompletedTurns??0)===0||record.goalBaseTokensUsed!=null))goal.tokensUsed=(record.goalBaseTokensUsed??0)+runs.reduce((sum,item)=>sum+item.tokens,0)
  else delete goal.tokensUsed
  if(goal.status!=='active')return
  if(!succeeded){setGoalStatus(goal,'blocked');goal.evidence='The run was interrupted or failed. Review saved state before resuming.'}
  else if(goal.tokenBudget!=null&&goal.tokensUsed==null){setGoalStatus(goal,'blocked');goal.evidence='Token usage is unavailable; the token budget cannot be enforced.'}
  else if(budgetReached(goal))setGoalStatus(goal,'budget_limited')
  else if(goal.progressRevision<=goal.pendingProgressRevision){setGoalStatus(goal,'blocked');goal.evidence='The turn ended without a goal checkpoint. Review progress before resuming.'}
  goal.updatedAt=now()
}
export const goalUsageUnavailable = (record,currentRunID) =>
  ((record.goalBaseCompletedTurns??0)>0&&record.goalBaseTokensUsed==null)
  || Object.entries(record.goalRuns??{}).some(([id,run])=>id!==currentRunID&&run.tokens==null)
export const budgetReached = goal => (goal.turnBudget!=null&&goal.completedTurns>=goal.turnBudget)||(goal.tokenBudget!=null&&(goal.tokensUsed??0)>=goal.tokenBudget)
