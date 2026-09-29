import { DefaultAgentError } from './config.mjs';

// Connections requests the device flow explicitly so the link and code are
// presented beneath the account that initiated sign-in.
export function preferredSignInAnswer(provider, prompt) {
  if (provider === 'openai-codex' && prompt.options?.some(option => option.id === 'device_code')) return 'device_code';
  return undefined;
}

export function createSignInPrompt({ provider, signal, pending, send }) {
  return value => {
    const preferred = preferredSignInAnswer(provider, value);
    if (preferred) return Promise.resolve(preferred);
    const inputSignal = value.signal ?? signal;
    return new Promise((resolve, reject) => {
      const id = crypto.randomUUID();
      const abort = () => { pending.delete(id); reject(new DefaultAgentError('Sign-in cancelled.')); };
      if (inputSignal.aborted) { abort(); return; }
      inputSignal.addEventListener('abort', abort, { once: true });
      pending.set(id, answer => {
        pending.delete(id);
        inputSignal.removeEventListener('abort', abort);
        resolve(answer);
      });
      send({ prompt: { ...value, signal: undefined }, id });
    });
  };
}
