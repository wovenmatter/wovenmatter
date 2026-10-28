# Node stable major shared with the bundled macOS runtime; --pull selects its newest
# patch and Debian security updates on every build (docs/DEPENDENCIES.md).
# Debian's current/backports OpenSSH clients retain CVE-2026-60002. Build
# current upstream clients separately; only verified binaries enter the image.
FROM node:26-trixie-slim AS workspace-ssh-build
ARG OPENSSH_VERSION=10.6p1
ARG OPENSSH_SHA256=a9dc9565dffe8640f64d863cd29a32bc4a3dbdec0566a7fc44c5d6ee767d5f39
RUN export DEBIAN_FRONTEND=noninteractive \
    && echo 'deb http://deb.debian.org/debian trixie-backports main' > /etc/apt/sources.list.d/wovenmatter-backports.list \
    && apt-get update && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends build-essential ca-certificates curl gnupg pkg-config libssl-dev zlib1g-dev libfido2-dev libedit-dev \
    && apt-get install -y --no-install-recommends -t trixie-backports curl libcurl4t64 libcurl3t64-gnutls \
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

# The official image now publishes the required Python security release for both
# native architectures. Record its verified manifest index; maintenance refreshes
# this runtime selection together with docs/DEPENDENCIES.md.
FROM python:3.15.2-slim-trixie@sha256:2145e0fc7fbd73eaae44c3c4759cf303e2c4e531353b207c6493226a02668ca5 AS workspace-python
RUN python3 -m pip install --no-cache-dir --upgrade 'pip>=26.2.2' 'setuptools>=84.2.1' \
    && find /usr/local -type f -executable ! -name '*tkinter*' -exec ldd '{}' ';' 2>/dev/null \
      | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) next; gsub("^/(usr/)?", "", so); printf "*%s\n", so }' \
      | sort -u | xargs -r dpkg-query --search \
      | awk 'sub(":$", "", $1) { print $1 }' | sort -u > /python-runtime-packages

# Reviewed source repairs preserve runtime SONAMEs and Debian's symbol checks.
# Signed APT source indexes authenticate the selected original sources.
FROM workspace-ssh-build AS workspace-security-build
RUN sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources \
    && echo 'deb-src http://deb.debian.org/debian sid main' > /etc/apt/sources.list.d/wovenmatter-sid-source.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends python3 devscripts debhelper patch autoconf automake libtool util-linux \
    && useradd --system --create-home wm-build
COPY remote/security /security
RUN chmod -R a+rX /security \
    && python3 /security/build-backports.py \
    && curl --proto '=https' --tlsv1.2 -fsSL https://cpan.metacpan.org/authors/id/B/BI/BINGOS/Archive-Tar-3.14.tar.gz -o /tmp/archive-tar.tgz \
    && echo '177ce0506124afbe3ef95836761fb0799c941b87b79bac489bddc6cda860d904  /tmp/archive-tar.tgz' | sha256sum --check --status \
    && tar --no-same-owner --no-same-permissions -xzf /tmp/archive-tar.tgz -C /tmp \
    && cd /tmp/Archive-Tar-3.14 && perl Makefile.PL && make test \
    && make install DESTDIR=/archive-tar-install

FROM node:26-trixie-slim

LABEL com.wovenmatter.workspace-uid="10001" \
      com.wovenmatter.workspace-gid="10001"

COPY --from=workspace-python /python-runtime-packages /tmp/python-runtime-packages
COPY --from=workspace-python /usr/local/ /usr/local/
COPY --from=workspace-security-build /security-output/ /tmp/security-output/
RUN export DEBIAN_FRONTEND=noninteractive \
    && echo 'deb http://deb.debian.org/debian trixie-backports main' > /etc/apt/sources.list.d/wovenmatter-backports.list \
    && apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
      bash ca-certificates chromium curl git jq libedit2 libfido2-1 \
      procps ripgrep tini util-linux $(cat /tmp/python-runtime-packages) \
    && mkdir -p /etc/apt/keyrings \
    && curl --proto '=https' --tlsv1.2 -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli.gpg \
    && echo '6084d5d7bd8e288441e0e94fc6275570895da18e6751f70f057485dc2d1a811b  /etc/apt/keyrings/githubcli.gpg' | sha256sum --check --status \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' gh)" ge 2.103.3 \
    && apt-get install -y --target-release trixie-backports --no-install-recommends /tmp/security-output/*.deb \
    && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' curl)" ge 8.23.0 \
    && mkdir -p /usr/local/share/wovenmatter/security \
    && cp -a /tmp/security-output/provenance /usr/local/share/wovenmatter/security/ \
    && rm -rf /var/lib/apt/lists/* /tmp/security-output /tmp/python-runtime-packages \
    && userdel --remove node \
    && groupadd --gid 10001 woven \
    && useradd --no-create-home --home-dir /home --shell /bin/bash --uid 10001 --gid 10001 woven \
    && chown woven:woven /home \
    && chmod 0750 /home \
    && test ! -e /usr/bin/python3 && ln -s /usr/local/bin/python3 /usr/bin/python3 \
    && rm -f /usr/bin/xdg-email \
    && find /usr -xdev -type f -perm /6000 -exec chmod a-s '{}' + \
    && ldconfig

ENV HOME=/home \
    WOVENMATTER_WORKSPACE=/home/.woven-matter \
    WOVENMATTER_LISTEN_HOST=0.0.0.0 \
    WOVENMATTER_LISTEN_PORT=7337 \
    PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright \
    NODE_PATH=/usr/local/lib/node_modules

COPY --from=workspace-ssh-build /openssh-install/ /
COPY --from=workspace-security-build /archive-tar-install/usr/local/share/perl/ /usr/local/share/perl/
WORKDIR /opt/wovenmatter
COPY remote/npm-runtime/package*.json ./npm-runtime/
COPY --chown=woven:woven default-agent/package*.json ./default-agent/
# npm bundles an affected undici even in its current release. Replace that
# vendored module with the locked current API-compatible security selection.
# The workspace Playwright CLI matches playwright-core in the tested lockfile.
# Keep browsers outside /home so persistent volumes cannot hide image updates.
RUN export npm_config_cache=/tmp/wovenmatter-npm-build-cache \
    && npm install --global --ignore-scripts --no-audit --no-fund 'npm@>=12.2.1' \
    && npm ci --prefix npm-runtime --omit=dev --ignore-scripts --no-audit --no-fund \
    && rm -rf /usr/local/lib/node_modules/npm/node_modules/undici /usr/local/lib/node_modules/npm/node_modules/ip-address /opt/yarn-* /usr/local/bin/yarn /usr/local/bin/yarnpkg \
    && cp -a /opt/wovenmatter/npm-runtime/node_modules/undici /usr/local/lib/node_modules/npm/node_modules/undici \
    && cp -a /opt/wovenmatter/npm-runtime/node_modules/ip-address /usr/local/lib/node_modules/npm/node_modules/ip-address \
    && npm install --global --ignore-scripts --no-audit --no-fund \
      "playwright@$(node -p 'require("./default-agent/package-lock.json").packages["node_modules/playwright-core"].version')" \
    && playwright install --with-deps chromium \
    && chmod -R a+rX /opt/ms-playwright \
    && rm -rf /var/lib/apt/lists/* \
    && find /usr -xdev -type f -perm /6000 -exec chmod a-s '{}' + \
    && cd default-agent && npm ci --omit=dev --ignore-scripts --no-audit --no-fund \
    && rm -rf "$npm_config_cache"
COPY --chown=woven:woven default-agent/src ./default-agent/src
COPY --chown=woven:woven remote/package.json ./package.json
COPY --chown=woven:woven remote/src ./src
COPY --chown=woven:woven remote/entrypoint.sh ./entrypoint.sh
COPY --chown=woven:woven harnesses ./harnesses

USER woven
EXPOSE 7337
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD ["node", "--input-type=module", "-e", "const response = await fetch('http://127.0.0.1:7337/v1/health', { headers: { authorization: 'Bearer ' + process.env.WOVENMATTER_API_TOKEN }, signal: AbortSignal.timeout(4000) }); if (!response.ok) process.exit(1)"]
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/wovenmatter/entrypoint.sh"]
