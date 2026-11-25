import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { expect, it } from "vitest";

// Packaged bots carry no SDK of their own: the CLI switches to Pi Durable's copy after reading its
// config, so config.ts and what it imports stay SDK-free (types only).
it("starts the CLI without importing the SDK before it switches to Pi Durable's copy", () => {
  const refuseSDK = `import { registerHooks } from "node:module";
registerHooks({ resolve(specifier, context, next) {
  if (/^@(earendil-works|anthropic-ai)\\//.test(specifier)) throw new Error("SDK imported early: " + specifier);
  return next(specifier, context);
} });`;
  const cli = fileURLToPath(new URL("../src/cli.ts", import.meta.url));
  const output = execFileSync(
    process.execPath,
    ["--import", `data:text/javascript,${encodeURIComponent(refuseSDK)}`, cli, "--help"],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
  );
  expect(output).toMatch(/^Usage: /);
});
