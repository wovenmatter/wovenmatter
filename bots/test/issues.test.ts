import type { AssistantMessage } from "@earendil-works/pi-ai";
import { describe, expect, it } from "vitest";
import { errorIssue } from "../src/issues.ts";
import { displayEntry } from "../src/transcript.ts";

const failed = (errorMessage: string, extra: Record<string, unknown> = {}) =>
  ({ role: "assistant", content: [], stopReason: "error", errorMessage, ...extra }) as unknown as AssistantMessage;

describe("errorIssue", () => {
  it.each([
    ["Not logged in to Claude.", "signIn"],
    ["401 Unauthorized", "signIn"],
    ["Incorrect API key provided", "signIn"],
    ["No API key for provider openai", "signIn"],
    ["You have exceeded your monthly credit balance", "limit"],
    ["The model is overloaded", undefined],
  ])("%j -> %s", (text, issue) => {
    expect(errorIssue(failed(text))).toBe(issue);
  });

  it("prefers what the provider attached, and ignores successful replies", () => {
    expect(errorIssue(failed("anything", { pibotIssue: "signIn" }))).toBe("signIn");
    expect(errorIssue(failed("anything", { pibotLimit: { kind: "credits" } }))).toBe("limit");
    expect(errorIssue({ stopReason: "stop", errorMessage: "401" } as AssistantMessage)).toBeUndefined();
  });

  it("puts the issue on the chat entry", () => {
    const entry = {
      id: 3,
      conversationId: 1,
      model: [failed("Not logged in to Claude.")],
    } as unknown as Parameters<typeof displayEntry>[0];
    expect(displayEntry(entry)).toMatchObject({
      error: "Not logged in to Claude.",
      issue: "signIn",
    });
  });
});
