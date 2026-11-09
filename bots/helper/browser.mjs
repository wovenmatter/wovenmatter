// Woven bot browser: Chromium through Playwright with a persistent profile in the bot's storage,
// so cookies and sign-ins survive container stops. Open tabs are saved on every change and on
// shutdown, and reopened when the browser starts again. Controlled by the supervisor over IPC.
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { join } from "node:path";

const STATE = process.env.WOVEN_BROWSER_STATE ?? "/workspace/.woven/browser";
const PROFILE = join(STATE, "profile");
const TABS = join(STATE, "tabs.json");
const MAX_TEXT = 100_000;
const NAV_TIMEOUT = 45_000;
const ACTION_TIMEOUT = 15_000;

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.WOVEN_PLAYWRIGHT_MODULE ?? "playwright");

let context;
const ids = new WeakMap();
const pages = new Map(); // id → page
let nextId = 1;
let active;
let saveTimer;
// Once shutdown begins the tab list is final: closing pages must not overwrite it.
let closing = false;

function idOf(page) {
  let id = ids.get(page);
  if (!id) {
    id = nextId++;
    ids.set(page, id);
    pages.set(id, page);
    page.on("close", () => {
      pages.delete(id);
      if (active === id) active = [...pages.keys()].at(-1);
      scheduleSave();
    });
    page.on("framenavigated", (frame) => {
      if (frame === page.mainFrame()) scheduleSave();
    });
  }
  return id;
}

function scheduleSave() {
  if (closing) return;
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => void saveTabs(), 500);
}

async function saveTabs() {
  const tabs = [...pages.values()]
    .map((page) => page.url())
    .filter((url) => url && url !== "about:blank" && !url.startsWith("chrome-error:"));
  await mkdir(STATE, { recursive: true });
  await writeFile(`${TABS}.tmp`, JSON.stringify({ tabs, savedAt: new Date().toISOString() }));
  await rename(`${TABS}.tmp`, TABS);
}

async function describeTab(page) {
  return { tab: idOf(page), url: page.url(), title: await page.title().catch(() => ""), active: idOf(page) === active };
}

function pageFor(args) {
  const id = args.tab ?? active;
  const page = id === undefined ? undefined : pages.get(Number(id));
  if (!page) throw new Error(args.tab === undefined ? "no open tab; navigate to a URL first" : `no tab ${args.tab}`);
  active = idOf(page);
  return page;
}

function checkURL(value) {
  const url = new URL(String(value));
  if (!["http:", "https:", "about:", "file:"].includes(url.protocol)) throw new Error("use an http(s) URL");
  return url.href;
}

async function open(url) {
  const page = await context.newPage();
  active = idOf(page);
  if (url) await page.goto(url, { timeout: NAV_TIMEOUT, waitUntil: "domcontentloaded" }).catch(() => {});
  return page;
}

function locate(page, args) {
  if (args.selector) return page.locator(String(args.selector)).first();
  if (args.text) return page.getByText(String(args.text), { exact: false }).first();
  if (args.label) return page.getByLabel(String(args.label), { exact: false }).first();
  throw new Error("give a selector, text or label");
}

const methods = {
  async ping() {
    return { ok: true, tabs: pages.size };
  },
  async tabs() {
    return Promise.all([...pages.values()].map(describeTab));
  },
  async new_tab(args) {
    const page = await open(args.url ? checkURL(args.url) : undefined);
    return describeTab(page);
  },
  async navigate(args) {
    const url = checkURL(args.url);
    const page = args.tab === undefined && active === undefined ? await open() : pageFor(args);
    const response = await page.goto(url, { timeout: NAV_TIMEOUT, waitUntil: "domcontentloaded" });
    await page.waitForLoadState("load", { timeout: 10_000 }).catch(() => {});
    return { ...(await describeTab(page)), status: response?.status() };
  },
  async read(args) {
    const page = pageFor(args);
    const text = await page.evaluate(() => document.body?.innerText ?? "");
    const max = Math.min(Number(args.maxChars) || 20_000, MAX_TEXT);
    return { ...(await describeTab(page)), text: text.length > max ? `${text.slice(0, max)}…` : text, truncated: text.length > max };
  },
  async screenshot(args) {
    const page = pageFor(args);
    const data = await page.screenshot({ fullPage: Boolean(args.fullPage), type: "png", timeout: ACTION_TIMEOUT });
    return { ...(await describeTab(page)), png: data.toString("base64") };
  },
  async click(args) {
    const page = pageFor(args);
    await locate(page, args).click({ timeout: ACTION_TIMEOUT });
    await page.waitForLoadState("domcontentloaded", { timeout: 10_000 }).catch(() => {});
    return describeTab(page);
  },
  async type(args) {
    const page = pageFor(args);
    const target = locate(page, args);
    await target.fill(String(args.value ?? ""), { timeout: ACTION_TIMEOUT });
    if (args.submit) await target.press("Enter", { timeout: ACTION_TIMEOUT });
    await page.waitForLoadState("domcontentloaded", { timeout: 10_000 }).catch(() => {});
    return describeTab(page);
  },
  async close_tab(args) {
    const page = pageFor(args);
    await page.close();
    return { closed: true, tabs: await methods.tabs() };
  },
  async shutdown() {
    if (closing) return { saved: true };
    clearTimeout(saveTimer);
    await saveTabs().catch(() => {});
    closing = true;
    await context?.close().catch(() => {});
    context = undefined;
    return { saved: true };
  },
};

async function start() {
  await mkdir(PROFILE, { recursive: true });
  context = await chromium.launchPersistentContext(PROFILE, {
    headless: true,
    viewport: { width: 1280, height: 800 },
  });
  // The profile may come back with Chromium's own blank page.
  for (const page of context.pages()) idOf(page);
  context.on("page", (page) => idOf(page));
  let saved = [];
  try {
    saved = JSON.parse(await readFile(TABS, "utf8")).tabs ?? [];
  } catch {
    // Nothing saved.
  }
  for (const url of saved.slice(0, 20)) await open(url);
  // Drop the initial blank page once real tabs are back.
  for (const page of context.pages()) {
    if (saved.length && page.url() === "about:blank" && pages.size > 1) await page.close();
  }
  active = [...pages.keys()].at(-1);
}

process.on("message", async (message) => {
  const method = methods[message?.method];
  try {
    if (!method) throw new Error(`unknown browser action ${message?.method}`);
    const value = await method(message.args ?? {});
    process.send({ id: message.id, value });
  } catch (error) {
    process.send({ id: message.id, error: error instanceof Error ? error.message.split("\n")[0].slice(0, 500) : String(error) });
  }
});

process.on("SIGTERM", async () => {
  await methods.shutdown();
  process.exit(0);
});

start().then(
  () => process.send({ ready: true }),
  (error) => {
    process.send({ error: error instanceof Error ? error.message.slice(0, 500) : String(error) });
    process.exit(1);
  },
);
