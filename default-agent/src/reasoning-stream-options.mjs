const responsesAPIs = new Set(['openai-codex-responses', 'openai-responses', 'azure-openai-responses']);

// Pi's streamSimple drops reasoningSummary, so request visible summaries at the
// actual Responses payload boundary. Preserve native continuation transforms.
export function withReasoningSummaries(model, options) {
  if (!model.reasoning || !responsesAPIs.has(model.api) || !options?.reasoning || options.reasoning === 'off') return options;
  const prior = options.onPayload;
  return { ...options, async onPayload(payload, requestedModel) {
    const changed = await prior?.(payload, requestedModel);
    const body = changed === undefined ? payload : changed;
    const effort = body?.reasoning?.effort;
    if (!effort || effort === 'none' || effort === 'off') return body;
    return { ...body, reasoning: { ...body.reasoning, summary: 'detailed' } };
  } };
}
