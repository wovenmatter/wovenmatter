# Woven bot toolchain: Node, the private npm, Playwright and its Chromium, under
# /opt/woven-toolchain. The runtime builds this through the Engine API under the content hash of
# this directory (plus the npm tooling records) and copies /opt/woven-toolchain into its shared
# volume as toolchain/<hash>. Each bot reaches its selected copy through its own
# /opt/woven-toolchain link, so a Node or Playwright update repoints the link in an ordinary
# update and keeps the bot's container. Built on the same Ubuntu release as ../Dockerfile; that
# image carries Chromium's system libraries.
FROM ubuntu:26.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils libatomic1 \
 && rm -rf /var/lib/apt/lists/*

# Node from the official archive, checksum-verified. It links libatomic, which ../Dockerfile
# installs too. Keep in step with remote/host/runtime-versions.json (dependency maintenance
# updates both).
ARG NODE_VERSION=26.13.1
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) arch=x64; sum=518674de2b621728a5e4486f5fb3b7d2900bb3cc4aa97969edaa463db99f9778 ;; \
      arm64) arch=arm64; sum=80a330b35415382878df18d41afbd106ea89bfb3be0087d6608e289a14c5cc7d ;; \
      *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac; \
    mkdir -p /opt/woven-toolchain/node /opt/woven-toolchain/bin; \
    curl -fsSLo /tmp/node.tar.gz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${arch}.tar.gz"; \
    echo "${sum}  /tmp/node.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/node.tar.gz -C /opt/woven-toolchain/node --strip-components=1 --no-same-owner; \
    rm -f /tmp/node.tar.gz; \
    ln -s ../node/bin/node /opt/woven-toolchain/bin/node; \
    /opt/woven-toolchain/bin/node --version

# Playwright with Chromium. Keep the version in step with remote/host/runtime-versions.json.
ARG PLAYWRIGHT_VERSION=1.65.1
# Node's archive npm is bootstrap-only. Use the same integrity-verified private
# npm and locked vendor repairs as managed CLI installs and SDK updates. Its
# builtin npmrc sends root's global installs to /usr/local in the bot container
# (the bot user's go to ~/.local through NPM_CONFIG_PREFIX).
COPY tooling /tmp/tooling/
RUN set -eu; \
    node=/opt/woven-toolchain/node/bin/node; \
    npm_path="$("$node" /tmp/tooling/harnesses/prepare-npm.mjs '{"prefix":"/opt/woven-toolchain/npm","node":"/opt/woven-toolchain/node/bin/node","bootstrap":["/opt/woven-toolchain/node/bin/node","/opt/woven-toolchain/node/lib/node_modules/npm/bin/npm-cli.js"],"securityGraph":"/tmp/tooling/npm-runtime"}')"; \
    npm_root="${npm_path%/bin/npm}/lib/node_modules/npm"; \
    ln -s "$npm_path" /opt/woven-toolchain/bin/npm; \
    ln -s "$npm_root/bin/npx-cli.js" /opt/woven-toolchain/bin/npx; \
    export PATH="/opt/woven-toolchain/bin:$PATH"; \
    npm install -g --prefix /opt/woven-toolchain/playwright "playwright@${PLAYWRIGHT_VERSION}" --no-audit --no-fund; \
    ln -s ../playwright/bin/playwright /opt/woven-toolchain/bin/playwright; \
    PLAYWRIGHT_BROWSERS_PATH=/opt/woven-toolchain/browsers playwright install chromium; \
    printf 'prefix=/usr/local\n' > "$npm_root/npmrc"; \
    printf '{"node":"%s","playwright":"%s"}\n' "$NODE_VERSION" "$PLAYWRIGHT_VERSION" > /opt/woven-toolchain/versions.json; \
    chmod -R a+rX /opt/woven-toolchain; \
    rm -rf /tmp/tooling /root/.npm
