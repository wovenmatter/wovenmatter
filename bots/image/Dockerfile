# Woven bot environment: one container per bot, its own storage volume at /workspace. The
# runtime builds this through the Docker Engine API with a content-hash tag. The helper (env
# agent, supervisor, browser and preview forwarder) is not in the image: it is mounted read-only
# at /opt/woven-bot from the runtime's helper volume, so runtime updates need no image change.
# No Docker socket is mounted and no provider credentials ever enter the image or a container.
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright \
    WOVEN_PLAYWRIGHT_MODULE=/usr/local/lib/node_modules/playwright

RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg git openssh-client sudo tini \
      build-essential pkg-config python3 python3-pip python3-venv python-is-python3 \
      unzip zip xz-utils jq ripgrep less procps file \
 && rm -rf /var/lib/apt/lists/*

# Node from the official archive, checksum-verified. Keep in step with
# remote/host/runtime-versions.json (dependency maintenance updates both).
ARG NODE_VERSION=26.13.0
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) arch=x64; sum=5848553868b402d3fabb5b09270649977780a390f832155721025a08b5104455 ;; \
      arm64) arch=arm64; sum=439e9c438acdf6a6ffe47418da709153d66c4bed812e30a473faacb107dd2791 ;; \
      *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo /tmp/node.tar.gz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${arch}.tar.gz"; \
    echo "${sum}  /tmp/node.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/node.tar.gz -C /usr/local --strip-components=1 --no-same-owner; \
    rm -f /tmp/node.tar.gz; \
    node --version

# Playwright with Chromium (and its system libraries), usable by the bot user. Keep the version in
# step with remote/host/runtime-versions.json.
ARG PLAYWRIGHT_VERSION=1.65.0
# Node's archive npm is bootstrap-only. Use the same integrity-verified private
# npm and locked vendor repairs as managed CLI installs and SDK updates.
# The container's bot user needs read/execute access; ownership stays with root.
COPY tooling /opt/wovenmatter/tooling-source/
RUN set -eu; \
    npm_path="$(node /opt/wovenmatter/tooling-source/harnesses/prepare-npm.mjs '{"prefix":"/opt/wovenmatter/npm","node":"/usr/local/bin/node","bootstrap":["/usr/local/bin/node","/usr/local/lib/node_modules/npm/bin/npm-cli.js"],"securityGraph":"/opt/wovenmatter/tooling-source/npm-runtime"}')"; \
    chmod -R a+rX /opt/wovenmatter/npm; \
    ln -sf "$npm_path" /usr/local/bin/npm; \
    ln -sf "${npm_path%/bin/npm}/lib/node_modules/npm/bin/npx-cli.js" /usr/local/bin/npx; \
    npm install -g --prefix /usr/local "playwright@${PLAYWRIGHT_VERSION}" --no-audit --no-fund \
 && playwright install --with-deps chromium \
 && chmod -R a+rX /opt/ms-playwright \
 && rm -rf /var/lib/apt/lists/* /root/.npm

# The bot user with passwordless sudo (full root inside its own container); /workspace is its
# storage volume.
RUN (userdel -r ubuntu 2>/dev/null || true) \
 && useradd -m -s /bin/bash -u 1000 bot \
 && echo 'bot ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/bot \
 && chmod 0440 /etc/sudoers.d/bot \
 && mkdir -p /workspace /opt/woven-bot \
 && chown bot:bot /workspace

USER bot
WORKDIR /workspace
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "/opt/woven-bot/supervisor.mjs"]
