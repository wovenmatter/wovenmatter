# Woven Matter UI style guide

Match the existing app and reuse its shared components. Keep this guide current
when an intentional design change is accepted.

- **macOS menu bar:** keep File, Edit, Appearance, Window, and Help after the app
  menu. File contains New Chat, New Note, New Browser Tab, Start/Stop Dictation,
  and Refresh Workspace. Route creation through the active workspace's existing
  flows. Preserve native Undo/Redo and clipboard commands in Edit; keep theme and
  sidebar layout in Appearance. Do not add a separate View or Workspace menu.
  Keep Window for native close, minimize, zoom, layout, and window-switching
  controls. Harness setup belongs in Settings. Disable macOS window tabbing so
  Window does not offer tab-management commands; in-app browser tabs are separate.
- **Colors and geometry:** use `DashboardTheme`, `DashboardPalette`,
  `DashboardMetrics` in [DashboardStyle.swift](../app/App/Views/DashboardStyle.swift),
  and desktop `DashboardShapes` in `DashboardDesign.swift`. Preserve the
  Green and Cognac light themes. Dark uses warm charcoal, forest-tinted rails,
  cream text, and lighter green/Cognac accents from shared `DashboardColors`.
  The selected theme controls native appearance on macOS, iPhone, and iPad.
  Filled primary actions retain British Racing Green. Keep spacing, radii, and
  surface treatments consistent with adjacent screens; keep exact values in code.
- **Typography:** use the macOS system font and the existing size/weight
  hierarchy. Use monospaced text for code and monospaced digits for aligned
  numeric displays.
- **Text links:** use `DashboardPalette.success` (`#0D8F5A`) for conversation
  Markdown links and SwiftUI external-link labels so they stand out against the
  body text. The shared token supplies lighter green in Dark.
- **Composer selectors:** use title-case popout headings, such as `Thinking Level`,
  without all-caps styling or expanded letter spacing. Keep saved-default actions
  out of the conversation selector popouts. Composer model buttons show only the
  model name and version; connection attribution belongs in the model popout.
  Permission menus use each harness's own mode names, except that every
  harness's full mode is shown as Full access. List Full access first (the
  default everywhere), then the harness's auto-approve modes, then its other
  modes, with ask-for-approval last.
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
  styles in `DashboardStyle.swift` and `DashboardDesign.swift`, and the page/row
  patterns in
  [SettingsComponents.swift](../app/App/Views/SettingsComponents.swift).
  Preserve intentional differences such as borderless Usage sections.
- **Mobile Quick Chat:** name the device conversation feature **Quick Chat**,
  with **Powered by Pi Durable** in its setup explanation. Mac/Linux agents retain
  their harness names. On the mobile home page and in the New Chat menu Quick
  Chat comes first and the workspaces follow it, each once under its own name.
  A message sent to a Mac or Linux session shows at once with quiet caption
  progress ("Sending to …", "Starting on …"), never a spinner. Home, Folders, New Chat and Calendar list only paired
  Mac and Linux workspaces that are reachable now; Settings → Workspaces keeps
  every saved workspace with its connection state. Never add an "Unavailable
  workspace" group: folders whose workspace is not listed stay in All Workspaces.
  Web search keys (Exa, Brave Search, Firecrawl) live in Settings → Accounts with
  the model providers. Do not add data-sharing prompts:
  connecting a provider is the user's choice to use it.
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
  the app. Order the main Settings page as General, Permissions & Access, Accounts,
  Agents, Bots, Woven MCP, Workspaces, Apple Devices, Background Server, then
  Dictation. Accounts, Permissions & Access, Woven MCP, and Bots return to the page
  whose link opened them.
- **General:** Appearance, Software, and Privacy only. Other settings live on the
  page for what they affect.
- **Bots:** the Bots section sits above New chat in the navigation rail, using the
  rail's own disclosure headings and rows; with bots on more than one machine, each
  machine gets its own "Bots on <name>" heading. A bot's row shows only its name and
  opens its main channel; a chevron reveals its threads, pinned first and then newest
  created. Thread dropdowns start closed. Everything about bots is native and uses the
  components regular chats and Settings use: the shared transcript text, user bubble and
  composer, and Settings sections and rows. A thread sits beside its bot's main channel
  at 760 points and wider. Message actions appear on hover. **Settings → Bots** holds
  this Mac's switch, the machine list, Install on another device, and version notices
  with "Update everything". Each machine opens its own page: a status row with a Manage
  menu, then summary links to Profiles, Bots and teams, and Resources. Profiles and
  bots are summary rows that open for editing. Bots' Woven MCP access lives in
  Settings → Woven MCP; Bots shows it as one summary link. Apple Devices shows only a
  version status link to Bots. Bots use the accounts in Settings → Accounts; there is
  no separate bot sign-in.
- **Harness setup:** use compact rows grouped on the theme-whisper surface for
  both harness installation and Pi Durable setup, with the same typography,
  padding, inset dividers, and quiet actions. Keep provider setup limited to
  OpenAI, Anthropic, Grok, OpenRouter, and OpenCode; web-search setup shows only
  the Exa key form. Both are optional and also accessible from Settings → Accounts.
- **Accounts:** provider sign-ins, API keys, web search keys, and local model servers
  have one home, **Settings → Accounts**, used by both Pi Durable and Usage. Each
  provider is one summary row showing what is connected. Choose the web search
  provider on its row, beside its key. A new account offers Choose chat models, and
  connecting one in the shared scope turns on its limit checks. Keep the Accounts
  for selector visible, since saved workspace accounts take priority and must stay reachable. Native harnesses sign
  in on their own agent pages.
- **Agent setup:** Pi Durable links to Accounts, then shows Models, Defaults for new
  chats, and More. Models holds the default model, In the composer, and Fallbacks. Add
  models opens the provider catalog with its filters and paging in a sheet. Guided
  setup opens that sheet after a successful sign-in or key addition.
- **Usage:** limits show each saved account and signed-out providers, with Manage
  accounts. Device analytics never depends on limits-account switches or credentials.
- **Tool defaults:** settings say Woven MCP and show effective defaults,
  rather than an off-looking inheritance switch. Composer controls retain Tools.
  **Settings → Woven MCP** holds tool defaults, connected apps, bots, and outside
  agents; agent pages show one Woven MCP summary row for their own defaults.
- **Permissions & Access:** Keychain and every macOS permission Woven Matter uses
  live on this one Settings page, directly after General. It opens with one sentence:
  agents on this Mac or the user's other devices stop at a prompt here without
  these permissions. Everything is one section: a header with how many are not
  allowed yet and one **Allow all** button, then one row per permission with its
  System Settings name, one short line, and a quiet "Allowed" check or its own
  **Allow** button. Allow all brings up each prompt in turn with no steps, Skip or
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
  Save remote agents in the workspace database when installed and show them on
  launch, including while disconnected or awaiting sign-in. Background readiness
  checks gate execution, never sidebar membership.
- **Harness accounts:** sign-in belongs to each harness settings page, scoped to
  Local workspace or a named remote workspace. Workspace inventory shows status and links
  to that scoped page. Never label credentials present as verified sign-in.
  New remote workspaces offer skippable, reopenable setup with only Pi Durable
  selected by default; additional installations retain installer source review.
- **Chat defaults:** use Defaults for new chats on every harness page. Group
  thinking level and permissions together, with one short explanation.
- **Agent pages:** one page with no area switcher: Account and software, then Defaults
  for new chats, using the same layout for every harness. Pages have one Applies to
  selector, hidden when there is no remote workspace or local override. Keep Use shared
  chat settings inside Defaults for new chats. Changing chat inheritance must not
  change credential selection. Workspace Pi Durable accounts take priority per provider,
  with shared accounts as fallback; show their source and labels. Explain native
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
- **Icons:** use the existing `DashboardLucideIcon` glyphs and bundled harness
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
- **Sidebar foregrounds:** use `DashboardPalette.foreground` (`#0A1F16` in Green and Cognac, cream in Dark) for text and interface icons in both rails, including section headings, metadata, and pinned indicators. Keep colored agent/harness logos in their original colors; monochrome marks use a contrasting foreground in Dark. Shared controls use the sidebar foreground environment only inside the rails.
- **Workspace naming:** use Local workspace and Remote workspaces in the sidebar,
  and Workspaces and Apple Devices for Settings pages.
  Describe local workspaces as agents and files on this Mac, remote workspaces as
  agents and files on remote Linux machines, and Apple devices as Macs, iPhones,
  and iPads that share the library.
- **Workspaces:** one list with the local workspace as a status row, remote workspaces
  as rows that open their detail, and workspaces from other devices. Forms for adding
  a workspace open from Add workspace. A remote workspace shows status with a Manage
  menu, its agents, and Details; do not lay actions out as a strip of buttons.
  Dev workspaces include `(Dev)` and their instance name. Hide retained snapshot
  owners and stopped Dev connections from the active inventory.
- **Apple devices:** show this Mac, pairing requests, and paired devices, then Pair a
  device with its three methods closed until needed. Pairing grants access to all
  available workspaces; do not add per-device workspace permissions or
  execution-sharing switches.
- **Workspace sidebar:** group Agents and Folders within each owning workspace.
  Pinned agents and folders lead their respective lists without a separate Pinned
  section. Each Folders section starts with New folder, scoped to that workspace.
  Remote workspace names align with the local workspace heading; both use the same
  child indentation. All Workspaces sits above the workspaces, Trash below them,
  and Recents remains global. Never add an Unassigned workspace section: folderless
  chats appear in All Workspaces and still have an execution owner. Folder hover cards match chat previews and show the
  workspace, chat/note counts, root directory, and additional reference directories.
- **Sidebar headers:** in Single and Adaptive layouts, mirror the header button
  order when the sidebar moves to the right, and point the workspace back arrow
  toward the navigation rail. Keep titles and list content in normal reading order.
- **Switches:** settings pages use `SettingsSwitchToggleStyle`, with the switch on the right edge of its row like every other control. Elsewhere, use `DashboardSwitchToggleStyle` for boolean controls and multi-select toggles. It supplies compact native switches in a 28 × 16-point control frame before their labels on the left, in the shared forest-green action color and is the default at the app root. iPhone Tools popouts keep native switches at 65% scale inside 44 × 44-point touch frames, with labels on the left and padding around the scroll content. Markdown task-list markers remain document content.
- **Interaction:** keep controls compact, selection fills restrained, and focus
  styling quiet. Popover and sheet text inputs use `dashboardQuietTextInput()`
  for a neutral border without a colored focus ring. Clicking noninteractive
  content inside a form releases text focus without closing it.
  Shared controls distinguish enabled hover, press, selection,
  and disabled states without making quiet or icon actions look primary. Do not
  add persistent colored focus rings. Preserve keyboard navigation and accessible
  labels and states, and respect Reduce Motion and Reduce Transparency.
- **Text inputs:** use `DashboardSearchField` for search and `.dashboardInput()` for
  new text/secure fields, including desktop settings. These use
  plain native editing on the theme-whisper surface, matching sidebar chat search.
  Never use `.textFieldStyle(.roundedBorder)`, native blue focus outlines, or a
  custom bright focus border on app forms. Do not disable focus or keyboard
  navigation to hide a ring. Inspect both focused and unfocused states in Green,
  Cognac, and Dark, including secure fields and pairing dialogs. Native system dialogs
  and document content are outside this rule.
- **Dark content:** apply the theme to app-owned surfaces, including native
  editors, tables, charts, sheets, and popovers. Adapt note ink and highlights
  for readability without saving display colors into document formatting.
  Preserve colored harness logos, webpages, and authored HTML; do not inject recoloring
  or inversion into their content.
- **Notes:** keep the header controls in this order from left to right: Undo,
  Redo, Version history, Database, Format note, Microphone. Use the same compact
  icon button style and frames for the microphone and adjacent controls, without
  a divider. The note-body count sits at the bottom right, starts with words, and
  switches between words and characters when clicked. Keep it in one compact
  24-point bottom gutter outside the scrolling text, without stacking additional
  editor or footer padding beneath the note. Align the count button's right
  edge with the header controls using the same 12-point side inset.
- **Conversation progress:** use the shared elapsed work header and static semantic
  icons with meaningful live text. Do not show busy spinners in tool-call rows,
  work-group headers, reasoning indicators, or tool-detail loading. Thinking and
  assistant messages stay visible in chronological order, including after a run
  completes. Live tool calls append as separate rows in the conversation; never
  replace the preceding tool with the latest call. A new thinking, commentary,
  or other standalone event condenses only the preceding tool list into a
  reopenable disclosure. Show supplied subagent rows at their event position.
  Preserve the reader's position; follow new work
  or reasoning only from the live edge. Between a tool and the next visible output,
  use a static Thinking label. Keep detail-loading text quiet ("Loading details…")
  and never add a separate mobile running spinner below the transcript.
- **Scrolling:** hide scrollbars throughout the app while preserving scrolling. Set
  `.scrollIndicators(.never)` on SwiftUI scroll views and editors, including
  sheets and popovers. Disable both scrollers on AppKit `NSScrollView` editors.
- **Layout:** use the existing sidebar, chat-panel, and compact/expanded composer
  patterns. Check affected views at narrow and wide widths and respect Reduce
  Motion and Reduce Transparency.

Compare rendered changes with the existing screen or supplied design reference.
Code cleanup alone should not alter appearance or interaction.

## iPhone and iPad

Both Xcode targets compile `app/App/Views/DashboardStyle.swift` and bundle
`app/App/SharedAssets.xcassets`. These are the canonical Lucide glyphs, harness
logos, Green/Cognac/Dark palettes, radii, search field, segmented selectors, and
primary/quiet/icon buttons.
Do not copy the icon catalog or introduce a parallel mobile palette. Desktop
runtime metadata and window-specific controls remain in `DashboardDesign.swift`.

The companion keeps Dynamic Type and a 44-point minimum for shared touch controls;
desktop sizing is unchanged. Dark uses the same shared palette on both platforms. Native sheets, pickers, switches, QR scanning and share controls retain
iOS behavior. SF Symbols used by desktop for spreadsheet/HTML/file kinds, text
formatting, and status controls remain deliberate exceptions to Lucide.
