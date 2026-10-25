# Node stable major shared with the bundled macOS runtime; --pull selects its newest
# patch and Debian security updates on every build (docs/DEPENDENCIES.md).
# Debian's current/backports OpenSSH clients retain CVE-2026-60002. Build
# current upstream clients separately; only verified binaries enter the image.
FROM node:26-trixie-slim AS workspace-ssh-build
ARG OPENSSH_VERSION=10.6p1
ARG OPENSSH_SHA256=a9dc9565dffe8640f64d863cd29a32bc4a3dbdec0566a7fc44c5d6ee767d5f39
RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends build-essential ca-certificates curl gnupg pkg-config libssl-dev zlib1g-dev libfido2-dev libedit-dev \
    && mkdir -m 700 /tmp/openssh-signatures \
    && curl --proto '=https' --tlsv1.2 -fsSL "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${OPENSSH_VERSION}.tar.gz" -o /tmp/openssh.tar.gz \
    && echo "${OPENSSH_SHA256}  /tmp/openssh.tar.gz" | sha256sum --check --status \
    && curl --proto '=https' --tlsv1.2 -fsSL "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${OPENSSH_VERSION}.tar.gz.asc" -o /tmp/openssh.tar.gz.asc \
    && curl --proto '=https' --tlsv1.2 -fsSL https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/RELEASE_KEY.asc -o /tmp/openssh-release-key.asc \
    && gpg --batch --homedir /tmp/openssh-signatures --import /tmp/openssh-release-key.asc \
    && gpg --batch --homedir /tmp/openssh-signatures --status-fd 1 --verify /tmp/openssh.tar.gz.asc /tmp/openssh.tar.gz > /tmp/openssh-signature.status \
    && grep -F '[GNUPG:] VALIDSIG 7168B983815A5EEF59A4ADFD2A3F414E736060BA ' /tmp/openssh-signature.status \
    && tar -xzf /tmp/openssh.tar.gz -C /tmp \
    && cd "/tmp/openssh-${OPENSSH_VERSION}" \
    && { ./configure --prefix=/usr/local --sysconfdir=/etc/ssh --with-security-key-builtin --with-libedit || { tail -n 100 config.log; exit 1; }; } \
    && make -j4 ssh scp sftp ssh-keygen ssh-agent ssh-add ssh-keyscan ssh-sk-helper ssh-pkcs11-helper \
    && make unit \
    && mkdir -p /openssh-install/usr/local/bin /openssh-install/usr/local/libexec /openssh-install/etc/ssh /openssh-install/usr/local/share/licenses/openssh \
    && install -m 0755 ssh scp sftp ssh-keygen ssh-agent ssh-add ssh-keyscan /openssh-install/usr/local/bin/ \
    && install -m 0755 ssh-sk-helper ssh-pkcs11-helper /openssh-install/usr/local/libexec/ \
    && install -m 0644 ssh_config /openssh-install/etc/ssh/ssh_config \
    && install -m 0644 LICENCE /openssh-install/usr/local/share/licenses/openssh/LICENCE

FROM node:26-trixie-slim

LABEL com.wovenmatter.workspace-uid="10001" \
      com.wovenmatter.workspace-gid="10001"

RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
      bash ca-certificates chromium curl git jq libedit2 libfido2-1 \
      procps python3 python3-venv ripgrep tini util-linux \
    && mkdir -p /etc/apt/keyrings \
    && curl --proto '=https' --tlsv1.2 -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli.gpg \
    && echo '6084d5d7bd8e288441e0e94fc6275570895da18e6751f70f057485dc2d1a811b  /etc/apt/keyrings/githubcli.gpg' | sha256sum --check --status \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' gh)" ge 2.103.2 \
    && rm -rf /var/lib/apt/lists/* \
    && userdel --remove node \
    && groupadd --gid 10001 woven \
    && useradd --no-create-home --home-dir /home --shell /bin/bash --uid 10001 --gid 10001 woven \
    && chown woven:woven /home \
    && chmod 0750 /home

ENV HOME=/home \
    WOVENMATTER_WORKSPACE=/home/.woven-matter \
    WOVENMATTER_LISTEN_HOST=0.0.0.0 \
    WOVENMATTER_LISTEN_PORT=7337 \
    PLAYWRIGHT_BROWSERS_PATH=/home/.cache/ms-playwright

COPY --from=workspace-ssh-build /openssh-install/ /
WORKDIR /opt/wovenmatter
COPY remote/npm-runtime/package*.json ./npm-runtime/
COPY --chown=woven:woven default-agent/package*.json ./default-agent/
# npm bundles an affected undici even in its current release. Replace that
# vendored module with the locked current API-compatible security selection.
# The workspace Playwright CLI matches playwright-core in the tested lockfile.
RUN export npm_config_cache=/tmp/wovenmatter-npm-build-cache \
    && npm install --global --ignore-scripts --no-audit --no-fund 'npm@>=12.2.1' \
    && npm ci --prefix npm-runtime --omit=dev --ignore-scripts --no-audit --no-fund \
    && rm -rf /usr/local/lib/node_modules/npm/node_modules/undici /opt/yarn-* /usr/local/bin/yarn /usr/local/bin/yarnpkg \
    && ln -s /opt/wovenmatter/npm-runtime/node_modules/undici /usr/local/lib/node_modules/npm/node_modules/undici \
    && npm install --global --ignore-scripts --no-audit --no-fund \
      "playwright@$(node -p 'require("./default-agent/package-lock.json").packages["node_modules/playwright-core"].version')" \
    && cd default-agent && npm ci --omit=dev --ignore-scripts --no-audit --no-fund \
    && rm -rf "$npm_config_cache"
COPY --chown=woven:woven default-agent/src ./default-agent/src
COPY --chown=woven:woven remote/package.json ./package.json
COPY --chown=woven:woven remote/src ./src
COPY --chown=woven:woven remote/entrypoint.sh ./entrypoint.sh
COPY --chown=woven:woven harnesses ./harnesses

RUN ln -s /opt/wovenmatter/src/wovenmatter /usr/local/bin/wovenmatter

USER woven
EXPOSE 7337
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD ["node", "--input-type=module", "-e", "const response = await fetch('http://127.0.0.1:7337/v1/health', { headers: { authorization: 'Bearer ' + process.env.WOVENMATTER_API_TOKEN }, signal: AbortSignal.timeout(4000) }); if (!response.ok) process.exit(1)"]
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/wovenmatter/entrypoint.sh"]
