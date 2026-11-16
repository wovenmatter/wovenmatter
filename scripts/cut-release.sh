#!/usr/bin/env bash
# Cuts a release from this Mac: builds the Linux library binaries on a Docker
# host, compiles the Release app here, uploads it to the private draft and pushes
# the tag. The tag starts .github/workflows/release.yml, which signs, notarizes and
# packages that exact app. Publication stays behind scripts/publish-release.sh.
#
# Usage: scripts/cut-release.sh X.Y.Z
# WOVENMATTER_LINUX_BUILD_HOST: SSH host with Docker for the Linux library
# (default: workstation). Set it to "local" to use Docker on this machine.
set -euo pipefail

version="${1:?usage: scripts/cut-release.sh X.Y.Z}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Version must be X.Y.Z.' >&2; exit 64; }
tag="v$version"
linux_host="${WOVENMATTER_LINUX_BUILD_HOST:-workstation}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"
started=$SECONDS
step() { printf '\n==> [%dm%02ds] %s\n' $(((SECONDS - started) / 60)) $(((SECONDS - started) % 60)) "$1"; }

step 'Checking GitHub access and source'
export GH_HOST=github.com GH_PROMPT_DISABLED=1 GH_BROWSER=/usr/bin/false
scripts/check-release-access.sh
git fetch --no-tags origin main
revision="$(git rev-parse HEAD)"
test "$revision" = "$(git rev-parse origin/main)" \
  || { echo 'Check out current origin/main to cut a release.' >&2; exit 65; }
[ -z "$(git status --porcelain)" ] || { echo 'The checkout must be clean.' >&2; exit 65; }
build="$(git rev-list --count HEAD)"
remote_tag="$(git ls-remote --tags origin "refs/tags/$tag^{}" | cut -f1)"
[ -z "$remote_tag" ] || { echo "$tag already exists at $remote_tag." >&2; exit 65; }
if gh release view "$tag" --json isDraft --jq .isDraft >/dev/null 2>&1; then
  gh release view "$tag" --json isDraft --jq .isDraft | grep -qx true \
    || { echo "$tag is already public." >&2; exit 65; }
fi
echo "Releasing $tag (build $build) from $revision."

step "Building Linux library binaries on $linux_host"
rm -rf remote/host/library
if [ "$linux_host" = local ]; then
  scripts/build-linux-library.sh --docker
else
  remote_dir="$(ssh "$linux_host" mktemp -d)"
  git archive HEAD | ssh "$linux_host" "tar -x -C '$remote_dir'"
  ssh "$linux_host" "cd '$remote_dir' && scripts/build-linux-library.sh --docker --output '$remote_dir/out'"
  mkdir -p remote/host/library
  ssh "$linux_host" "tar -C '$remote_dir/out' -c ." | tar -x -C remote/host/library
  # Docker leaves root-owned output behind.
  ssh "$linux_host" "sudo rm -rf '$remote_dir'"
fi
scripts/verify-linux-library.sh

step 'Compiling the Release app'
work="${WOVENMATTER_RELEASE_WORK_DIR:-/private/tmp/wovenmatter-release-$version}"
output="$work/upload"
WOVENMATTER_SIGNING_IDENTITY=- WOVENMATTER_RELEASE_ALLOW_UNTAGGED=1 \
WOVENMATTER_RELEASE_WORK_DIR="$work" WOVENMATTER_RELEASE_OUTPUT_DIR="$work/dist" \
WOVENMATTER_COMPILER_CACHE="$HOME/Library/Caches/WovenMatter/ReleaseCompiler" \
WOVENMATTER_PACKAGE_CACHE="$HOME/Library/Caches/WovenMatter/SourcePackages" \
  scripts/build-release.sh "$version" compile
app="$work/DerivedData/Build/Products/Release/Woven Matter.app"
python3 scripts/validate-release-metadata.py verify "$version" "$build" "$revision" --plist "$app/Contents/Info.plist"
scripts/validate-native-app.sh "$app"

step 'Uploading the app to the private draft'
rm -rf "$output"
mkdir -p "$output"
ditto -c -k --keepParent "$app" "$output/WovenMatter-unsigned.zip"
jq -n --arg version "$version" --argjson build "$build" --arg revision "$revision" \
  --arg sha "$(shasum -a 256 "$output/WovenMatter-unsigned.zip" | cut -d' ' -f1)" \
  '{version: $version, build: $build, source_revision: $revision, sha256: $sha}' > "$output/unsigned-input.json"
if ! gh release view "$tag" >/dev/null 2>&1; then
  gh release create "$tag" --draft --target "$revision" --title "Woven Matter $tag" \
    --notes 'Signed and notarized Apple Silicon release.'
fi
gh release upload "$tag" "$output/WovenMatter-unsigned.zip" "$output/unsigned-input.json" --clobber

step "Pushing $tag to start signing and notarization"
git tag -a "$tag" "$revision" -m "Woven Matter $tag"
git push origin "refs/tags/$tag"
sleep 5
gh run list --workflow release.yml --branch "$tag" --limit 1 --json url --jq '.[0].url // "Release workflow starting."'
step 'Done. When the workflow succeeds, verify with:'
echo "scripts/publish-release.sh --verify-only $tag $revision"
