// The levels alone, with no SDK import: the CLI loads them through its config before it switches
// to Pi Durable's SDK copy (pi-durable-sdk.ts), and the packaged bots have no SDK of their own.

/** Reasoning levels bots run at. There is no "off": every bot request reasons. */
export const REASONING = ["minimal", "low", "medium", "high", "xhigh", "max"] as const;
export type Reasoning = (typeof REASONING)[number];

/** A profile's main-model level until the user picks another. */
export const DEFAULT_REASONING: Reasoning = "high";

export const isReasoning = (value: unknown): value is Reasoning =>
  (REASONING as readonly unknown[]).includes(value);
