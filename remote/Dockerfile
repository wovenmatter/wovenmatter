FROM node:24.18.0-bookworm-slim@sha256:6f7b03f7c2c8e2e784dcf9295400527b9b1270fd37b7e9a7285cf83b6951452d

LABEL com.wovenmatter.workspace-uid="10001" \
      com.wovenmatter.workspace-gid="10001" \
      org.opencontainers.image.base.digest="sha256:6f7b03f7c2c8e2e784dcf9295400527b9b1270fd37b7e9a7285cf83b6951452d"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      bash ca-certificates chromium curl git gh jq openssh-client \
      procps python3 python3-venv ripgrep tini util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && npm install --global playwright@1.62.1 \
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
COPY --chown=woven:woven remote/package.json ./package.json
COPY --chown=woven:woven remote/src ./src
COPY --chown=woven:woven remote/entrypoint.sh ./entrypoint.sh
COPY --chown=woven:woven harnesses ./harnesses

USER woven
EXPOSE 7337
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD ["sh", "-c", "curl -fsS -H \"Authorization: Bearer $WOVENMATTER_API_TOKEN\" http://127.0.0.1:7337/v1/health >/dev/null"]
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/wovenmatter/entrypoint.sh"]
