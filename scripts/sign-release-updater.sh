#!/usr/bin/env bash
# xcodebuild build signs only Sparkle's outer framework. Sign its shipped helpers
# from the inside out before sealing the framework and containing application.
# https://sparkle-project.org/documentation/sandboxing/#code-signing
set -euo pipefail
app="${1:?usage: sign-release-updater.sh APP SIGNING_IDENTITY}"
identity="${2:?usage: sign-release-updater.sh APP SIGNING_IDENTITY}"
framework="$app/Contents/Frameworks/Sparkle.framework"
root="$framework/Versions/B"
for member in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
  [ -e "$root/$member" ] || { printf 'Missing updater helper: %s\n' "$member" >&2; exit 65; }
done
codesign --force --sign "$identity" --options runtime --timestamp "$root/XPCServices/Installer.xpc"
# Preserve Downloader's specific entitlements, never apply them to other helpers.
codesign --force --sign "$identity" --options runtime --timestamp --preserve-metadata=entitlements "$root/XPCServices/Downloader.xpc"
codesign --force --sign "$identity" --options runtime --timestamp "$root/Autoupdate"
codesign --force --sign "$identity" --options runtime --timestamp "$root/Updater.app"
codesign --force --sign "$identity" --options runtime --timestamp "$framework"
codesign --force --sign "$identity" --options runtime --timestamp --preserve-metadata=identifier,entitlements "$app"
codesign --verify --deep --strict "$app"
