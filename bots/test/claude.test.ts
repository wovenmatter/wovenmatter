import { chmod, mkdir, writeFile } from "node:fs/promises";
import { delimiter, join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { claudeExecutable } from "../src/claude/runtime.ts";
import { tempDir } from "./helpers.ts";

describe("the installed Claude Code", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  beforeEach(async () => {
    dir = await tempDir();
  });
  afterEach(async () => {
    await dir.cleanup();
  });

  it("is the first executable claude on PATH, or a clear error", async () => {
    const none = join(dir.path, "none");
    const plain = join(dir.path, "plain");
    const installed = join(dir.path, "installed");
    for (const folder of [none, plain, installed]) await mkdir(folder);
    await writeFile(join(plain, "claude"), "");
    await writeFile(join(installed, "claude"), "#!/bin/sh\n");
    await chmod(join(installed, "claude"), 0o755);
    expect(claudeExecutable([none, plain, installed].join(delimiter))).toBe(join(installed, "claude"));
    expect(() => claudeExecutable([none, plain].join(delimiter))).toThrow("Claude Code is not installed on this machine.");
  });
});
