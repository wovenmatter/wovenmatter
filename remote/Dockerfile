# Node LTS line shared with the bundled macOS runtime; --pull selects its newest
# patch and Debian security updates on every build (docs/DEPENDENCIES.md).
FROM node:24-trixie-slim

LABEL com.wovenmatter.workspace-uid="10001" \
      com.wovenmatter.workspace-gid="10001"

RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
      bash ca-certificates chromium curl git gh jq openssh-client \
      procps python3 python3-venv ripgrep tini util-linux \
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

WORKDIR /opt/wovenmatter
COPY --chown=woven:woven default-agent/package*.json ./default-agent/
# The workspace Playwright CLI matches playwright-core in the tested lockfile.
RUN npm install --global --ignore-scripts --no-audit --no-fund \
      "playwright@$(node -p 'require("./default-agent/package-lock.json").packages["node_modules/playwright-core"].version')" \
    && cd default-agent && npm ci --omit=dev --ignore-scripts --no-audit --no-fund
COPY --chown=woven:woven default-agent/src ./default-agent/src
COPY --chown=woven:woven remote/package.json ./package.json
COPY --chown=woven:woven remote/src ./src
COPY --chown=woven:woven remote/entrypoint.sh ./entrypoint.sh
COPY --chown=woven:woven harnesses ./harnesses

RUN ln -s /opt/wovenmatter/src/wovenmatter /usr/local/bin/wovenmatter

USER woven
EXPOSE 7337
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD ["sh", "-c", "curl -fsS -H \"Authorization: Bearer $WOVENMATTER_API_TOKEN\" http://127.0.0.1:7337/v1/health >/dev/null"]
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/wovenmatter/entrypoint.sh"]
