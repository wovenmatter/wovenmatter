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
- **Components:** reuse the shared cards, selectors, search fields, and button
  styles in `DashboardStyle.swift` and `DashboardDesign.swift`, and the page/row
  patterns in
  [SettingsComponents.swift](../app/App/Views/SettingsComponents.swift).
  Preserve intentional differences such as borderless Usage sections.
- **Agent naming:** use **Pi Durable** for the agent in navigation, settings,
  conversation labels, and actions. Use **Pi Durable SDK** for the underlying SDK
  in technical descriptions and version/update controls. Keep the agent name
  stable across model and provider changes.
- **Pi Durable SDK settings:** place SDK management directly below the workspace
  scope controls. The local workspace uses a fixed heading with Pi Durable SDK and Claude
  SDK versions and explicit check/update actions always visible. Remote workspaces
  use full-width disclosure buttons, collapsed by default, for the same controls.
  All workspaces lists the local location and configured remote workspaces; an
  individual scope shows only that location. Keep progress and errors with their
  workspace and preserve operation state when a remote row is collapsed.
- **Settings disclosures:** use `SettingsDisclosureGroupStyle` on the Connections
  page so the chevron, label, and remaining header width all toggle expansion.
  The style propagates to nested provider, credential, account, and Executor
  defaults disclosures.
  OpenAI, Anthropic, and Grok retain separate subscription and API-key groups.
  OpenRouter, OpenCode, and Exa show API-key controls directly when expanded.
  Keep their content and Cursor's controls at the same indentation as the content
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
  and Recents remains global. Folder hover cards match chat previews and show the
  workspace, chat/note counts, root directory, and additional reference directories.
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
