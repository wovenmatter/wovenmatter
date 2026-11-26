# Woven Matter UI style guide

Match the existing app and reuse its shared components. Keep this guide current
when an intentional design change is accepted.

- **macOS menu bar:** keep File, Edit, Appearance, Window, and Help after the app
  menu. File contains New Chat, New Artifact, New Browser Tab, Start/Stop Dictation,
  and Refresh Workspace. Route creation through the active workspace's existing
  flows. Preserve native Undo/Redo and clipboard commands in Edit; keep theme and
  sidebar layout in Appearance. Do not add a separate View or Workspace menu.
  Keep Window for native close, minimize, zoom, layout, and window-switching
  controls. Harness setup belongs in Settings. Disable macOS window tabbing so
  Window does not offer tab-management commands; in-app browser tabs are separate.
- **Colors and geometry:** use `WovenTheme`, `WovenPalette`,
  `WovenMetrics` in [WovenStyle.swift](../app/App/Views/WovenStyle.swift),
  and `DesktopShapes` in `DesktopDesign.swift`. Preserve the
  Green and Cognac light themes. Dark uses warm charcoal, forest-tinted rails,
  cream text, and lighter green/Cognac accents from shared `WovenColors`.
  The selected theme controls native appearance on macOS, iPhone, and iPad.
  Filled primary actions retain British Racing Green. Keep spacing, radii, and
  surface treatments consistent with adjacent screens; keep exact values in code.
- **Typography:** use the macOS system font and the existing size/weight
  hierarchy. Use monospaced text for code and monospaced digits for aligned
  numeric displays.
- **Text links:** use `WovenPalette.success` (`#0D8F5A`) for conversation
  Markdown links and SwiftUI external-link labels so they stand out against the
  body text. The shared token supplies lighter green in Dark.
- **Composer selectors:** use title-case popout headings, such as `Thinking Level`,
  without all-caps styling or expanded letter spacing. Keep saved-default actions
  out of the conversation selector popouts. Composer model buttons show only the
  model name and version; connection attribution belongs in the model popout.
  Permission menus offer only Full access and, where the harness has one, its
  auto mode under the harness's own name (Codex Approve for me, Claude Code and
  Grok Build Auto). List Full access first; it is the default everywhere. Never
  offer an ask-for-approval mode.
  Permission buttons use the fullest label that fits, then explicit shorter
  labels, then an icon. Never ellipsize these labels or collapse distinct modes
  such as Auto and Auto Accept into the same text. Popouts retain full labels
  and descriptions. On iPhone, keep the composer controls on one compact row:
  add, model name, thinking level, permission key, tools icon, and send. Keep
  permission and tool labels inside their popouts so the model and thinking
  selection stay visible. Keep the dictation microphone beside the text entry
  area above this row.
- **Composer setup notices:** explain missing model configuration in a full-width
  quiet action above the input. Use regular-weight secondary text, allow wrapping,
  and open Pi Durable settings in the relevant workspace scope.
- **Components:** reuse the shared cards, selectors, search fields, and button
  styles in `WovenStyle.swift` and `DesktopDesign.swift`, and the page/row
  patterns in
  [SettingsComponents.swift](../app/App/Views/SettingsComponents.swift).
  Preserve intentional differences such as borderless Usage sections.
- **Mobile Quick Chat:** name the device conversation feature **Quick Chat**,
  with **Powered by Pi Durable** in its setup explanation. Mac/Linux agents retain
  their harness names. On the mobile home page and in the New Chat menu Quick
  Chat comes first and the workspaces follow it, each once under its own name.
  A message sent to a Mac or Linux session shows at once with quiet caption
  progress ("Sending to …", "Starting on …"), never a spinner. Home, Folders, New Chat and Calendar list only
  Mac and Linux workspaces that are reachable now; Settings → Workspaces keeps
  every saved workspace with its connection state. Never add an "Unavailable
  workspace" group: folders whose workspace is not listed stay in All Workspaces.
  Web search keys (Exa, Brave Search, Firecrawl) live in Settings → Subscriptions & API Keys with
  the model providers. Do not add data-sharing prompts:
  connecting a provider is the user's choice to use it.
  With no Mac reachable the app must still feel complete: no blocking screens, error banners or
  "not reachable" wording. Home shows one "Connect your Mac" row with a
  single caption saying what a Mac adds; Mac-only pages stay hidden until one is reachable. The
  Quick Chat composer notice reads "Sign in to a model provider to use Quick Chat", then
  "Add a web search key for answers from the web" until a key is saved.
- **Agent naming:** use **Pi Durable** for the agent in navigation, settings,
  conversation labels, and actions. Use **Pi Durable SDK** for the underlying SDK
  in technical descriptions and version/update controls. Keep the agent name
  stable across model and provider changes.
- **Settings pages:** keep the landing list and drill-down navigation; do not add a
  tab row or segmented control that switches between pages or page areas. Pages use a
  720-point column. `SettingsSection` is a 14-point heading, at most one sentence,
  then rows, separated by spacing without cards or divider lines. `SettingsRow` puts
  a 13-point title and 11.5-point secondary line on the left and the control on the
  right. `SettingsSummaryRow` shows a title, its current value, and a chevron, and
  opens details on request; `SettingsSummaryLink` is the same row for navigation.
  Collapse related options into one summary row rather than listing switches on the
  page, and prefer one dropdown to a pair of switches. Use `SettingsPicker` for
  dropdowns and `SettingsStatus` (dot and text) for readiness. Use the `Font.settings*`
  tokens and palette tokens, not literal sizes, `.secondary`, or `.red`. Longer
  explanations fold into `SettingsHelp`. Hide what does not apply. Each capability
  has one home; other pages show status and link to it.
- **Settings navigation:** group Pi Durable, Codex, Claude Code, Grok Build, and
  OpenCode under **Settings → Agents**. Agent pages return to Agents unless
  opened from a remote workspace's page. Spell **OpenCode** as one word throughout
  the app. Order the main Settings page as General, Updates, Permissions & Access,
  Subscriptions & API Keys, GitHub, Agents, Bots, Woven MCP, Workspaces, Apple
  Devices, Background Server, Dictation, then Analytics and Privacy. Subscriptions & API Keys, Permissions &
  Access, Woven MCP, Bots, and Updates return to the page whose link opened them.
- **Updates:** the one home for versions and updates.
  - **The top row:** "This Mac · Woven Matter X" ("Woven Matter development
    build" in development), always subtitled "This updates the Woven Matter
    desktop app on this Mac.", with **Check for updates** and, when a newer
    release is out, **Update this Mac**, the page's one primary button.
  - **Three rows with a compact Update each:** "Update everything", "Update
    just Woven Matter", and "Update just the harnesses", each subtitled with
    what it covers across your machines. No full-width buttons, and never
    "fleet".
  - **Your machines:** no subtitle. One expandable row per machine, named as on
    the tailnet, this Mac first, then other Macs, then remote workspaces. The
    closed row shows only its name, its Woven Matter or Woven server version,
    **Bots** on the one machine that runs bots, and a status; it has no Update
    button. Opened, it lists "Update everything on this machine", "Update just
    Woven Matter", "Update just the bots" where they run, then each harness,
    each with its own **Update**. Bots never show a version of their own.
  - **Updates run side by side:** starting one never disables the others. Only
    the rows an update covers show "Updating…"; a button whose parts are all
    already updating waits.
  - **Plain copy:** subtitles are full sentences saying what the row updates.
    No "How it works" section; the rows explain themselves.
  - **No update counts:** each row says "Update available" itself.
  Work an update would stop is named in one alert before anything starts; Linux
  harness downloads are reviewed in one confirmation per update. Other pages
  show only a "Versions don't match" link here.
- **General:** the Woven Matter version first (no heading), as one whole-row link
  that highlights on hover and opens Updates, with one line saying updates live
  there. Then Appearance and Conversation titles. Other
  settings live on the page for what they affect. Summary rows whose value would be
  unclear before opening (Sidebar sections, Agent icons) show a one-line description
  instead. Conversation titles show the Codex account they use and link to its page.
- **Analytics and Privacy:** the last Settings page. It is the app part of the
  privacy policy at wovenmatter.com/privacy in the policy's own words, without
  the website parts, then the contact and policy links, and at the bottom the
  one switch, which applies to the library. Change the page and the policy
  together.
- **Bots:** the Bots section sits above New chat in the navigation rail, using the
  rail's own disclosure headings and rows. There is one "Bots" heading, for the one
  machine that runs bots; machines still running bots from before that rule are named
  in one quiet row that opens Settings. A bot's row shows only its name and
  opens its main channel; a chevron reveals its threads, pinned first and then newest
  created. Thread dropdowns start closed. The Forum is a row in the same section, above
  Admin Bot, with the same chevron and thread rows and "Paused" as its trailing word.
  It opens like a bot's channel: the same transcript, composer and thread-beside
  layout, with the poster's name over each bot's post, a bots button (who is in), a
  scheduled-posts button and one Pause or Resume button in its header, a banner while
  paused, and a one-line note above the composer of what the draft's mentions do.
  Typing "@" in the composer lists the bots in the same inline list slash commands
  use, narrowing as the name is typed; there is no separate mention button.
  Wording: only the Forum is ever "paused". A bot whose models are all at a usage limit is
  "out of usage" everywhere (its sidebar row, the banner in its channel, the profile
  editor), one on a fallback model says "Fallback". Woven MCP access is "revoked" and
  "reinstated", for one bot (its key) or for every bot on a machine (the older hold,
  "Woven MCP revoked"), never paused. Text says "bots" or "your bots", not "bots on this
  Mac": a machine is named only where the user picks it, goes to it, or it is the thing
  that is unavailable. A bot in the Forum "sees" posts; one switched out sees none.
  Everything about bots is native and uses the
  components regular chats and Settings use: the shared transcript text, user bubble and
  composer, and Settings sections and rows. A thread sits beside its bot's main channel
  at 760 points and wider. Message actions appear on hover. Bots run on one machine.
  **Settings → Bots** holds one "Run bots on" choice (Off, This Mac, or another Mac or
  Linux machine), the chosen machine's row, Install on another machine, and a
  "Versions don't match" link to Settings → Updates. Choosing a machine asks first, then turns bots off
  everywhere else; bots and their files stay where they were made. Below it, for the
  chosen machine: a "Your name" row, and a Forum section with a Pause switch and a
  "Bots in the Forum" summary row that opens one switch per bot. The machine opens
  its own page: a status row with a Manage menu, then summary links to Profiles, Bots
  and teams, Resources, and that machine's Subscriptions & API Keys. Profiles and bots
  are summary rows that open for editing. Bots' Woven MCP access lives in Settings →
  Woven MCP, with no pause switch; Bots shows it as one summary link. Apple Devices
  shows only a version status link to Updates. Bots use Subscriptions & API Keys on the
  machine they run on; there is no separate bot sign-in.
- **Harness setup:** use compact rows grouped on the theme-whisper surface for
  both harness installation and Pi Durable setup, with the same typography,
  padding, inset dividers, and quiet actions. Keep provider setup limited to
  OpenAI, Anthropic, Grok, OpenRouter, and OpenCode; web-search setup shows only
  the Exa key form. Both are optional and also accessible from Settings →
  Subscriptions & API Keys.
- **Subscriptions & API Keys:** provider sign-ins, API keys, web search keys, and
  local model servers have one home, used by Pi Durable, Usage, and bots. Each
  provider is one summary row showing what is connected. Choose the web search
  provider on its row, beside its key. A new account offers Choose chat models, and
  connecting one on this Mac turns on its limit checks. Keep the "Sign in on"
  selector visible: every machine keeps its own sign-ins, and each must stay
  reachable. Native harnesses sign in on their own agent pages.
- **GitHub:** one SSH key and git identity for agents and bots on every
  machine; there is no per-bot, per-workspace or per-harness GitHub key. The SSH
  key section shows the key's name and fingerprint with a Ready status, the
  public key in monospace, then Copy public key, Add key on GitHub, and Remove
  key; Generate a key (Replace with a new key, after asking) and Paste an
  existing private key follow. The private key is never shown after saving. Git
  identity is a Name and Email form with Save identity; blank fields keep each
  machine's own git settings. With a key, Where the key goes lists New places get
  the key, then each machine (This Mac first, other Macs, Linux machines) with
  its bots indented beneath it, each with a switch on the right; a machine turned
  off turns off its bots. One note says a place turned off stops at its next git
  command, and an offline one when it's next online. There is no How it works
  section. The landing row shows Key added or No key.
- **Agent setup:** Pi Durable links to Subscriptions & API Keys with a one-line
  description and how many are connected, then shows Models, Defaults for new
  chats, and More. Models holds the default model, In the composer, and Fallbacks. Add
  models opens the provider catalog with its filters and paging in a sheet. Guided
  setup opens that sheet after a successful sign-in or key addition.
- **Usage:** account setup lives in Subscriptions & API Keys, linked from Limits. A
  fixed header holds the title, the Analytics/Limits switch, and refresh. Machine
  analytics never depends on limits-account switches or credentials.
  No rule lines separate the header, filter column, and report; spacing does that.
  While a range has no data yet, the page keeps its full layout with muted placeholders
  and never reads as zero. Analytics keeps a fixed filter column to the left of its scrolling report: search,
  range, machine rows, provider rows, then compact Model, Harness, and Reasoning
  dropdowns. Machine and provider rows are an intentional exception to switches for
  multi-select toggles: click a row to show or hide it; a hidden row keeps its place
  with a hollow swatch and muted text. Provider rows are the graph's legend. A machine
  whose usage may be missing or old says why in its row, never showing zero. The report runs graph, breakdown
  numbers, by provider, by model, sessions, then collapsed source coverage. Sections
  stay borderless with hairline rows. Provider colors follow the provider, never rank;
  neutral ink shows token types. Graphs default to layered lines with a Bars switch and
  to Tokens with an API estimate switch. A period keeps a minimum width, so long ranges
  scroll sideways under a fixed y-axis and open on the latest period, with edge fades
  and earlier/later buttons in place of a scrollbar. Label estimates; never mix them
  into direct spend. Unknown prices read Unpriced, never $0.
  Limits uses one-column rows for each saved account: window, bar, amount left, reset.
  Bars show what is left, with a tick where even spending would be. Signed-out providers
  share one line. Unavailable data is never shown as zero usage or a full allowance.
- **Tool defaults:** settings say Woven MCP and show effective defaults,
  rather than an off-looking inheritance switch. Composer controls retain Tools.
  **Settings → Woven MCP** holds tool defaults, connected apps, bots, and outside
  agents; agent pages show one Woven MCP summary row for their own defaults.
- **Permissions & Access:** Keychain and every macOS permission Woven Matter uses
  live on this one Settings page, directly after General. It opens with one sentence:
  agents on this Mac or the user's other machines stop at a prompt here without
  these permissions. Everything is one section: a header with how many are not
  allowed yet and one **Allow all** button, then one row per permission with its
  System Settings name, one line saying only what it does (no instructions), and a
  quiet "Allowed" check or its own **Allow** button. Allow all brings up each prompt in turn with no steps, Skip or
  Stop. A row shows **Reopen** only when macOS needs the app reopened. Other
  settings that depend on a permission (Dictation, Computer Use) show a one-line
  status with a Permissions & Access link instead of their own controls; the
  Settings landing row shows "All allowed" or "N to allow" as its status. A session
  on a Mac missing a permission it needs shows a full-width quiet notice above its
  composer, like the composer setup notices. Consent is not verification.
- **Harness lists:** Agents and remote workspace pages use flat rows: logo, name,
  status, and a chevron to the agent page. Versions, installation, sign-in, updates,
  and diagnostics live only on the agent page. Remote workspaces have no global
  enable switch; saved workspaces reconnect using silent Keychain reads.
  Installed harnesses are available automatically in local and remote workspaces.
  Do not add harness enable/disable, Use harness, or per-harness sidebar visibility
  controls. Installation, sign-in, and connection status communicate readiness.
  Save remote agents in the library when installed and show them on
  launch, including while disconnected or awaiting sign-in. Background readiness
  checks gate execution, never sidebar membership.
- **Harness accounts:** sign-in belongs to each harness settings page, scoped to
  Local workspace or a named remote workspace. Workspace inventory shows status and links
  to that scoped page. Never label credentials present as verified sign-in.
  Sign-in happens in the app, never in Terminal, except OpenCode's key picker: the
  same panel as Subscriptions & API Keys (Open sign-in page, Copy link, the one-time
  code with Copy code, and a field for a page's code), using the regular browser
  sign-in on this Mac and each harness's headless sign-in on remote machines. A
  signed-in account shows its name or email with **Remove account**; **Sign in**
  shows only when nothing is signed in. There is no "Change sign-in".
  New remote workspaces offer skippable, reopenable setup with only Pi Durable
  selected by default. Installs run each vendor's official installer with no review
  step; the only question is **Replace OpenCode 1?** when OpenCode 2 would replace it.
- **Chat defaults:** use Defaults for new chats on every harness page. Group
  thinking level and permissions together, with one short explanation.
- **Agent pages:** one page with no area switcher: the harness's account ("Codex
  account"), Software, then Defaults for new chats, using the same layout for every harness. Pages have one Applies to
  selector, hidden when there is no remote workspace or local override. Keep Use shared
  chat settings inside Defaults for new chats. Changing chat inheritance must not
  change credential selection. Pi Durable uses the sign-ins of the machine it runs on,
  managed in Subscriptions & API Keys; show their labels. Explain native
  harness capability differences under How it works: reusable API keys are not the
  same as automatic credential sync, and native subscription sign-ins stay with their
  installation. Never show key/token values or infer names that a harness does not expose.
- **Pi Durable updates:** use the same compact Software row as other harnesses:
  embedded SDK versions on one summary line, installed status, and one Check for
  updates / Update action per workspace. Update all outdated components in one staged activation. Shared scope
  lists local and remote installations; an individual scope shows that installation.
  Keep progress and errors with their workspace and preserve operation state when
  a remote row is collapsed.
- **Settings disclosures:** use `SettingsDisclosureGroupStyle` throughout settings
  editors so the chevron, label, and remaining header width all toggle expansion.
  `SettingsPage` supplies this by default; standalone settings sheets apply it
  explicitly. Keep this behavior for new sections, including nested Executor controls.
  The style propagates to nested provider, credential, account, and Executor
  defaults disclosures, workspace overrides, local model servers, fallback models,
  and workspace synchronization.
  OpenAI, Anthropic, and Grok show their subscription first, with API keys folded
  under a Use an API key disclosure that opens when a key is saved.
  Each subscription shows one account with Reconnect/Remove, without
  Add account, priority labels, or ordering controls. Show the subscription identity
  without primary/backup wording. API-key lists show Primary followed by numbered
  backups. Mobile permits one subscription connection per provider per device,
  with reconnect through the saved connection.
  OpenRouter, OpenCode, Exa, Brave, and Firecrawl show API-key controls directly when expanded.
  Keep their content at the same indentation as the content
  inside the nested credential groups.
- **Icons:** use the existing `LucideIcon` glyphs and bundled harness
  logos, matching nearby icon sizes and stroke weights. Pi Durable’s color and
  black-and-white variants share the same circular black badge, padding, and mark
  bounds.
- **Asset and browser toolbars:** keep the tab strip and address row the same
  height, with matching button frames and minimal space between hover fills and
  dividers. Use the shared asset-toolbar metrics, including for tab-close and
  sidebar reveal buttons. Keep a single ellipsis menu without a second chevron.
- **Calendar:** keep the four-item legend below the selected-day list. Use the
  saved category colors for event markers and recurrence labels. Default to
  British Racing Green events, royal blue scheduled tasks, purple recurring
  events, and Cognac recurring scheduled tasks. The picker offers Cognac, British
  Racing Green, lighter green, royal blue, purple, red, pink, orange, yellow, and
  black. Choices persist and may be reused across categories.
- **Sidebar foregrounds:** use `WovenPalette.foreground` (`#0A1F16` in Green and Cognac, cream in Dark) for text and interface icons in both rails, including section headings, metadata, and pinned indicators. Keep colored agent/harness logos in their original colors; monochrome marks use a contrasting foreground in Dark. Shared controls use the sidebar foreground environment only inside the rails.
- **Words:** use these the same way in the app, the docs, and everything an agent
  or a bot reads.
  - **Machine:** a Mac or Linux computer on your tailnet, with or without Woven
    Matter. Say machine when the text is about the thing itself: adding or
    removing it, updating, restarting, storage, the tailnet, sync, usage per
    machine.
  - **Workspace:** the place you work on a machine: its agents, folders and
    sessions. Each machine has one. **Local workspace** is the one on this Mac; a
    **remote workspace** is one on any other machine, Mac or Linux. Say workspace
    when the text is about working there: the sidebar, where a session, folder or
    database lives, which agents are available. Add workspace picks and inspects
    a machine, then creates the workspace on it.
  - **Host:** only the machine the bots run on, "the bots' host". Never a machine
    in general, and never a verb: a machine runs agents.
  - **Library:** the database that holds everything and syncs across machines.
    Never a workspace.
  - **Device:** only an iPhone or iPad (Settings → Apple Devices). Never a machine.
  - **A bot's files:** what a bot keeps in its container. Never its workspace.
  - Keep "This Mac" where the text is about the Mac itself, and All Workspaces as
    the no-folder choice.
- **Workspaces:** one list with the local workspace as a status row and remote workspaces
  as rows that open their detail. Forms for adding
  a workspace open from Add workspace. A remote workspace shows status with a Manage
  menu, its agents, and Details; do not lay actions out as a strip of buttons.
  Dev workspaces include `(Dev)` and their instance name. Hide retained snapshot
  owners and stopped Dev connections from the active inventory.
- **Machines:** every machine on your tailnet that runs the Woven server reaches all
  workspaces; do not add per-machine workspace permissions or
  execution-sharing switches.
- **Workspace sidebar:** each workspace lists only its folders, starting with New
  folder, scoped to that workspace. Pinned folders lead the list without a separate
  Pinned section. Do not list agents in the sidebar. Remote workspace names sit one
  level in under Remote workspaces; every workspace's New folder row and folders
  share that same single level, with no second level of nesting. All Workspaces sits above the workspaces, Trash below them,
  and Recents remains global. Never add an Unassigned workspace section: folderless
  chats appear in All Workspaces and still have an execution owner. Folder hover cards match chat previews and show the
  workspace, chat/note counts, root directory, and additional reference directories.
- **Sidebar headers:** in Single and Adaptive layouts, mirror the header button
  order when the sidebar moves to the right, and point the workspace back arrow
  toward the navigation rail. Keep titles and list content in normal reading order.
- **Switches:** settings pages use `SettingsSwitchToggleStyle`, with the switch on the right edge of its row like every other control. Elsewhere, use `CompactSwitchToggleStyle` for boolean controls and multi-select toggles. It supplies compact native switches in a 28 × 16-point control frame before their labels on the left, in the shared forest-green action color and is the default at the app root. iPhone Tools popouts keep native switches at 65% scale inside 44 × 44-point touch frames, with labels on the left and padding around the scroll content. Markdown task-list markers remain document content.
- **Interaction:** keep controls compact, selection fills restrained, and focus
  styling quiet. Popover and sheet text inputs use `quietTextInput()`
  for a neutral border without a colored focus ring. Clicking noninteractive
  content inside a form releases text focus without closing it.
  Shared controls distinguish enabled hover, press, selection,
  and disabled states without making quiet or icon actions look primary. Do not
  add persistent colored focus rings. Preserve keyboard navigation and accessible
  labels and states, and respect Reduce Motion and Reduce Transparency.
- **Text inputs:** use `WovenSearchField` for search and `.wovenInput()` for
  new text/secure fields, including desktop settings. These use
  plain native editing on the theme-whisper surface, matching sidebar chat search.
  Never use `.textFieldStyle(.roundedBorder)`, native blue focus outlines, or a
  custom bright focus border on app forms. Do not disable focus or keyboard
  navigation to hide a ring. Inspect both focused and unfocused states in Green,
  Cognac, and Dark, including secure fields. Native system dialogs
  and document content are outside this rule.
- **Dark content:** apply the theme to app-owned surfaces, including native
  editors, tables, charts, sheets, and popovers. Adapt note ink and highlights
  for readability without saving display colors into document formatting.
  Preserve colored harness logos, webpages, and authored HTML; do not inject recoloring
  or inversion into their content.
- **Notes:** keep the header controls in this order from left to right: Undo,
  Redo, Version history, Database, Format note, Microphone. Pages use Undo, Redo,
  Version history, Database, Add component (a plus), Format page, Microphone.
  Sheets use Undo, Redo, Version history, Database, Format sheet, Microphone.
  Apps, which agents edit, use Undo, Redo, Version history, Database; their
  Undo and Redo step through code changes. Use the same compact
  icon button style and frames for the microphone and adjacent controls, without
  a divider. The note-body count sits at the bottom right, starts with words, and
  switches between words and characters when clicked. Keep it in one compact
  24-point bottom gutter outside the scrolling text, without stacking additional
  editor or footer padding beneath the note. Align the count button's right
  edge with the header controls using the same 12-point side inset.
- **Artifacts:** call everything people create in the library an **artifact**:
  Notes, Pages, Sheets and Apps. Never call them assets in the interface. Label the
  creation picker **New Artifact** and the Library's general saved-output
  collection **Saved Artifacts**. New Artifact lists Note, Page, Sheet, App, each
  with a one-line description that says what it is. Apps are interactive apps your
  agent builds, usually on live data; data connections are optional. The Artifacts
  sidebar filters these types. Preserve the existing HTML sandbox. Describe an App
  connected to live data as a **Live App**. Keep **App** as the single creation
  option; Live is a description of the data connection, not another type. These
  experiences run inside Woven. An empty App shows **Ask an agent to build this**
  and points to the open chat, which builds it like any other edit; it has no
  message box of its own.
- **Pages:** make the flowing document the primary experience. Reuse the native
  Notes editor for contiguous text, lists, formatting and tables. Use one outer
  scroll surface; text grows to fit rather than becoming a scroll box per
  component. Keep editable paragraph positions before, between, and after
  sections, tasks, images and embedded artifacts. Nest sections with quiet
  indentation and disclosure controls. A Page never holds another Page. The plus
  menu offers Task, Section, Table, Existing artifact, Image, and New Note, Sheet
  or App; typing is how text is added, so there is no Text entry. List only image
  sources available on the device. Grow tables directly: hover buttons at the
  right and bottom edges and right-click insert and delete.
  Show a task as one full-width line: a status circle, the title, the status
  label, the **Assign** dropdown and the component's ⋯ menu. **Instructions**
  appear beneath while the task is selected or once written. The status circle and
  label are set by whoever has the task (In progress, Needs input, Done), never a
  control, except a small status menu when it is assigned to the person; show what
  the assignee wrote below the line. Assigning never sends; a primary **Send**
  appears while someone waits to be sent. The Assign dropdown lists who has the
  task with their actions, then Me, agents by workspace as the sidebar names them,
  then bots. A Mac Page has no component details panel. Agent dispatch uses the existing chat admission and permissions.
  Mark embeds **Original**. Notes, Sheets and Apps edit the same library artifact
  wherever it is embedded. Use the original editor and database-link refresh path.
  App form inputs and custom state persist on that original, with a visible
  save error and explicit retry after a conflict. Data refresh must not reload the
  interface or erase input being entered. Preserve normal title, version
  history, and draft recovery controls. Keep the existing sync limitations clear;
  this is not distributed live editing.
- **Conversation progress:** use the shared elapsed work header and static semantic
  icons with meaningful live text. Do not show busy spinners in tool-call rows,
  work-group headers, reasoning indicators, or tool-detail loading. While a turn
  runs, thinking and assistant messages stream visibly in chronological order.
  The elapsed header (with a chevron) folds its thinking, commentary and tool
  calls at any time, and the turn folds them itself when it ends, leaving the
  reply, an error, a proposed plan or an inline page in view. A turn in which the
  reader opened a row, group or thought while it ran stays open when it ends. Live tool calls append as
  separate rows in the conversation; never replace the preceding tool with the
  latest call. A new thinking, commentary,
  or other standalone event condenses only the preceding tool list into a
  reopenable disclosure. Show supplied subagent rows at their event position.
  Preserve the reader's position; follow new work
  or reasoning only from the live edge. Only the reader decides whether the
  transcript follows: scrolling away, opening or selecting something stops it,
  and scrolling back to the end or Latest reply resumes it; layout never does.
  A chat opens at its end, with the end of its last reply clear of the composer. Between a tool and the next visible output,
  use a static Thinking label. Thinking is marked with a static brain, in chats
  and bot chats. While a turn runs, one row of three small dots sits under the
  last thing it shows, starting where that thing's text starts, its strong dot
  stepping left to right, still under Reduce Motion: at the work lane's text edge, or at the reply's. The
  turn's fold at its end is instantaneous. Keep detail-loading text quiet ("Loading details…")
  and never add a separate mobile running spinner below the transcript.
- **Conversation layout:** agent chats, bot chats and the Forum share one rhythm
  from `ConversationMetrics`; keep exact values there. Everything in an assistant
  turn starts at one left edge, and user messages, the assistant turn and the
  composer share one column and so one right edge. A long user message
  collapses to six lines only when that hides at least three more at its width;
  otherwise it shows whole, with no control. Gaps come from roles: one gap
  between turns in both directions; work, reply, files and the changed-files card
  are sections; work-log entries sit closer, and rows inside a group closer
  still. Commentary sits close to the tools it introduces and further from the
  work before it. The work log is a secondary lane: everything in it is one
  size below the reply, commentary a step quieter than the reply's ink, tool
  labels quieter, reasoning quietest; its text starts at one inset, with only
  icons left of it, and open work ends a section and a half above the reply. A
  visual reply and the reply that explains it are one answer, a section apart.
  The work divider shows only over foldable work that is showing, never over a
  lone Thinking row or the dots. Tool rows are one
  line, truncated in the middle, with the chevron right after the label; the
  full text is in their details, which open at the rows' text inset and wrap
  rather than scroll sideways. Every harness's tool rows use one grammar: a
  verb and a short object (Read docs/README.md, Listed sample, Searched for
  “x” in docs), paths relative to the folder the tool ran in or else their last
  two components, and commands without the folder plumbing in front of them. A
  plain read-only shell search, listing or file read takes the same words as the
  file tool; anything compound shows its first part and an ellipsis, since a row
  never claims what its command did not do. Verbs are past tense once done.
  Woven's visual tools have one label each, previewed or shown, and a group
  names its kinds of step in the rows' words ("Listed 1 folder and read 2
  files"), never an unnamed action. Thinking looks the same everywhere.
  Live reasoning shows its last three lines, its cut top line fading out; afterwards a
  thought with text is one closed row named by its title or leading heading,
  else "Thought", never by its raw text; one with no text draws nothing. A
  record such as an approval is named by status and action, with its own glyph. A visual
  reply sits in a hairline frame with its title inside, the column wide or as
  wide as it asked to be, with a small inset inside it; its controls show on
  hover, while zoomed, or with focus. Under the reply, Copy and the files it
  refers to share one wrapping row. In reply text,
  lists sit tighter than paragraphs, two different lists in a row are spaced as
  paragraphs, every item keeps its marker, a task's box is one drawn square,
  filled with a check or outlined, headings attach to what follows them, and
  code, tables and quotes keep the same space on each side and start at their
  block's indent. Inline code is shaded around its own text on each line. Table
  columns fit their content; a table nearly as wide as the text fills it, and
  one too wide gives the rest to its widest column. Each block's spacing depends only on the block before it, so streamed
  text never moves. Nothing moves when a turn settles: the dots hold the row
  Copy then takes, and parts with nothing to show draw nothing. In agent chats,
  bot chats and the Forum alike, rows fade out before the window's floating
  buttons at the top and before the composer at the bottom, and the
  button back to the latest reply or post is a small round one centred above it,
  over a band where nothing is legible.
- **Scrolling:** hide scrollbars throughout the app while preserving scrolling. Set
  `.scrollIndicators(.never)` on SwiftUI scroll views and editors, including
  sheets and popovers. Disable both scrollers on AppKit `NSScrollView` editors.
- **Layout:** use the existing sidebar, chat-panel, and compact/expanded composer
  patterns. Check affected views at narrow and wide widths and respect Reduce
  Motion and Reduce Transparency. Below the desktop breakpoint the rails hide on
  their own; a revealed rail docks beside the conversation with the same width,
  inset, and surface as at full width, and the conversation resizes rather than
  sliding, dimming, or clipping. Only one rail is shown there: Split shows the
  revealed side, and Adaptive shows one page with its back button.

Compare rendered changes with the existing screen or supplied design reference.
Code cleanup alone should not alter appearance or interaction.

## iPhone and iPad

Both Xcode targets compile `app/App/Views/WovenStyle.swift` and bundle
`app/App/SharedAssets.xcassets`. These are the canonical Lucide glyphs, harness
logos, Green/Cognac/Dark palettes, radii, search field, segmented selectors, and
primary/quiet/icon buttons.
Do not copy the icon catalog or introduce a parallel mobile palette. Desktop
runtime metadata and window-specific controls remain in `DesktopDesign.swift`.

The iOS app keeps Dynamic Type and a 44-point minimum for shared touch controls;
desktop sizing is unchanged. Dark uses the same shared palette on both platforms. Native sheets, pickers, switches, QR scanning and share controls retain
iOS behavior. SF Symbols used by desktop for spreadsheet/HTML/file kinds, text
formatting, and status controls remain deliberate exceptions to Lucide.
