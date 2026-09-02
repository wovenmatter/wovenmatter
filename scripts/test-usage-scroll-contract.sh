#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_file="${repo_root}/app/App/Views/DashboardUsageView.swift"

usage_body="$(sed -n '/^    var body: some View {$/,/^        \.task {$/p' "$source_file")"
if printf '%s\n' "$usage_body" | grep -Eq 'ScrollViewReader|\.onChange\(of: page\)|scrollTo\('; then
  printf '%s\n' 'Usage page selection must not programmatically change vertical scroll position.' >&2
  exit 1
fi

page_binding="$(sed -n '/^    private var pageBinding:/,/^    var body: some View {$/p' "$source_file")"
printf '%s\n' "$page_binding" | grep -Fq 'await model.usageAnalyticsSelected(range: range)'

printf '%s\n' 'Usage page scroll-position contract passed.'
