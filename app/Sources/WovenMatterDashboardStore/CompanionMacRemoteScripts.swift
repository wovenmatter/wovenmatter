import Foundation

enum CompanionMacRemoteScripts {
    static let locate = #"""
    set -eu
    export PATH=/usr/bin:/bin:/usr/sbin:/sbin
    fail() { printf 'woven-error:%s\n' "$1"; exit 0; }
    [ "$(uname -s)" = Darwin ] || fail 'This device is not running macOS.'
    app='/Applications/Woven Matter.app'
    if [ ! -d "$app" ] && [ -d "$HOME/Applications/Woven Matter.app" ]; then app="$HOME/Applications/Woven Matter.app"; fi
    field() { [ -f "$app/Contents/Info.plist" ] || return 0; /usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist" 2>/dev/null || true; }
    running() { /usr/bin/pgrep -f '[/]Woven Matter.app/Contents/MacOS/' >/dev/null 2>&1; }
    """#

    static let inspect = locate + #"""

    printf 'woven-mac-inspection-v1\n'
    if [ -d "$app" ]; then printf 'installed\n'; else printf 'missing\n'; fi
    printf '%s\n' "$(field CFBundleShortVersionString)" "$(field CFBundleVersion)" "$(field WovenMatterDeviceSetupVersion)"
    if running; then printf '1\n'; else printf '0\n'; fi
    uname -m
    sw_vers -productVersion
    /usr/bin/defaults read wovenmatter.desktop wovenmatter.device-setup.status 2>/dev/null || printf '\n'
    /usr/bin/defaults read wovenmatter.desktop wovenmatter.device-setup.device-id 2>/dev/null || printf '\n'
    """#

    static let pair = locate + #"""

    [ -d "$app" ] || fail 'Woven Matter is not installed. Download it before pairing.'
    [ "$(field WovenMatterDeviceSetupVersion)" = 1 ] || fail 'Update Woven Matter on this Mac to pair it from here.'
    [ "$(stat -f %Su /dev/console)" = "$(id -un)" ] || fail 'Sign in to this Mac with the SSH user before pairing.'
    /usr/bin/defaults delete wovenmatter.desktop wovenmatter.device-setup.status 2>/dev/null || true
    /usr/bin/defaults write wovenmatter.desktop wovenmatter.device-setup.request -string "$1"
    /usr/bin/open "$app"
    """#

    static let open = locate + #"""

    [ -d "$app" ] || fail 'Woven Matter is not installed. Download it before pairing.'
    [ "$(stat -f %Su /dev/console)" = "$(id -un)" ] || fail 'Sign in to this Mac with the SSH user before opening Woven Matter.'
    /usr/bin/open "$app"
    """#

    static let install = locate + #"""

    [ "$(uname -m)" = arm64 ] || fail 'Woven Matter downloads currently require an Apple Silicon Mac.'
    [ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ] || fail 'Woven Matter requires macOS 26 or later.'
    version_at_least() {
      /usr/bin/awk -v current="$1" -v minimum="$2" 'BEGIN { n=split(current,a,"."); m=split(minimum,b,"."); for(i=1;i<=n || i<=m;i++){ if(a[i]+0>b[i]+0)exit 0; if(a[i]+0<b[i]+0)exit 1 } exit 0 }'
    }
    version_at_least "$(sw_vers -productVersion)" "$6" || fail 'Update macOS on this Mac before installing this release.'
    [ "$(stat -f %Su /dev/console)" = "$(id -un)" ] || fail 'Sign in to this Mac with the SSH user before installing.'
    umask 077
    lock_dir="$HOME/Library/Caches/WovenMatter/DeviceSetup"
    mkdir -p "$lock_dir"
    lock_file="$lock_dir/install.lock"
    /usr/bin/shlock -f "$lock_file" -p "$$" || fail 'Another Woven Matter installation is in progress on this Mac. Wait for it to finish, then retry.'
    work=''
    mount=''
    stage=''
    backup=''
    installed=0
    was_running=0
    update_request="$5"
    update_request_id=''
    cleanup() {
      if [ -n "$mount" ]; then /usr/bin/hdiutil detach "$mount" -quiet >/dev/null 2>&1 || true; fi
      if [ "$installed" = 0 ] && [ -n "$backup" ] && [ -d "$backup" ] && [ ! -e "$app" ]; then mv "$backup" "$app"; fi
      if [ "$installed" = 0 ] && [ "$was_running" = 1 ]; then
        pending=$(/usr/bin/defaults read wovenmatter.desktop wovenmatter.device-setup.request 2>/dev/null || true)
        if [ "$pending" = "$update_request" ]; then /usr/bin/defaults delete wovenmatter.desktop wovenmatter.device-setup.request 2>/dev/null || true; fi
      fi
      if [ "$installed" = 0 ] && [ "$was_running" = 1 ] && [ -d "$app" ]; then /usr/bin/open "$app" >/dev/null 2>&1 || true; fi
      if [ -n "$stage" ]; then rm -rf "$stage" >/dev/null 2>&1 || true; fi
      if [ -n "$work" ]; then rm -rf "$work"; fi
      owner=$(cat "$lock_file" 2>/dev/null || true)
      if [ "$owner" = "$$" ]; then rm -f "$lock_file"; fi
    }
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    work=$(mktemp -d "${TMPDIR:-/tmp}/woven-device-install.XXXXXX")
    mount="$work/mount"
    /usr/bin/curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-time 480 --output "$work/app.dmg" "$1"
    actual=$(/usr/bin/shasum -a 256 "$work/app.dmg" | /usr/bin/awk '{print $1}')
    [ "$actual" = "$2" ] || fail 'The download checksum did not match. The existing app was preserved.'
    mkdir "$mount"
    /usr/bin/hdiutil attach "$work/app.dmg" -mountpoint "$mount" -readonly -nobrowse -quiet
    candidate="$mount/Woven Matter.app"
    /usr/bin/codesign --verify --deep --strict -R '=anchor apple generic and identifier "wovenmatter.desktop" and certificate leaf[subject.OU] = "3M84Q9NAMN"' "$candidate" || fail 'The app signature could not be verified. The existing app was preserved.'
    /usr/sbin/spctl --assess --type execute "$candidate" || fail 'macOS could not verify this app for installation.'
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$candidate/Contents/Info.plist")" = "$3" ] || fail 'The downloaded app version does not match this release.'
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$candidate/Contents/Info.plist")" = "$4" ] || fail 'The downloaded app build does not match this release.'
    candidate_minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$candidate/Contents/Info.plist")
    version_at_least "$(sw_vers -productVersion)" "$candidate_minimum" || fail 'The downloaded app requires a newer macOS version.'
    if [ "$7" = 1 ]; then
      [ "$(/usr/libexec/PlistBuddy -c 'Print :WovenMatterDeviceSetupVersion' "$candidate/Contents/Info.plist" 2>/dev/null || true)" = 1 ] || fail 'This download does not support remote pairing. The existing app was preserved.'
    fi
    # Never downgrade an installation that changed since inspection.
    current=$(field CFBundleVersion)
    if [ -n "$current" ]; then [ "$current" -le "$4" ] || fail 'A newer app is already installed. Refresh this Mac before continuing.'; fi
    if [ ! -d "$app" ] && [ ! -w /Applications ]; then mkdir -p "$HOME/Applications"; app="$HOME/Applications/Woven Matter.app"; fi
    parent=$(dirname "$app")
    [ -w "$parent" ] || fail 'The SSH user cannot update this app. Use an account that can write to its Applications folder.'
    stage=$(mktemp -d "$parent/.woven-install.XXXXXX")
    /usr/bin/ditto "$candidate" "$stage/Woven Matter.app"
    /usr/bin/codesign --verify --deep --strict "$stage/Woven Matter.app"
    if running; then
      was_running=1
      if [ "$(field WovenMatterDeviceSetupVersion)" = 1 ]; then
        /usr/bin/defaults delete wovenmatter.desktop wovenmatter.device-setup.status 2>/dev/null || true
        update_request_id=$(printf '%s' "$update_request" | /usr/bin/plutil -extract id raw -o - -)
        /usr/bin/defaults write wovenmatter.desktop wovenmatter.device-setup.request -string "$5"
        /usr/bin/open "$app"
      else
        # Legacy releases still receive an ordinary quit, never a forced stop.
        /usr/bin/osascript -e 'tell application id "wovenmatter.desktop" to quit' >/dev/null 2>&1 || true
      fi
      for attempt in $(seq 1 60); do
        if ! running; then break; fi
        setup_status=$(/usr/bin/defaults read wovenmatter.desktop wovenmatter.device-setup.status 2>/dev/null || true)
        if [ "$(field WovenMatterDeviceSetupVersion)" = 1 ]; then
          status_id=$(printf '%s' "$setup_status" | /usr/bin/plutil -extract requestID raw -o - - 2>/dev/null || true)
          status_phase=$(printf '%s' "$setup_status" | /usr/bin/plutil -extract phase raw -o - - 2>/dev/null || true)
          if [ "$status_id" = "$update_request_id" ] && [ "$status_phase" = failed ]; then fail 'Woven Matter could not prepare to update. Check its running work and pending approvals, then retry.'; fi
        fi
        sleep 1
      done
      if running; then
        fail 'Woven Matter is still running. Finish its active work and approvals, or stop the background server on that Mac, then retry Update.'
      fi
    fi
    # Refuse to overwrite a newly started owner; no process is force-stopped.
    running && fail 'Woven Matter started during installation. Quit it and retry Update.'
    current=$(field CFBundleVersion)
    if [ -n "$current" ]; then [ "$current" -le "$4" ] || fail 'A newer app was installed during this update. Refresh this Mac before continuing.'; fi
    if [ -e "$app" ]; then backup="$stage/previous.app"; mv "$app" "$backup"; fi
    mv "$stage/Woven Matter.app" "$app"
    installed=1
    /usr/bin/open "$app" || fail 'Woven Matter was installed but could not open. Open it on that Mac to finish setup.'
    printf 'installed\n'
    """#
}
