#!/usr/bin/env bash
# Cuts a release from this Mac in two steps.
#
#   scripts/cut-release.sh build X.Y.Z
#     Fresh worktree of current origin/main, production Release app compiled
#     here (ad-hoc signed; the compile also builds the Linux woven-server for
#     x86_64 and aarch64 into the app, and no Claude engine is bundled) and
#     checked. Uploads nothing.
#   scripts/cut-release.sh ship X.Y.Z
#     Uploads that exact build to the private draft and pushes the tag, which
#     starts .github/workflows/release.yml to sign, notarize and package it.
#
# Publication stays behind scripts/publish-release.sh and approved notes.
set -euo pipefail

usage() { echo 'usage: scripts/cut-release.sh build|ship X.Y.Z' >&2; exit 64; }
[ "$#" -eq 2 ] || usage
command="$1"
version="$2"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
tag="v$version"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="/private/tmp/wovenmatter-release-$version"
source="$work/source"
upload="$work/upload"
started=$SECONDS
step() { printf '\n==> [%dm%02ds] %s\n' $(((SECONDS - started) / 60)) $(((SECONDS - started) % 60)) "$1"; }
export GH_HOST=github.com GH_PROMPT_DISABLED=1 GH_BROWSER=/usr/bin/false

refuse_existing() {
  local remote
  remote="$(git -C "$repo_root" ls-remote --tags origin "refs/tags/$tag^{}" | cut -f1)"
  [ -z "$remote" ] || { echo "$tag already exists at $remote; delete it first if it was never published." >&2; exit 65; }
  if gh release view "$tag" >/dev/null 2>&1; then
    gh release view "$tag" --json isDraft --jq .isDraft | grep -qx true \
      || { echo "$tag is already public." >&2; exit 65; }
  fi
}

compile_app() {
  WOVENMATTER_SIGNING_IDENTITY=- WOVENMATTER_RELEASE_ALLOW_UNTAGGED=1 \
  WOVENMATTER_RELEASE_WORK_DIR="$1" WOVENMATTER_RELEASE_OUTPUT_DIR="$1/dist" \
  WOVENMATTER_COMPILER_CACHE="$HOME/Library/Caches/WovenMatter/ReleaseCompiler" \
  WOVENMATTER_PACKAGE_CACHE="$HOME/Library/Caches/WovenMatter/SourcePackages" \
    scripts/build-release.sh "$version" compile
}

build() {
  step 'Checking GitHub access'
  "$repo_root/scripts/check-release-access.sh"
  refuse_existing

  step 'Creating a fresh worktree of origin/main'
  git -C "$repo_root" fetch --no-tags origin main
  if [ -d "$source" ]; then git -C "$repo_root" worktree remove --force "$source"; fi
  rm -rf "$work"
  mkdir -p "$work"
  git -C "$repo_root" worktree add --detach "$source" origin/main
  cd "$source"
  revision="$(git rev-parse HEAD)"
  build_number="$(git rev-list --count HEAD)"
  echo "Building $tag (build $build_number) from $revision."

  step 'Compiling the Release app'
  compile_app "$work/build"
  local app="$work/build/DerivedData/Build/Products/Release/Woven Matter.app"

  # Includes the Linux server for x86_64 and aarch64 and the Linux Node record, Pi Durable,
  # the bots and the VM helper.
  step 'Checking the app'
  python3 scripts/validate-release-metadata.py verify "$version" "$build_number" "$revision" \
    --plist "$app/Contents/Info.plist"
  scripts/validate-native-app.sh "$app"

  mkdir -p "$upload"
  ditto -c -k --keepParent "$app" "$upload/WovenMatter-unsigned.zip"
  jq -n --arg version "$version" --argjson build "$build_number" --arg revision "$revision" \
    --arg sha "$(shasum -a 256 "$upload/WovenMatter-unsigned.zip" | cut -d' ' -f1)" \
    '{version: $version, build: $build, source_revision: $revision, sha256: $sha}' > "$upload/unsigned-input.json"
  step "Build ready: $tag from $revision. Ship it with: scripts/cut-release.sh ship $version"
}

ship() {
  [ -f "$upload/unsigned-input.json" ] && [ -f "$upload/WovenMatter-unsigned.zip" ] \
    || { echo "No build for $tag; run scripts/cut-release.sh build $version first." >&2; exit 65; }
  local revision
  revision="$(jq -er .source_revision "$upload/unsigned-input.json")"
  test "$(shasum -a 256 "$upload/WovenMatter-unsigned.zip" | cut -d' ' -f1)" = "$(jq -er .sha256 "$upload/unsigned-input.json")" \
    || { echo 'The built app changed since it was checked.' >&2; exit 65; }

  step 'Checking GitHub access'
  "$repo_root/scripts/check-release-access.sh"
  refuse_existing
  git -C "$repo_root" fetch --no-tags origin main
  git -C "$repo_root" merge-base --is-ancestor "$revision" origin/main \
    || { echo "$revision is not on origin/main." >&2; exit 65; }

  step 'Uploading the app to the private draft'
  if ! gh release view "$tag" >/dev/null 2>&1; then
    gh release create "$tag" --draft --target "$revision" --title "Woven Matter $tag" \
      --notes 'Signed and notarized Apple Silicon release.'
  fi
  gh release upload "$tag" "$upload/WovenMatter-unsigned.zip" "$upload/unsigned-input.json" --clobber

  step "Pushing $tag to start signing and notarization"
  git -C "$repo_root" tag -a "$tag" "$revision" -m "Woven Matter $tag"
  git -C "$repo_root" push origin "refs/tags/$tag"
  sleep 5
  gh run list --workflow release.yml --branch "$tag" --limit 1 --json url --jq '.[0].url // "Release workflow starting."'
  if [ -d "$source" ]; then git -C "$repo_root" worktree remove --force "$source"; fi
  step "Shipped $tag ($revision). When the workflow succeeds, verify with:"
  echo "scripts/publish-release.sh --verify-only $tag $revision"
}

case "$command" in
  build) build ;;
  ship) ship ;;
  *) usage ;;
esac
