// Connections requests the device flow explicitly so the link and code are
// presented beneath the account that initiated sign-in.
export function preferredSignInAnswer(provider, prompt) {
  if (provider === 'openai-codex' && prompt.options?.some(option => option.id === 'device_code')) return 'device_code';
  return undefined;
}
