// A Playwright stand-in for the browser helper (`WOVEN_PLAYWRIGHT_MODULE`), so tests need no
// Chromium. Pages only track URLs. Like Chromium, a launched profile is locked with Singleton*
// links that a clean close removes and a kill leaves behind, and a profile that is still locked
// refuses to launch. URLs containing "unreachable" fail to load (an error page); navigating to a
// URL containing "crash" makes the browser die shortly after.
const { EventEmitter } = require("node:events");
const { lstatSync, rmSync, symlinkSync } = require("node:fs");
const { hostname } = require("node:os");
const { join } = require("node:path");

const LOCKS = ["SingletonLock", "SingletonSocket", "SingletonCookie"];

class Page extends EventEmitter {
  constructor(context) {
    super();
    this.context = context;
    this.address = "about:blank";
    this.frame = {};
    this.closed = false;
  }
  url() {
    return this.address;
  }
  mainFrame() {
    return this.frame;
  }
  async title() {
    return `title of ${this.address}`;
  }
  async goto(url) {
    if (url.includes("unreachable")) {
      this.address = "chrome-error://chromewebdata/";
      this.emit("framenavigated", this.frame);
      throw new Error("net::ERR_NAME_NOT_RESOLVED");
    }
    if (url.includes("crash")) setTimeout(() => this.context.crash(), 50);
    this.address = url;
    this.emit("framenavigated", this.frame);
    return { status: () => 200 };
  }
  async waitForLoadState() {}
  async evaluate() {
    return `text of ${this.address}`;
  }
  async close() {
    if (this.closed) return;
    this.closed = true;
    this.context.open.delete(this);
    this.emit("close", this);
  }
}

class Context extends EventEmitter {
  constructor(profile) {
    super();
    this.profile = profile;
    this.open = new Set([new Page(this)]);
  }
  pages() {
    return [...this.open];
  }
  async newPage() {
    const page = new Page(this);
    this.open.add(page);
    this.emit("page", page);
    return page;
  }
  async close() {
    for (const page of [...this.open]) await page.close();
    for (const name of LOCKS) rmSync(join(this.profile, name), { force: true });
    this.emit("close", this);
  }
  /** The browser process died: pages and context close, the profile lock stays. */
  crash() {
    for (const page of [...this.open]) {
      page.closed = true;
      this.open.delete(page);
      page.emit("close", page);
    }
    this.emit("close", this);
  }
}

exports.chromium = {
  async launchPersistentContext(profile) {
    for (const name of LOCKS) {
      let found = false;
      try {
        lstatSync(join(profile, name));
        found = true;
      } catch {
        // Not there.
      }
      if (found) throw new Error(`The profile appears to be in use by another Chromium process (${name})`);
    }
    symlinkSync(`${hostname()}-${process.pid}`, join(profile, "SingletonLock"));
    symlinkSync("/tmp/.org.chromium.Chromium.fake/SingletonSocket", join(profile, "SingletonSocket"));
    symlinkSync("1234567890", join(profile, "SingletonCookie"));
    return new Context(profile);
  },
};
