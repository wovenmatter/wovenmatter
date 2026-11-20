import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { FIXTURES, wireJSON } from "./wire-fixtures.ts";

describe("wire fixtures", () => {
  it("match what test/wire-fixtures.ts writes (run it after changing protocol.ts)", () => {
    expect(readFileSync(FIXTURES, "utf8")).toBe(wireJSON());
  });
});
