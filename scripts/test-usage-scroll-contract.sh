#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="${repo_root}/app/App/Views/DashboardUsageView.swift"
model_file="${repo_root}/app/App/ApplicationModel.swift"

usage_body="$(sed -n '/^    var body: some View {$/,/^        \.task {$/p' "$source_file")"
if printf '%s\n' "$usage_body" | grep -Eq 'ScrollViewReader|\.onChange\(of: page\)|scrollTo\('; then
  printf '%s\n' 'Usage page selection must not programmatically change vertical scroll position.' >&2
  exit 1
fi

page_binding="$(sed -n '/^    private var pageBinding:/,/^    var body: some View {$/p' "$source_file")"
printf '%s\n' "$page_binding" | grep -Fq 'await model.usageAnalyticsSelected(range: range)'

accounts_body="$(sed -n '/private func accountConnections/,/private func limitCard/p' "$source_file")"
printf '%s\n' "$accounts_body" | grep -Fq 'ProviderKind.supportedAccounts.map'
printf '%s\n' "$accounts_body" | grep -Fq 'ViewThatFits(in: .horizontal)'
printf '%s\n' "$accounts_body" | grep -Fq 'GridItem(.flexible(), alignment: .topLeading)'
printf '%s\n' "$accounts_body" | grep -Fq 'limitCard(account, pinsFooter: true)'
printf '%s\n' "$accounts_body" | grep -Fq 'limitCard(account, pinsFooter: false)'

limit_card_body="$(sed -n '/private func limitCard/,/private var openRouterCredentialControls/p' "$source_file")"
printf '%s\n' "$limit_card_body" | grep -Fq 'account.provider == .openRouter'
printf '%s\n' "$limit_card_body" | grep -Fq 'openRouterCredentialControls'
printf '%s\n' "$limit_card_body" | grep -Fq 'if pinsFooter { Spacer(minLength: 12) }'
printf '%s\n' "$limit_card_body" | grep -Fq 'maxHeight: pinsFooter ? .infinity : nil'
printf '%s\n' "$limit_card_body" | grep -Fq 'model.codexUsageWorkspaces.count > 1'

codex_workspace_selector="$(sed -n '/private var codexWorkspaceSelector/,/private var selectedCodexWorkspace/p' "$source_file")"
printf '%s\n' "$codex_workspace_selector" | grep -Fq 'Text(selectedCodexWorkspace?.name ?? "Choose workspace")'
printf '%s\n' "$codex_workspace_selector" | grep -Fq '.menuStyle(.borderlessButton)'
printf '%s\n' "$codex_workspace_selector" | grep -Fq '.disabled(model.isRefreshingUsageLimits)'
if printf '%s\n' "$codex_workspace_selector" | grep -Fq 'Image(systemName: "chevron.up.chevron.down")'; then
  printf '%s\n' 'Codex workspace picker must use only the borderless Menu dropdown indicator.' >&2
  exit 1
fi

grep -Fq 'await model.selectCodexUsageWorkspace(' "$source_file"
grep -Fq 'model.reconnectSelectedCodexUsageWorkspace()' "$source_file"
grep -Fq 'environment["CODEX_HOME"] = homeDirectory.path' "$model_file"

explicit_claude_count="$(grep -Fc 'explicitCredentialAccess: provider == .claude' "$model_file")"
test "$explicit_claude_count" -eq 3

printf '%s\n' 'Usage page layout and scroll-position contract passed.'
