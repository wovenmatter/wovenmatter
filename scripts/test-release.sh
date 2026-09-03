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
grep -Fq '.agents/skills/cut-release-wovenmatter/SKILL.md' AGENTS.md
grep -Fq "'v[0-9]+.[0-9]+.[0-9]+'" .github/workflows/release.yml
grep -Fq 'scripts/build-release.sh "$version"' .github/workflows/release.yml
grep -Fq 'OTHER_CODE_SIGN_FLAGS="--timestamp"' scripts/build-release.sh
grep -Fq 'refusing to replace published assets' .github/workflows/release.yml
grep -Fq 'if [[ "$is_draft" != "true" ]]' .github/workflows/release.yml
grep -Fq 'test "$actual" = "$expected"' .github/workflows/release.yml
! grep -Fq -- '--draft=false' .github/workflows/release.yml
test ! -e .github/workflows/publish-release.yml
bash -n scripts/publish-release.sh
grep -Fq 'remote_actor="${BASH_REMATCH[1]}"' scripts/publish-release.sh
grep -Fq 'test "$actor" = "$remote_actor"' scripts/publish-release.sh
grep -Fq 'test "$push_remote" = "$fetch_remote"' scripts/publish-release.sh
grep -Fq 'git merge-base --is-ancestor "$expected_sha" origin/main' scripts/publish-release.sh
grep -Fq 'test "$is_draft" = "true"' scripts/publish-release.sh
grep -Fq 'test "$actual_assets" = "$expected_assets"' scripts/publish-release.sh
grep -Fq 'source=Notarized Developer ID' scripts/publish-release.sh
grep -Fq 'gh release edit "$tag" --repo "$repository" --draft=false' scripts/publish-release.sh
if scripts/publish-release.sh invalid-tag deadbeef >/dev/null 2>&1; then
  printf '%s\n' 'Invalid release publication input was accepted.' >&2
  exit 1
fi
printf '%s\n' 'Release contract validation passed.'
