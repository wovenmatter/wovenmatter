# Same unchanged local runtime as macOS, packaged for a managed Linux host.
FROM node:24.18.0-bookworm-slim
# The published runtime bundles Git/workerd, while Debian supplies their shared
# libraries and the CA store used for app/package and provider HTTPS traffic.
RUN apt-get update && apt-get install --yes --no-install-recommends ca-certificates git libatomic1 \
    && rm -rf /var/lib/apt/lists/*
RUN npm install --prefix /opt/executor --ignore-scripts --no-audit --no-fund --save-exact executor@2.0.0-beta.7
ENV NODE_ENV=production
CMD ["node", "/opt/executor/node_modules/executor/bin.mjs", "serve"]
