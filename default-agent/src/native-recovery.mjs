import { DefaultAgentError } from './config.mjs';

// Input identities must come from persisted, run-scoped native submissions.
// Missing evidence never becomes a successful (or replayed) run.
export function validateRecoveryRuns(runs) {
  const validID = value => typeof value === 'string' && value.length > 0 && value.length <= 200;
  if (!Array.isArray(runs) || runs.length > 100 || runs.some(run => !validID(run?.runID)
    || !Array.isArray(run.inputIDs) || !run.inputIDs.length || run.inputIDs.length > 100
    || !run.inputIDs.every(validID)) || new Set(runs.map(run => run.runID)).size !== runs.length) {
    throw new DefaultAgentError('Invalid native recovery request.');
  }
  const owners = new Map();
  for (const run of runs) for (const inputID of run.inputIDs) {
    if (owners.has(inputID) && owners.get(inputID) !== run.runID) throw new DefaultAgentError('Ambiguous native recovery input.');
    owners.set(inputID, run.runID);
  }
}

export async function recoverNativeRuns(runs, requests, conversationID, tx) {
  validateRecoveryRuns(runs);
  const recovered = [];
  for (const run of runs) {
    const answers = new Map();
    let provable = true, failed = false;
    for (const inputID of new Set(run.inputIDs)) {
      const ids = requests?.[inputID]?.nativeRequestIDs;
      if (!Array.isArray(ids) || !ids.length) { provable = false; break; }
      let final;
      for (const requestID of ids) {
        const submission = await tx.submissionByRequest(conversationID, requestID);
        if (!submission || submission.conversationId !== conversationID || submission.requestId !== requestID
          || submission.type !== 'input' || !['done', 'unanswered'].includes(submission.status)) {
          provable = false; break;
        }
        final = submission;
      }
      if (!provable) break;
      if (final.status === 'unanswered') { failed = true; continue; }
      const entry = await tx.entry(final.answer);
      if (!entry || entry.conversationId !== conversationID || !entry.model?.some(message => message.role === 'assistant')) {
        provable = false; break;
      }
      answers.set(entry.id, entry);
    }
    if (!provable) continue;
    // The app reconciles only the latest assistant segment of this run.
    const answer = [...answers.values()].sort((a, b) => a.id - b.id).at(-1);
    const content = (answer?.model ?? []).filter(message => message.role === 'assistant')
      .flatMap(message => (message.content ?? []).filter(block => block.type === 'text').map(block => block.text)).join('\n');
    recovered.push({ runID: run.runID, content, ...(failed ? { error: 'The native run ended without a completed answer.' } : {}) });
  }
  return recovered;
}
