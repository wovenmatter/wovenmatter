# Same unchanged local runtime as macOS, packaged for a managed Linux host.
FROM node:26-trixie-slim AS executor-archive-build
RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates curl make perl \
    && curl --proto '=https' --tlsv1.2 -fsSL https://cpan.metacpan.org/authors/id/B/BI/BINGOS/Archive-Tar-3.14.tar.gz -o /tmp/archive-tar.tgz \
    && echo '177ce0506124afbe3ef95836761fb0799c941b87b79bac489bddc6cda860d904  /tmp/archive-tar.tgz' | sha256sum --check --status \
    && tar --no-same-owner --no-same-permissions -xzf /tmp/archive-tar.tgz -C /tmp \
    && cd /tmp/Archive-Tar-3.14 \
    && perl Makefile.PL \
    && make test \
    && make install DESTDIR=/archive-tar-install

FROM node:26-trixie-slim AS executor-security-build
RUN sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources \
    && echo 'deb-src http://deb.debian.org/debian sid main' > /etc/apt/sources.list.d/wovenmatter-sid-source.list \
    && apt-get update \
    && apt-get install --yes --no-install-recommends python3 devscripts debhelper patch autoconf automake libtool util-linux \
    && useradd --system --create-home wm-build
COPY security /security
RUN chmod -R a+rX /security \
    && WM_SECURITY_PACKAGES=ncurses,acl,util-linux,curl python3 /security/build-backports.py

FROM node:26-trixie-slim
# The published runtime bundles Git/workerd, while Debian supplies their shared
# libraries and the CA store used for app/package and provider HTTPS traffic.
COPY --from=executor-security-build /security-output/ /tmp/security-output/
RUN export DEBIAN_FRONTEND=noninteractive \
    && echo 'deb http://deb.debian.org/debian trixie-backports main' > /etc/apt/sources.list.d/wovenmatter-backports.list \
    && apt-get update && apt-get upgrade --yes \
    && apt-get install --yes --no-install-recommends ca-certificates git libatomic1 \
    && apt-get install --yes --no-install-recommends \
      /tmp/security-output/curl_*.deb \
      /tmp/security-output/libcurl4t64_*.deb \
      /tmp/security-output/libcurl4-gnutls_*.deb \
      /tmp/security-output/libcurl3t64-gnutls_*.deb \
      /tmp/security-output/libacl1_*.deb \
      /tmp/security-output/ncurses-bin_*.deb \
      /tmp/security-output/ncurses-base_*.deb \
      /tmp/security-output/libtinfo6_*.deb \
      /tmp/security-output/bsdutils_*.deb \
      /tmp/security-output/libblkid1_*.deb \
      /tmp/security-output/liblastlog2-2_*.deb \
      /tmp/security-output/libmount1_*.deb \
      /tmp/security-output/libsmartcols1_*.deb \
      /tmp/security-output/libuuid1_*.deb \
      /tmp/security-output/login_*.deb \
      /tmp/security-output/mount_*.deb \
      /tmp/security-output/util-linux_*.deb \
    && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' curl)" ge 8.23.0 \
    && mkdir -p /usr/local/share/wovenmatter/security \
    && cp -a /tmp/security-output/provenance /usr/local/share/wovenmatter/security/ \
    && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' libacl1)" ge 2.4.0-1+wmsecurity1 \
    && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' libtinfo6)" ge 6.5+20250216-2+wmsecurity1 \
    && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' util-linux)" ge 2.41.5-0+deb13u1+wmsecurity1 \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /tmp/security-output \
    && find /usr -xdev -type f -perm /6000 -exec chmod a-s '{}' +
COPY --from=executor-archive-build /archive-tar-install/usr/local/share/perl/ /usr/local/share/perl/
COPY npm-runtime/package*.json /opt/wovenmatter/npm-runtime/
COPY executor-runtime/package*.json /opt/wovenmatter/executor-runtime/
ARG EXECUTOR_VERSION
RUN test -n "$EXECUTOR_VERSION" \
    && export npm_config_cache=/tmp/wovenmatter-npm-build-cache \
    && npm install --global --ignore-scripts --no-audit --no-fund 'npm@>=12.2.1' \
    && npm ci --prefix /opt/wovenmatter/npm-runtime --omit=dev --ignore-scripts --no-audit --no-fund \
    && rm -rf /usr/local/lib/node_modules/npm/node_modules/undici /usr/local/lib/node_modules/npm/node_modules/ip-address \
    && cp -a /opt/wovenmatter/npm-runtime/node_modules/undici /usr/local/lib/node_modules/npm/node_modules/undici \
    && cp -a /opt/wovenmatter/npm-runtime/node_modules/ip-address /usr/local/lib/node_modules/npm/node_modules/ip-address \
    && node -e 'const {createRequire}=require("node:module"); const npm=createRequire("/usr/local/lib/node_modules/npm/package.json"); for(const name of ["undici","ip-address"]){const expected=require("/opt/wovenmatter/npm-runtime/node_modules/"+name+"/package.json").version; if(npm(name+"/package.json").version!==expected)process.exit(1)}' \
    && npm ci --prefix /opt/wovenmatter/executor-runtime --omit=dev --ignore-scripts --no-audit --no-fund \
    && npm install --prefix /opt/executor --ignore-scripts --no-audit --no-fund --save-exact "executor@$EXECUTOR_VERSION" \
    && runtime_modules="$(find /opt/executor/node_modules -type d -path '*/runtime/node_modules' -print -quit)" \
    && test -n "$runtime_modules" \
    && rm -rf "$runtime_modules/sharp" "$runtime_modules/@img/colour" "$runtime_modules/@img"/sharp-* "$runtime_modules/detect-libc" "$runtime_modules/semver" \
    && cp -a /opt/wovenmatter/executor-runtime/node_modules/sharp "$runtime_modules/sharp" \
    && mkdir -p "$runtime_modules/@img" \
    && cp -a /opt/wovenmatter/executor-runtime/node_modules/@img/colour "$runtime_modules/@img/colour" \
    && find /opt/wovenmatter/executor-runtime/node_modules/@img -mindepth 1 -maxdepth 1 -type d -name 'sharp-*' -exec cp -a '{}' "$runtime_modules/@img/" ';' \
    && cp -a /opt/wovenmatter/executor-runtime/node_modules/detect-libc "$runtime_modules/detect-libc" \
    && cp -a /opt/wovenmatter/executor-runtime/node_modules/semver "$runtime_modules/semver" \
    && node -e 'const sharp=require(process.argv[1]); if (sharp.versions.sharp !== "0.35.5") process.exit(1)' "$runtime_modules/sharp" \
    && rm -rf "$npm_config_cache" /opt/wovenmatter/npm-runtime /opt/wovenmatter/executor-runtime
ENV NODE_ENV=production HOME=/home/node
USER node
EXPOSE 4312
CMD ["node", "/opt/executor/node_modules/executor/bin.mjs", "serve"]
