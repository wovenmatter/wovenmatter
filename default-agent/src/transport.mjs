import { accessFailure } from './config.mjs';

// Codex SDK friendly messages collapse subscription exhaustion and transient 429s.
// Classify the original HTTP failure while leaving the body intact for the SDK.
// Keep only the safe reason, never a response body, header, or credential.
export function providerFetch(record, fetchRequest = fetch) {
  return async (...args) => {
    const response = await fetchRequest(...args);
    record.httpAccessFailure = undefined;
    if (!response.ok) {
      let detail = '';
      try { detail = (await response.clone().text()).slice(0, 65536); } catch { }
      record.httpAccessFailure = accessFailure(`${response.status} ${detail}`);
    }
    return response;
  };
}
