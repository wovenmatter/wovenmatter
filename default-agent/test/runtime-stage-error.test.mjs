import test from 'node:test';
import { SdkHttpError, SdkErrorCode } from '@modelcontextprotocol/client';
import assert from 'node:assert/strict';
import { DefaultAgentError, operationErrorMessage } from '../src/config.mjs';
import { runtimeStageError } from '../src/runtime-stage-error.mjs';

test('native preparation reports fixed stages without leaking arbitrary diagnostics',()=>{
  for(const stage of ['nativeSession','nativeStorage','nativeHarness','mcpDiscovery','mcpInstallation','runPreparation','secret-stage','__proto__']) {
    const error=runtimeStageError(stage,new Error('secret-token https://private.invalid/provider response body'));
    assert.ok(error instanceof DefaultAgentError);
    assert.equal(operationErrorMessage(error).includes('secret'),false);
    assert.equal(operationErrorMessage(error).includes('private.invalid'),false);
    assert.equal(operationErrorMessage(error).includes('response body'),false);
  }
  const safe=new DefaultAgentError('The native owner is busy.');
  assert.equal(runtimeStageError('nativeStorage',safe),safe);
});

test('MCP discovery exposes only allowlisted status and connection diagnostics',()=>{
  for(const status of [401,403,404,429,503]) {
    const error=runtimeStageError('mcpDiscovery',new Error(`Error POSTing to endpoint (HTTP ${status}): secret-body token=private`));
    assert.ok(error.message.includes(`HTTP ${status}`));assert.equal(error.message.includes('secret'),false);
  }
  assert.equal(runtimeStageError('mcpDiscovery',new Error('Error POSTing to endpoint (HTTP 999): secret')).message.includes('999'),false);
  const nativeHTTP=runtimeStageError('mcpDiscovery',new SdkHttpError(SdkErrorCode.ClientHttpNotImplemented,'secret response',{status:401,text:'secret',statusText:'private'}));
  assert.ok(nativeHTTP.message.includes('HTTP 401'));assert.equal(nativeHTTP.message.includes('secret'),false);
  assert.equal(runtimeStageError('mcpDiscovery',{code:'__proto__'}).message,'Pi Durable could not discover Woven Matter tools for this conversation.');
  const disconnected=runtimeStageError('mcpDiscovery',new Error('secret',{cause:{code:'ECONNREFUSED',url:'private'}}));
  assert.ok(disconnected.message.includes('refused'));assert.equal(disconnected.message.includes('private'),false);
});
