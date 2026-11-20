# Woven bot base image: one container per bot, its own storage volume at /workspace. The
# runtime builds this through the Docker Engine API with a content-hash tag of this directory
# (toolchain/ excluded). Only slow-moving parts live here: the Ubuntu release, its packages and
# Chromium's system libraries. Node, npm, Playwright and Chromium (toolchain/) and the helper (env
# agent, supervisor, browser and SSH agent relay) come from the runtime's shared volume,
# mounted read-only at /opt/woven, through per-bot links (/opt/woven-toolchain, /opt/woven-bot)
# that an update repoints in place. So a tool or runtime update keeps the container, and only a
# change to this file moves bots to a new container.
# No Docker socket is mounted and no provider credentials ever enter the image or a container.
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    PATH=/home/bot/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    NPM_CONFIG_PREFIX=/home/bot/.local \
    NPM_CONFIG_CACHE=/var/cache/bot/npm \
    XDG_CACHE_HOME=/var/cache/bot \
    PLAYWRIGHT_BROWSERS_PATH=/var/cache/bot/ms-playwright \
    WOVEN_PLAYWRIGHT_BROWSERS=/opt/woven-toolchain/browsers \
    WOVEN_PLAYWRIGHT_MODULE=/opt/woven-toolchain/playwright/lib/node_modules/playwright

# Chromium's runtime libraries and fonts for the toolchain's Playwright build, from Playwright's
# own Ubuntu 26.04 list (chromium-packages.txt). An update whose Chromium needs more runs
# `playwright install-deps chromium` in the container, so this list changes only with the base.
COPY chromium-packages.txt /tmp/chromium-packages.txt
RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg git openssh-client sudo tini libatomic1 \
      build-essential pkg-config python3 python3-pip python3-venv python-is-python3 \
      unzip zip xz-utils jq ripgrep less procps file \
      $(grep -v '^#' /tmp/chromium-packages.txt) \
 && rm -rf /var/lib/apt/lists/* /tmp/chromium-packages.txt

# The bot user with passwordless sudo (full root inside its own container). Its home is a link
# into its storage (/workspace/.woven/home), so dotfiles, SSH keys, CLI sign-ins and user-level
# installs (npm -g and pip --user into ~/.local) outlive every update and move. Caches stay in
# the container. The toolchain's commands are linked into /usr/local/bin so sudo finds them; root
# npm installs go to /usr/local (the toolchain's npmrc). The bot's Playwright browser folder is
# writable (for its own Playwright versions) and links the toolchain's Chromium.
COPY start.sh /usr/lib/woven-bot/start
RUN (userdel -r ubuntu 2>/dev/null || true) \
 && useradd -M -d /home/bot -s /bin/bash -u 1000 bot \
 && ln -s /workspace/.woven/home /home/bot \
 && echo 'bot ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/bot \
 && chmod 0440 /etc/sudoers.d/bot \
 && chmod 0755 /usr/lib/woven-bot/start \
 && mkdir -p /workspace /var/cache/bot \
 && chown bot:bot /workspace /var/cache/bot \
 && for tool in node npm npx playwright; do ln -s "/opt/woven-toolchain/bin/$tool" "/usr/local/bin/$tool"; done

USER bot
WORKDIR /workspace
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/lib/woven-bot/start"]
