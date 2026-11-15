#!/bin/sh
# A bot container's first process under tini: make sure the home folder exists in the bot's
# storage (a new bot gets the default dotfiles), link the toolchain's browsers into the bot's own
# Playwright browser folder, then become the helper's supervisor.
home=/workspace/.woven/home
if [ ! -d "$home" ]; then
  rm -rf "$home.new" && mkdir -p "$home.new" && cp -R /etc/skel/. "$home.new/" && mv "$home.new" "$home"
fi
browsers="${PLAYWRIGHT_BROWSERS_PATH:-/var/cache/bot/ms-playwright}"
if mkdir -p "$browsers/.links" 2>/dev/null; then
  find "$browsers" -mindepth 1 -maxdepth 1 -type l ! -exec test -e {} \; -delete 2>/dev/null
  for dir in "$WOVEN_PLAYWRIGHT_BROWSERS"/*; do
    [ -d "$dir" ] && ln -sfn "$dir" "$browsers/$(basename "$dir")"
  done
  # Registered, so a Playwright install's cleanup keeps the toolchain's browsers linked.
  cp -f "$WOVEN_PLAYWRIGHT_BROWSERS"/.links/* "$browsers/.links/" 2>/dev/null
fi
exec node /opt/woven-bot/supervisor.mjs
