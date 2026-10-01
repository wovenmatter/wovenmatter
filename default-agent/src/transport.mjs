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
      const reader = response.clone().body?.getReader();
      try {
        const chunks = [];
        let remaining = 65536;
        while (reader && remaining > 0) {
          const { done, value } = await reader.read();
          if (done) break;
          const chunk = value.subarray(0, remaining);
          chunks.push(chunk);
          remaining -= chunk.length;
        }
        detail = Buffer.concat(chunks).toString('utf8');
      } catch { /* Status alone can still identify an authentication failure. */ }
      finally {
        // A cloned stream's cancellation can wait for the SDK's reader; do not
        // await it before handing the original response back to that reader.
        void reader?.cancel().catch(() => {});
      }
      record.httpAccessFailure = accessFailure(`${response.status} ${detail}`);
    }
    return response;
  };
}
