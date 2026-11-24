import { type Api, getSupportedThinkingLevels, type Model } from "@earendil-works/pi-ai";

/** Reasoning levels bots run at. There is no "off": every bot request reasons. */
export const REASONING = ["minimal", "low", "medium", "high", "xhigh", "max"] as const;
export type Reasoning = (typeof REASONING)[number];

/** A profile's main-model level until the user picks another. */
export const DEFAULT_REASONING: Reasoning = "high";

export const isReasoning = (value: unknown): value is Reasoning =>
  (REASONING as readonly unknown[]).includes(value);

/**
 * The level to run `model` at for `wanted`: `wanted` when the model supports it, else the nearest
 * lower level it supports, else the nearest higher one. Undefined for a model without reasoning
 * levels. A model the catalog does not know keeps `wanted` until a catalog refresh re-applies
 * profiles.
 */
export function reasoningFor(model: Model<Api> | undefined, wanted: Reasoning): Reasoning | undefined {
  if (!model) return wanted;
  const supported = getSupportedThinkingLevels(model).filter(isReasoning);
  if (supported.includes(wanted)) return wanted;
  const index = REASONING.indexOf(wanted);
  const lower = REASONING.slice(0, index).reverse().find((level) => supported.includes(level));
  return lower ?? REASONING.slice(index + 1).find((level) => supported.includes(level));
}
