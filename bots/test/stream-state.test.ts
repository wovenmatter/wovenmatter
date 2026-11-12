import { describe, expect, it } from "vitest";
import { streamEvents } from "../src/server.ts";

const view = (text: string, taskId = 1, attempt = 1) => ({
  entries: [],
  docs: {
    "pi.live": {
      run: { taskId, inputs: [], turns: 0 },
      generation: {
        attempt,
        message: { role: "assistant", content: [{ type: "text", text }] },
      },
    },
  },
});

describe("conversation state streaming", () => {
  it("settles a coalesced run even when the busy revision was not delivered", () => {
    expect(streamEvents({ entries: [], docs: {} }, { entries: [], docs: {} })).toEqual([
      { kind: "run", state: "end" },
    ]);
  });
  it("appends partials only within the same generation", () => {
    expect(streamEvents(view("hello"), view("hello world"))).toEqual([
      { kind: "delta", text: " world" },
    ]);
    expect(streamEvents(view("hello"), view("hello world", 2))).toEqual([
      { kind: "assistant_start", text: "hello world" },
    ]);
    expect(streamEvents(view("hello"), view("hello", 1, 2))).toEqual([
      { kind: "assistant_start", text: "hello" },
    ]);
  });
  it("replaces rewritten partials instead of appending them", () => {
    expect(streamEvents(view("old"), view("new"))).toEqual([
      { kind: "assistant_start", text: "new" },
    ]);
  });
});
