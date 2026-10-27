import { SdkHttpError, UnauthorizedError } from '@modelcontextprotocol/client';
import { DefaultAgentError } from './config.mjs';

const stages = {
  nativeSession: 'Pi Durable could not restore its native conversation.',
  nativeStorage: 'Pi Durable could not open its native conversation storage.',
  nativeHarness: 'Pi Durable could not initialize its native execution runtime.',
  mcpDiscovery: 'Pi Durable could not discover Woven Matter tools for this conversation.',
  mcpInstallation: 'Pi Durable could not install this conversation’s Woven Matter tool definitions.',
  runPreparation: 'Pi Durable could not prepare the native run group.',
};

// SDK errors may contain URLs, response bodies or credentials. Only fixed stage
// labels and a small set of transport codes may cross the UI boundary.
export function runtimeStageError(stage, error) {
  if (error instanceof DefaultAgentError) return error;
  let suffix = '';
  if (stage === 'mcpDiscovery') {
    const match = /^Error POSTing to endpoint \(HTTP (401|403|404|405|408|429|500|502|503|504)\):/.exec(String(error?.message ?? ''));
    const httpStatus = error instanceof SdkHttpError ? error.status : undefined;
    const status = [401,403,404,405,408,429,500,502,503,504].includes(httpStatus)
      ? String(httpStatus) : match?.[1] ?? (error instanceof UnauthorizedError ? '401' : undefined);
    if (status === '401' || status === '403') suffix = ` The workspace tool grant was rejected (HTTP ${status}).`;
    else if (status) suffix = ` The workspace tool service returned HTTP ${status}.`;
    else {
      const code = error?.code ?? error?.cause?.code;
      const diagnostics = {ECONNREFUSED:' The workspace tool service refused the connection.',
        ECONNRESET:' The workspace tool connection was reset.',
        ETIMEDOUT:' The workspace tool connection timed out.',
        UND_ERR_CONNECT_TIMEOUT:' The workspace tool connection timed out.'};
      suffix = Object.hasOwn(diagnostics, code) ? diagnostics[code] : '';
    }
  }
  return new DefaultAgentError((Object.hasOwn(stages, stage) ? stages[stage] : 'Pi Durable could not prepare this operation.') + suffix);
}
