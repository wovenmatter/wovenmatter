# Woven Matter UI style guide

Match the existing app and reuse its shared components. Keep this guide current
when an intentional design change is accepted.

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
- **Agent naming:** use **Pi Durable** for the agent in navigation, settings,
  conversation labels, and actions. Use **Pi Durable SDK** for the underlying SDK
  in technical descriptions and version/update controls. Keep the agent name
  stable across model and provider changes.
- **Harness setup:** use compact rows grouped on the theme-whisper surface for
  both harness installation and Pi Durable setup, with the same typography,
  padding, inset dividers, and quiet actions. Keep provider setup limited to
  OpenAI, Anthropic, Grok, OpenRouter, and OpenCode; web-search setup shows only
  the Exa key form. Both are optional and also accessible from Pi Durable settings.
- **Agent setup:** Pi Durable uses the same grouped provider rows as Harness setup,
  inline below SDK management. Web search follows accounts, then the model browser
  and its single default-model choice. Successful sign-in/key addition opens that
  provider's model browser. Fallback ordering and workspace overrides are disclosures.
- **Usage:** account setup lives in Usage settings. Limits show each saved account
  and signed-out providers, with Go to Usage settings. Device analytics never depends
  on limits-account switches or credentials.
- **Tool defaults:** settings say Woven Matter CLI and show effective defaults,
  rather than an off-looking inheritance switch. Composer controls retain Tools.
- **Keychain:** General uses Keychain access, Enable/Restore Keychain access,
  Access ready, and Access needs attention. Keep one storage sentence, a status
  pill, and an action; show the Always Allow hint only when access is not ready.
  Consent is not verification.
- **Harness lists:** local and remote workspaces use compact expandable harness
  rows. Keep versions and labeled maintenance controls inside the expanded row,
  rather than a horizontal strip of actions. Remote workspaces have no global
  enable switch; saved workspaces reconnect using silent Keychain reads.
  Installed harnesses are available automatically in local and remote workspaces.
  Do not add harness enable/disable, Use harness, or per-harness sidebar visibility
  controls. Installation, sign-in, and connection status communicate readiness.
  Save remote agents in the workspace database when installed and show them on
  launch, including while disconnected or awaiting sign-in. Background readiness
  checks gate execution, never sidebar membership.
- **Harness accounts:** sign-in belongs to each harness settings page, scoped to
  Local agent workspace or a named remote workspace. Workspace inventory shows status and links
  to that scoped page. Never label credentials present as verified sign-in.
  New remote workspaces offer skippable, reopenable setup with only Pi Durable
  selected by default; additional installations retain installer source review.
- **Chat defaults:** use Defaults for new chats on every harness page. Group
  thinking level and permissions together, with one short explanation.
- **Harness settings areas:** separate Accounts & installation from Chat settings.
  Use DashboardSegmentedSelector for the area control so padding, hover, press,
  and accessibility behavior match Sidebar layout. Use the quiet standard selection
  in Dark; retain the existing primary selection color in Green and Cognac.
  Give accounts their own Local agent workspace / named remote workspace selector;
  only Pi Durable exposes Shared Pi Durable accounts. Keep chat inheritance controls
  inside Chat settings, never above accounts or software. Changing chat inheritance
  must not change credential selection. Workspace Pi Durable accounts take priority
  per provider, with shared accounts as fallback; show their source and labels.
  Explain native harness capability differences in the Account sharing disclosure:
  reusable API keys are not the same as automatic credential sync, and native
  subscription sign-ins stay with their installation. Never show key/token values
  or infer names that a harness does not expose.
- **Pi Durable updates:** use the same compact runtime row as other harnesses:
  logo, harness name, embedded SDK versions on one summary line, installed status,
  and one Check for updates / Update action per
  workspace. Update all outdated components in one staged activation. Shared scope
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
  OpenAI, Anthropic, and Grok retain separate subscription and API-key groups.
  Each subscription group shows one account with Reconnect/Remove, without
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
- **Switches:** use `DashboardSwitchToggleStyle` for boolean controls and multi-select toggles. It supplies compact native switches in a 28 × 16-point control frame before their labels on the left, in the shared forest-green action color and is the default at the app root. iPhone Tools popouts keep native switches at 65% scale inside 44 × 44-point touch frames, with labels on the left and padding around the scroll content. Markdown task-list markers remain document content.
- **Interaction:** keep controls compact, selection fills restrained, and focus
  styling quiet. Popover and sheet text inputs use `dashboardQuietTextInput()`
  for a neutral border without a colored focus ring. Clicking noninteractive
  content inside a form releases text focus without closing it.
  Shared controls distinguish enabled hover, press, selection,
  and disabled states without making quiet or icon actions look primary. Do not
  add persistent colored focus rings. Preserve keyboard navigation and accessible
  labels and states, and respect Reduce Motion and Reduce Transparency.
- **Text inputs:** use `DashboardSearchField` for search, `.dashboardInput()` for
  new text/secure fields, and `.settingsInput()` in desktop settings. These use
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
- **Conversation progress:** use the shared elapsed work header. A collapsed
  live tool group shows progress once; expanding it moves the indicator to its
  active tool rows. Keep detail-loading text quiet and avoid a separate mobile
  running spinner below the transcript.
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
