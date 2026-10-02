# Woven Matter UI style guide

Match the existing app and reuse its shared components. Keep this guide current
when an intentional design change is accepted.

- **Colors and geometry:** use `DashboardTheme`, `DashboardPalette`,
  `DashboardMetrics`, and `DashboardShapes` in
  [DashboardDesign.swift](../app/App/Views/DashboardDesign.swift). Preserve the
  Green and Cognac themes; keep spacing, radii, and surface treatments consistent
  with adjacent screens. Keep exact values in code.
- **Typography:** use the macOS system font and the existing size/weight
  hierarchy. Use monospaced text for code and monospaced digits for aligned
  numeric displays.
- **Text links:** use `DashboardPalette.success` (`#0D8F5A`) for conversation
  Markdown links and SwiftUI external-link labels so they stand out against the
  dark body text.
- **Composer selectors:** use title-case popout headings, such as `Thinking Level`,
  without all-caps styling or expanded letter spacing. Keep saved-default actions
  out of the conversation selector popouts. Composer model buttons show only the
  model name and version; connection attribution belongs in the model popout.
  Permission buttons use the fullest label that fits, then explicit shorter
  labels, then an icon. Never ellipsize these labels or collapse distinct modes
  such as Auto and Auto Accept into the same text. Popouts retain full labels
  and descriptions.
- **Components:** reuse the shared cards, selectors, search fields, and button
  styles in `DashboardDesign.swift`, and the page/row patterns in
  [SettingsComponents.swift](../app/App/Views/SettingsComponents.swift).
  Preserve intentional differences such as borderless Usage sections.
- **Built-in SDK settings:** place SDK management directly below the workspace
  scope controls. Each workspace has a disclosure row, collapsed by default,
  containing Pi SDK and Claude SDK versions and explicit check/update actions.
  All workspaces lists the local location and configured remote workspaces; an
  individual scope shows only that location. Keep progress and errors with their
  workspace and preserve operation state when a row is collapsed.
- **Icons:** use the existing `DashboardLucideIcon` glyphs and bundled harness
  logos, matching nearby icon sizes and stroke weights.
- **Calendar:** keep the four-item legend below the selected-day list. Use the
  saved category colors for event markers and recurrence labels. Default to
  British Racing Green events, royal blue scheduled tasks, purple recurring
  events, and Cognac recurring scheduled tasks. The picker offers Cognac, British
  Racing Green, lighter green, royal blue, purple, red, pink, orange, yellow, and
  black. Choices persist and may be reused across categories.
- **Sidebar foregrounds:** use `DashboardPalette.foreground` (`#0A1F16`) for text and interface icons in both rails, including section headings, metadata, and pinned indicators. Keep agent/harness logos in their original colors. Shared controls use the sidebar foreground environment only inside the rails.
- **Switches:** use `DashboardSwitchToggleStyle` for boolean controls and multi-select toggles. It supplies compact native switches in a 28 × 16-point control frame before their labels on the left, in the shared forest-green action color and is the default at the app root. Markdown task-list markers remain document content.
- **Interaction:** keep controls compact, selection fills restrained, and focus
  styling quiet. Shared controls distinguish enabled hover, press, selection,
  and disabled states without making quiet or icon actions look primary. Do not
  add persistent colored focus rings. Preserve keyboard navigation and accessible
  labels and states, and respect Reduce Motion and Reduce Transparency.
- **Scrolling:** hide scrollbars throughout the app while preserving scrolling. Set
  `.scrollIndicators(.never)` on SwiftUI scroll views and editors, including
  sheets and popovers. Disable both scrollers on AppKit `NSScrollView` editors.
- **Layout:** use the existing sidebar, chat-panel, and compact/expanded composer
  patterns. Check affected views at narrow and wide widths and respect Reduce
  Motion and Reduce Transparency.

Compare rendered changes with the existing screen or supplied design reference.
Code cleanup alone should not alter appearance or interaction.
