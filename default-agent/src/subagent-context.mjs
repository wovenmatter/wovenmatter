import { isAbsolute, join } from 'node:path';
import { DefaultAgentError } from './config.mjs';
import { nativeContextBridge } from './native-context.mjs';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// The native child shares only its owner's store and archive writer. Provider
// context, SDK disk scope, input authority and mutable execution state belong
// to this child conversation, never to the parent currently generating a turn.
export function createSubagentContext(parent, engine, {
  conversation, sessionID, providerSessionID, model, accountID, thinkingLevel,
  runID, cli, appendArchive, reportUsage,
}, background) {
  if (!Number.isSafeInteger(conversation?.id) || conversation.id < 1 || !uuid.test(sessionID ?? '')
      || !isAbsolute(parent.nativeRoot ?? '') || !model?.provider || !model.id || !accountID
      || providerSessionID !== undefined && !uuid.test(providerSessionID)) {
    throw new DefaultAgentError('Invalid native subagent scope.');
  }
  const child = {
    harness: parent.harness, storage: parent.storage, registry: parent.registry,
    manifest: parent.manifest, cwd: parent.cwd, conversation,
    nativeRoot: join(parent.nativeRoot, 'native-children', String(conversation.id)),
    parentSessionID: parent.manifest.sessionID,
    providerSessionID: providerSessionID ?? sessionID,
    cli: cli ?? parent.cli.fork(), busy: true,
    selected: `${model.provider}/${model.id}`, accountID,
    permission: parent.permission,
    ordinaryTools: [...parent.ordinaryTools],
    codeModeState: { value: parent.codeModeState.value },
    options: { selected: `${model.provider}/${model.id}`, thinking: thinkingLevel, permission: parent.permission },
    session: { sessionId: sessionID, model, thinkingLevel, messages: [] },
    nativePrepared: undefined, nativeContextFailure: undefined,
    nativeVisible: false, httpAccessFailure: undefined, lastError: undefined,
    pendingStoreWrites: [],
    reportUsage: reportUsage ?? parent.reportUsage,
  };
  Object.defineProperties(child, {
    // The originating Woven run stays fixed even while the parent consumes a
    // later input. All exposed child content belongs to this attached group.
    runID: { enumerable: true, value: runID },
    archiveQueue: { get: () => parent.archiveQueue },
    archiveError: { get: () => parent.archiveError },
  });
  child.appendArchive = records => (appendArchive ?? parent.appendArchive)(records.map(record => ({
    ...record, ...(runID ? { runID } : {}),
  })));
  child.nativeBridge = nativeContextBridge(child, engine, background);
  return child;
}
