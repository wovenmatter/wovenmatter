#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
asset="${temporary}/WovenMatter_0.1.0_arm64.dmg"
printf 'fixture\n' > "$asset"
scripts/generate-release-manifest.sh 0.1.0 1 "$asset" "${temporary}/latest-mac.json"

jq -e '
  .schema_version == 1
  and .version == "0.1.0"
  and .build == 1
  and .architecture == "arm64"
  and .minimum_macos == "26.0"
  and .download_url == "https://github.com/wovenmatter/wovenmatter/releases/download/v0.1.0/WovenMatter_0.1.0_arm64.dmg"
  and .release_url == "https://github.com/wovenmatter/wovenmatter/releases/tag/v0.1.0"
  and (.sha256 | test("^[0-9a-f]{64}$"))
' "${temporary}/latest-mac.json" >/dev/null

grep -Fq 'WovenMatter_X.Y.Z_arm64.dmg' docs/MAINTAINER_WORKFLOW.md
grep -Fq "'v[0-9]+.[0-9]+.[0-9]+'" .github/workflows/release.yml
grep -Fq 'scripts/build-release.sh "$version"' .github/workflows/release.yml
printf '%s\n' 'Release contract validation passed.'
