#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_file="${repo_root}/app/App/Views/WorkspaceView.swift"
design_file="${repo_root}/app/App/Views/DashboardDesign.swift"

rail_source="$(sed -n '/^private struct DashboardSidebarRail: View {$/,/^    private var scopedConversations:/p' "$workspace_file")"
rail_rendering="$(
  sed -n '/^    var body: some View {$/,/^    private var navigationPage:/p' <<<"$rail_source" \
    | sed '$d'
)"
navigation_state="$(sed -n '/^struct DashboardSidebarNavigationState:/,/^struct DashboardPalette/p' "$design_file")"

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

# Single mode follows explicit navigation state; split mode remains permanently
# mapped to navigation on the left and workspace content on the right.
require_navigation_source 'case .single:'
require_navigation_source 'singlePage'
require_navigation_source 'case .split:'
require_navigation_source 'side == .left ? .navigation : .workspace'

# The shared workspace surface keeps the single-sidebar Back affordance without
# changing split-sidebar controls.
printf '%s\n' "$rail_source" | grep -Fq \
  'onBack: style == .single ? actions.onShowNavigation : nil'

printf '%s\n' 'Sidebar single-page rendering and split-layout contract passed.'
