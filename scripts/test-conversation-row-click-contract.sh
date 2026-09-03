#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="${repo_root}/app/App/Views/WorkspaceView.swift"

row_source="$(sed -n '/^private struct DashboardConversationRow: View {$/,/^\/\/\/ Hover pop-out for a workspace chat row/p' "$source_file")"
state_source="$(sed -n '/^struct DashboardConversationDetailCardState:/,/^struct DashboardConversationRowAccessibility:/p' "$source_file")"
list_source="$(sed -n '/^private struct DashboardSidebarWorkspacePage: View {$/,/^private struct DashboardRightRailContentTaskID:/p' "$source_file")"

require_row_source() {
  local needle="$1"
  if ! printf '%s\n' "$row_source" | grep -Fq "$needle"; then
    printf 'Conversation row click contract is missing: %s\n' "$needle" >&2
    exit 1
  fi
}

require_row_source 'Button {'
require_row_source 'action()'
require_row_source 'detailCardState.completePrimaryAction('
require_row_source 'guard !Task.isCancelled, hovered, !Self.isMouseButtonPressed else { return }'
require_row_source '} else if !Self.isMouseButtonPressed {'
require_row_source 'guard !Self.isMouseButtonPressed else { return }'
require_row_source 'NSEvent.pressedMouseButtons != 0'
require_row_source '.frame(maxWidth: .infinity, alignment: .leading)'
require_row_source '.contentShape(RoundedRectangle('
require_row_source '.popover(isPresented: detailCardPresented, arrowEdge: .trailing)'
require_row_source '.contextMenu {'

if printf '%s\n' "$row_source" | grep -Eq '\.(gesture|onTapGesture|simultaneousGesture|highPriorityGesture)\('; then
  printf '%s\n' 'Conversation rows must keep native Button activation without competing gestures.' >&2
  exit 1
fi

printf '%s\n' "$state_source" | grep -Fq \
  'mutating func completePrimaryAction(conversationID: String, hovered: Bool)'
printf '%s\n' "$state_source" | grep -Fq 'focusedConversationID = conversationID'
printf '%s\n' "$state_source" | grep -Fq 'hoveredConversationID = hovered ? conversationID : nil'

if [ "$(printf '%s\n' "$list_source" | grep -Fc 'conversationRow(presentation)')" -ne 2 ]; then
  printf '%s\n' 'Pinned and Recents lists must share the stable conversation row.' >&2
  exit 1
fi

printf '%s\n' 'Conversation row click contract passed.'
