#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_file="${repo_root}/app/App/Views/WorkspaceView.swift"
design_file="${repo_root}/app/App/Views/DashboardDesign.swift"
settings_file="${repo_root}/app/App/Views/SettingsGeneralView.swift"
app_file="${repo_root}/app/App/WovenMatterApp.swift"
model_file="${repo_root}/app/App/ApplicationModel.swift"

rail_source="$(sed -n '/^private struct DashboardSidebarRail: View {$/,/^    private var scopedConversations:/p' "$workspace_file")"
rail_rendering="$(
  sed -n '/^    var body: some View {$/,/^    private var navigationPage:/p' <<<"$rail_source" \
    | sed '$d'
)"
navigation_state="$(sed -n '/^struct DashboardSidebarNavigationState:/,/^struct DashboardPalette/p' "$design_file")"
sidebar_style="$(sed -n '/^enum DashboardSidebarStyle:/,/^enum DashboardSidebarSide:/p' "$design_file")"
rail_group="$(sed -n '/^    private func railGroup(/,/^    private func rail(/p' "$workspace_file")"
folder_selection="$(sed -n '/^    private func selectFolder(/,/^    private func selectConversation(/p' "$workspace_file")"
sidebar_back="$(sed -n '/^    private func showSidebarNavigation()/,/^    private func centerSurface(/p' "$workspace_file")"

require_rail_source() {
  local needle="$1"
  if ! printf '%s\n' "$rail_rendering" | grep -Fq "$needle"; then
    printf 'Sidebar page contract is missing: %s\n' "$needle" >&2
    exit 1
  fi
}

require_navigation_source() {
  local needle="$1"
  if ! printf '%s\n' "$navigation_state" | grep -Fq "$needle"; then
    printf 'Sidebar navigation contract is missing: %s\n' "$needle" >&2
    exit 1
  fi
}

# A rail owns one visual page. Keeping both complete trees in a ZStack allows
# translucent sidebar materials to reveal overlapping headers, controls, and rows.
require_rail_source 'switch page {'
require_rail_source 'case .navigation:'
require_rail_source 'navigationPage'
require_rail_source 'case .workspace:'
require_rail_source 'workspacePage'

if printf '%s\n' "$rail_rendering" | grep -Eq 'ZStack|allowsHitTesting|accessibilityHidden'; then
  printf '%s\n' 'Sidebar rail must render one page, not stack or hide complete page trees.' >&2
  exit 1
fi

test "$(printf '%s\n' "$rail_rendering" | grep -Fc 'navigationPage')" -eq 1
test "$(printf '%s\n' "$rail_rendering" | grep -Fc 'workspacePage')" -eq 1

# The public selector order and labels are deliberate. Existing raw values and
# the storage key remain stable so stored Single/Split choices survive the new case.
test "$(
  printf '%s\n' "$sidebar_style" \
    | sed -n '/^enum DashboardSidebarStyle:/,/^    static let storageKey/p' \
    | grep -E '^    case (adaptive|single|split)$' \
    | awk '{print $2}' \
    | paste -sd ' ' -
)" = 'adaptive single split'
printf '%s\n' "$sidebar_style" | grep -Fq 'static let storageKey = "wovenmatter.dashboard.sidebar-style"'
printf '%s\n' "$sidebar_style" | grep -Fq 'static let defaultStyle = DashboardSidebarStyle.split'
printf '%s\n' "$sidebar_style" | grep -Fq 'case .adaptive: "Adaptive Sidebar"'
printf '%s\n' "$sidebar_style" | grep -Fq 'case .single: "Single Sidebar"'
printf '%s\n' "$sidebar_style" | grep -Fq 'case .split: "Split Sidebar"'
grep -Fq 'options: DashboardSidebarStyle.allCases' "$settings_file"
grep -Fq \
  '@AppStorage(DashboardSidebarStyle.storageKey) private var storedSidebarStyle = DashboardSidebarStyle.defaultStyle.rawValue' \
  "$settings_file"
grep -Fq \
  '@AppStorage(DashboardSidebarStyle.storageKey) private var sidebarStyleRawValue = DashboardSidebarStyle.defaultStyle.rawValue' \
  "$workspace_file"
grep -Fq \
  '@AppStorage(DashboardSidebarStyle.storageKey) private var sidebarStyleRawValue = DashboardSidebarStyle.defaultStyle.rawValue' \
  "$app_file"
grep -A2 -F 'DashboardSidebarStyle.storageKey,' "$model_file" \
  | grep -Fq 'fallback: DashboardSidebarStyle.defaultStyle.rawValue'

# Adaptive starts with navigation only, expands after folder selection, and Back
# closes only its workspace page. Single keeps its in-place page replacement.
require_navigation_source 'private(set) var singlePage = DashboardSidebarPage.navigation'
require_navigation_source 'private(set) var adaptiveWorkspaceVisible = false'
require_navigation_source 'singlePage = .workspace'
require_navigation_source 'adaptiveWorkspaceVisible = true'
require_navigation_source 'singlePage = .navigation'
require_navigation_source 'adaptiveWorkspaceVisible = false'
require_navigation_source 'case .adaptive:'
require_navigation_source 'guard adaptiveWorkspaceVisible else { return [.navigation] }'
require_navigation_source '? [.navigation, .workspace]'
require_navigation_source ': [.workspace, .navigation]'
require_navigation_source 'case .single:'
require_navigation_source 'return [singlePage]'
require_navigation_source 'case .split:'
require_navigation_source 'return [side == .left ? .navigation : .workspace]'

printf '%s\n' "$folder_selection" | grep -Fq 'selectedFolderID = id'
printf '%s\n' "$folder_selection" | grep -Fq 'sidebarNavigation.selectFolder()'
printf '%s\n' "$sidebar_back" | grep -Fq 'sidebarNavigation.showNavigation()'
sed -n '/^        \.onChange(of: sidebarStyleRawValue)/,/^        \.onChange(of: singleSidebarSideRawValue)/p' \
  "$workspace_file" | grep -Fq 'compactDrawer = .none'

# Adaptive renders the ordered pages as touching, fixed-width sibling rails on
# the configured side. The right-side ordering above keeps navigation outermost.
printf '%s\n' "$rail_group" | grep -Fq \
  'HStack(spacing: sidebarStyle == .adaptive ? 0 : DashboardMetrics.shellGap)'
printf '%s\n' "$rail_group" | grep -Fq \
  'ForEach(sidebarNavigation.pages(for: side, style: sidebarStyle), id: \.self)'
printf '%s\n' "$rail_group" | grep -Fq 'rail(side: side, page: page)'
sed -n '/^    private func desktopShell(/,/^    private func compactShell(/p' "$workspace_file" \
  | grep -Fq 'railGroup(side: .left)'
sed -n '/^    private func desktopShell(/,/^    private func compactShell(/p' "$workspace_file" \
  | grep -Fq 'railGroup(side: .right)'

# The shared workspace surface supplies Back to Single and Adaptive while Split
# keeps its established controls.
printf '%s\n' "$rail_source" | grep -Fq \
  'onBack: style == .split ? nil : actions.onShowNavigation'

printf '%s\n' 'Sidebar adaptive, single-page, and split-layout contracts passed.'
