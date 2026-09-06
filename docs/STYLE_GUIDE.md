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
- **Components:** reuse the shared cards, selectors, search fields, and button
  styles in `DashboardDesign.swift`, and the page/row patterns in
  [SettingsComponents.swift](../app/App/Views/SettingsComponents.swift).
  Preserve intentional differences such as borderless Usage sections.
- **Icons:** use the existing `DashboardLucideIcon` glyphs and bundled harness
  logos, matching nearby icon sizes and stroke weights.
- **Interaction:** keep controls compact, selection fills restrained, and focus
  styling quiet. Do not add persistent colored focus rings. Preserve keyboard
  navigation and accessible labels and states.
- **Layout:** use the existing sidebar, chat-panel, and compact/expanded composer
  patterns. Check affected views at narrow and wide widths and respect Reduce
  Motion and Reduce Transparency.

Compare rendered changes with the existing screen or supplied design reference.
Code cleanup alone should not alter appearance or interaction.
