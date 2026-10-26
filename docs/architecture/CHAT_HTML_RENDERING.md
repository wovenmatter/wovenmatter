# HTML visual replies

Agents publish self-contained interactive pages with `html_render`, rather than
executing ordinary fenced HTML. Each page appears inline above the final reply,
stays visible when the work transcript folds, and survives reopening the chat.
The viewer supports automatic height, responsive layout, theme changes, zoom,
and an expanded sheet on macOS and iOS. Expanding opens a separate view of the
page, so its temporary form/input state starts fresh there.

## T3 Code reference

Inspected upstream `pingdotgg/t3code` at
[`7510e5e43c6cb40d454530c9aaa9a8fbb43ab1bf`](https://github.com/pingdotgg/t3code/tree/7510e5e43c6cb40d454530c9aaa9a8fbb43ab1bf)
on October 26, 2026. Its current implementation is a tool and attachment flow,
not a Markdown HTML renderer:

- [`toolkits/html/tools.ts`](https://github.com/pingdotgg/t3code/blob/7510e5e43c6cb40d454530c9aaa9a8fbb43ab1bf/apps/server/src/mcp/toolkits/html/tools.ts)
  defines `html_preview` (HTML, optional width/appearance) and `html_render`
  (HTML, title, height). Preview returns a screenshot, console messages, and
  measured content height. Render publishes a page in the caller's thread.
- [`HtmlRender.ts`](https://github.com/pingdotgg/t3code/blob/7510e5e43c6cb40d454530c9aaa9a8fbb43ab1bf/apps/server/src/htmlRender/HtmlRender.ts)
  injects its bootstrap, embeds local images after signature/size checks, saves
  a thread-owned HTML attachment, and measures responsive heights with a private
  headless Chromium. Publishing can succeed without the preview browser.
- [`htmlRender.ts`](https://github.com/pingdotgg/t3code/blob/7510e5e43c6cb40d454530c9aaa9a8fbb43ab1bf/packages/shared/src/htmlRender.ts)
  defines the reference (`attachmentId`, title, height, optional width/height
  samples), theme CSS variables, and JSON-RPC theme, size, link, and keyboard
  messages. It rejects viewport-height CSS to avoid frame growth loops.
- [`session-logic.ts`](https://github.com/pingdotgg/t3code/blob/7510e5e43c6cb40d454530c9aaa9a8fbb43ab1bf/apps/web/src/session-logic.ts),
  [`HtmlRenderFrame.tsx`](https://github.com/pingdotgg/t3code/blob/7510e5e43c6cb40d454530c9aaa9a8fbb43ab1bf/apps/web/src/components/chat/HtmlRenderFrame.tsx), and
  [`BrowserDocumentFrame.tsx`](https://github.com/pingdotgg/t3code/blob/7510e5e43c6cb40d454530c9aaa9a8fbb43ab1bf/apps/web/src/components/files/BrowserDocumentFrame.tsx)
  turn successful tool references into standalone timeline rows, fetch signed
  attachment URLs, and render them in a sandbox without same-origin access.
  Live sizing can fit up to 20,000px; zoom and full-screen controls sit around
  the page. URL refreshes and theme changes preserve the loaded inline page.

## Woven Matter implementation

`default-agent/src/automation-tools.mjs` exposes both tools to Pi Durable and
the existing MCP server. The dependency-free remote MCP adapter exposes the
same schemas. Native harnesses also receive CLI instructions:

```sh
wovenmatter html call --json - --request-id UUID <<'JSON'
{"action":"render","html":"<button onclick='this.textContent=42'>Calculate</button>","title":"Calculator","height":160}
JSON
```

Use `action: "preview"`, optional `width` (240–1600, default 728), and optional
`appearance` (`light` or `dark`) to inspect a screenshot and console messages.
Preview uses an ephemeral WebKit view through the existing GUI automation relay;
the app must be open. Publishing needs no browser and remains available to a
connected local or remote harness. Phone tools use the existing central Mac
route. This does not add an offline phone publishing service.

Publication validates HTML (512,000 UTF-8 bytes), title (200 characters), and
initial height (80–2000px). It writes a normalized activity into the caller's
active device-owned run, using the request UUID for replay protection. A replay
with changed content fails. The small `htmlRender` reference survives compact
summaries; the full page is loaded through the existing conversation-scoped
activity-details API. Pages inherit the conversation/run's retention and sync
behavior without separate files or orphaned attachments. HTML never becomes an
assistant-text segment or a hidden generic tool result.

Device-owned phone sessions also reconstruct a page from the successful native
HTML call/result pair, retaining its full detail in the native journal and its
small reference in transcript summaries. Reopening and replicating that journal
preserve the page. References are deduplicated when the native projection and
the central publication meet. OpenCode server reconciliation preserves published
pages independently of its current native tool-part list.

`ConversationHTMLDocument` creates an app-owned wrapper with an opaque
`sandbox="allow-scripts"` iframe. The iframe inherits a restrictive CSP: inline
scripts/styles and data images/fonts/media are allowed, and network, local files,
forms, plugins, popups, and external navigation are blocked. The WebKit data
store is nonpersistent. The wrapper checks message sources, and native handlers
accept only main-frame messages. HTTP(S) links clicked inside a page use the
chat's existing external-link confirmation. Page content has no app tools or
session bridge.

Theme and zoom update the existing web view without reloading it. Live size is
bounded at 20,000px, and the expanded viewer scrolls long content. The screenshot
tool captures at most 2000px vertically and bounds encoded image output to the
existing tool-response transport limit.

Compared with T3, this implementation intentionally requires inline resources
and data URIs. It does not read arbitrary image paths or load external resources.
It uses system WebKit rather than downloading Chromium, measures live on the
client rather than storing a responsive height matrix, and uses native app
controls rather than forwarding T3's web keyboard shortcuts. MCP Apps are a
separate T3 feature and are outside this HTML-reply implementation.
