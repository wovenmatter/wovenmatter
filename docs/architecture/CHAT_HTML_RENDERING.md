# HTML visual replies

Agents publish self-contained interactive pages with `html_render`, rather than
executing ordinary fenced HTML. Each page appears inline above the final reply,
stays visible when the work transcript folds, and survives reopening the chat.
The viewer supports automatic height, responsive layout, theme changes, zoom,
and an expanded sheet on macOS and iOS. Expanding opens a separate view of the
page, so its temporary form/input state starts fresh there.

## T3 Code reference

Inspected upstream `pingdotgg/t3code` at
[`3f9448747bb8848050dc2cacf83affa6f94a66a1`](https://github.com/pingdotgg/t3code/tree/3f9448747bb8848050dc2cacf83affa6f94a66a1)
on October 26, 2026. Its current implementation is a tool and attachment flow,
not a Markdown HTML renderer:

- [`toolkits/html/tools.ts`](https://github.com/pingdotgg/t3code/blob/3f9448747bb8848050dc2cacf83affa6f94a66a1/apps/server/src/mcp/toolkits/html/tools.ts)
  defines `html_preview` (HTML, optional width/appearance) and `html_render`
  (HTML, title, height). Preview returns a screenshot, console messages, and
  measured content height. Render publishes a page in the caller's thread.
- [`HtmlRender.ts`](https://github.com/pingdotgg/t3code/blob/3f9448747bb8848050dc2cacf83affa6f94a66a1/apps/server/src/htmlRender/HtmlRender.ts)
  injects its bootstrap, embeds local images after signature/size checks, saves
  a thread-owned HTML attachment, and measures responsive heights with a private
  headless Chromium. Publishing can succeed without the preview browser.
- [`htmlRender.ts`](https://github.com/pingdotgg/t3code/blob/3f9448747bb8848050dc2cacf83affa6f94a66a1/packages/shared/src/htmlRender.ts)
  defines the reference (`attachmentId`, title, height, optional width/height
  samples), theme CSS variables, and JSON-RPC theme, size, link, and keyboard
  messages. It rejects viewport-height CSS to avoid frame growth loops.
- [`session-logic.ts`](https://github.com/pingdotgg/t3code/blob/3f9448747bb8848050dc2cacf83affa6f94a66a1/apps/web/src/session-logic.ts),
  [`HtmlRenderFrame.tsx`](https://github.com/pingdotgg/t3code/blob/3f9448747bb8848050dc2cacf83affa6f94a66a1/apps/web/src/components/chat/HtmlRenderFrame.tsx), and
  [`BrowserDocumentFrame.tsx`](https://github.com/pingdotgg/t3code/blob/3f9448747bb8848050dc2cacf83affa6f94a66a1/apps/web/src/components/files/BrowserDocumentFrame.tsx)
  turn successful tool references into standalone timeline rows, fetch signed
  attachment URLs, and render them in a sandbox without same-origin access.
  Live sizing can fit up to 20,000px; expansion controls sit around the page. URL refreshes and theme changes preserve the loaded inline page.

## Woven Matter implementation

The canonical Woven MCP catalog exposes `woven_html_preview`,
`woven_html_render`, and `woven_html_cancel`. Pi Durable discovers these through
its native MCP client; Codex, Claude Code, Grok Build, and OpenCode receive the
same tools through their caller-bound native MCP adapters. For example:

```json
{"name":"woven_html_render","arguments":{"html":"<button onclick='this.textContent=42'>Calculate</button>","title":"Calculator","height":160}}
```

`woven_html_preview` accepts HTML, optional `width` (240–1600, default 728),
and optional `appearance` (`light` or `dark`, default `dark`). It returns a
screenshot, console messages, and measured height. Preview uses an ephemeral
WebKit view through the existing GUI automation relay; the app must be open.
Publishing needs no browser and remains available to a connected local or
remote harness. Phone tools use the existing central Mac route. This does not
add an offline phone publishing service.

The invoking MCP adapter/device validates authored HTML (512,000 UTF-16 code units,
matching T3's JavaScript schema) and embeds absolute local image paths before
transport. This includes quoted HTML, CSS, JavaScript and backtick references,
and bare CSS `url(/path)`. Protocol-relative and HTTP(S) URLs remain URLs.
Each local image must be a regular file with an image signature and at most
10 MiB; the prepared page must be at most 25 MiB. Duplicate paths are read once.
Preview reports missing/unreadable/nonimage paths in `missingImages`; publishing
rejects them. Nonimage text is never embedded. Images stay with the saved page
when the source files move or disappear.

Preparation runs on the executing Mac, remote host, or phone, never on a Mac
merely observing a remote caller. Phone paths use the conversation's existing
workspace resolver and sandbox: absolute `/workspace/...` image paths map to the
conversation's private device files, as in the on-device command runtime. Phone
SDK result metadata retains prepared HTML
without returning the image bytes as model-visible tool text. Ordinary tool
requests keep their existing limits; HTML requests and the underlying bounded
RPC/companion transports accommodate prepared pages. The same canonical catalog
is generated for remote workspaces. Visual replies remain available with older
saved tool selections; explicitly limited outside-client grants still apply.
Publication is marked non-idempotent so adapters never automatically replay it
after an uncertain transport failure.

Publication validates prepared HTML, title (200 characters), and initial height
(80–2000px). It writes a normalized activity into the caller's
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
`sandbox="allow-scripts allow-forms"` iframe, matching T3's HTML reply sandbox.
The iframe inherits a CSP allowing inline and external scripts/styles, images,
fonts, media, HTTP(S) fetch, WebSockets, and HTTP(S) forms/frames. Local file URLs,
plugins, popups, same-origin access, and top-level navigation remain blocked.
External resources follow CORS and the platform's transport-security rules;
HTTPS works without an app-wide insecure-HTTP exception. The WebKit data
store is nonpersistent. The wrapper checks message sources, and native handlers
accept only main-frame messages. HTTP(S) links clicked inside a page use the
chat's existing external-link confirmation. Page content has no app tools or
session bridge.

Theme and zoom update the existing web view without reloading it. Live size is
bounded at 20,000px, and the expanded viewer scrolls long content. The screenshot
tool captures at most 2000px vertically and bounds encoded image output to the
existing tool-response transport limit, reducing image resolution when necessary while preserving the captured area.

## Parity review

| Behavior | T3 Code | Woven Matter |
| --- | --- | --- |
| Agent contract | `html_preview`, then `html_render`; caller-owned thread | Equivalent focused MCP tools and caller-owned conversation |
| Page and image budgets | 512,000 authored characters; 10 MiB/image; 25 MiB prepared | Same |
| Local images | Absolute quoted and CSS paths; signatures; retained data URIs | Same; prepared on the executing host/device |
| Missing images | Preview reports; render fails | Same |
| External resources | URLs load as authored | HTTP(S) allowed by CSP, subject to platform transport rules and CORS |
| Script isolation | Opaque iframe, scripts/forms allowed, no same-origin access | Same plus nonpersistent WebKit storage and no app/session tools |
| Preview | Width 728, optional 240–1600; dark default; PNG/console/height | Same; screenshot height capped at 2000 and output byte budget enforced |
| Responsive sizing | Stored width samples, then live sizing up to 20,000px | Live sizing up to 20,000px; no stored width matrix |
| Themes and interaction | Update live iframe without losing inline state | Same; native zoom and expansion controls |
| Persistence | Thread-owned HTML attachment | Conversation-owned activity detail, compact reference, native journal replication |

Native platform differences: system WebKit replaces T3's private Chromium;
client measurement replaces T3's responsive server measurements. Expanded views
are new WebKit instances, so temporary inputs reset there. External-link clicks
use Woven Matter's existing confirmation; T3 forwards them to its external
browser. Woven Matter does not add an app-wide ATS exception for insecure HTTP,
and does not forward T3's web keyboard shortcuts. MCP Apps are a separate T3
feature and are outside this HTML-reply implementation.

## Local harness acceptance

`scripts/test-changes.sh` exercises the real packaged tool paths after building
the native app, without inference or provider credentials. The opt-in Swift
test `packagedHTMLToolsWorkAcrossHarnesses` runs the Node driver in
`default-agent/test/fixtures/html-harness.mjs` against a real caller-bound HTTP MCP endpoint,
the normal publication service and the production WebKit preview implementation.

| Harness | Exercised entry points |
| --- | --- |
| Codex | Packaged native adapter, HTTP MCP discovery/preview/render |
| Claude Code | Packaged native adapter, HTTP MCP discovery/preview/render |
| Grok Build | Packaged native adapter, HTTP MCP discovery/preview/render |
| Pi Durable | Packaged native MCP discovery, tool registration and execution |
| OpenCode | Packaged plugin, native-tool session binding, HTTP MCP preview/render |

Every path previews at 728px/light and 390px/dark, checks PNG output, responsive
height, JavaScript execution, and embedded-image loading; then publishes, deletes
the source image, and reopens persisted page detail. It checks missing-image
diagnostics/rejection, rejects caller-selected conversation IDs, and verifies
pages remain visible in folded history. OpenCode additionally reconciles its
native snapshot before the persisted-page check. Separate ACP tests verify the
MCP configuration and connection metadata for both new and resumed Codex,
Claude Code, and Grok Build sessions.

These are deterministic integration checks of the harness adapters and tool
transports. They do not make model calls or certify account authentication or a
particular model's decision to use the tools. The phone package/journal tests,
native iOS builds, and remote MCP/relay fixtures cover their corresponding
boundaries separately.
