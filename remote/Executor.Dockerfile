# Same unchanged local runtime as macOS, packaged for a managed Linux host.
FROM node:24.22.0-trixie-slim@sha256:7f486cabe892bff8fef04c0f7da8dba84a560be3e4e2740b7a86afc57ebec315
# The published runtime bundles Git/workerd, while Debian supplies their shared
# libraries and the CA store used for app/package and provider HTTPS traffic.
RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update && apt-get upgrade --yes \
    && apt-get install --yes --no-install-recommends ca-certificates git libatomic1 \
    && rm -rf /var/lib/apt/lists/*
RUN npm install --global --ignore-scripts --no-audit --no-fund npm@12.2.0
ARG EXECUTOR_VERSION
RUN test -n "$EXECUTOR_VERSION" && npm install --prefix /opt/executor --ignore-scripts --no-audit --no-fund --save-exact "executor@$EXECUTOR_VERSION"
ENV NODE_ENV=production
CMD ["node", "/opt/executor/node_modules/executor/bin.mjs", "serve"]
