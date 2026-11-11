import type { AssistantMessage } from "@earendil-works/pi-ai";
import { classifyLimit, type LimitClass } from "./limits.ts";

/**
 * Why a reply failed, when the user can fix it: `signIn` (the model's provider is not signed in
 * or its key was refused: Settings → Subscriptions & API Keys) or `limit` (a usage limit or out of
 * credits: change the model, or the account, in Settings). Clients show the matching actions.
 */
export type ErrorIssue = "signIn" | "limit";

/** What a provider attached to a failed message (the Claude provider sets `signIn`). */
export type IssueCarrier = Pick<AssistantMessage, "stopReason" | "errorMessage"> & {
  pibotIssue?: ErrorIssue;
  pibotLimit?: LimitClass;
};

/** Provider wording for a missing or refused sign-in or key. */
const SIGN_IN =
  /not logged in|please run \/login|not signed in|authentication_failed|invalid (?:x-)?api[ _-]?key|incorrect api key|no api key|missing api key|api key (?:is )?(?:missing|required|not found)|unauthori[sz]ed|\b401\b|token (?:has )?expired|no credentials/i;

export function errorIssue(message: IssueCarrier): ErrorIssue | undefined {
  if (message.stopReason !== "error") return undefined;
  if (message.pibotIssue) return message.pibotIssue;
  const limit = classifyLimit(message);
  if (limit && limit.kind !== "rate") return "limit";
  return SIGN_IN.test(message.errorMessage ?? "") ? "signIn" : undefined;
}
