# syntax=docker/dockerfile:1

# base commune : juste les manifestes npm pour profiter du cache
FROM node:20.17.0-alpine3.20 AS base
WORKDIR /app
COPY package.json package-lock.json ./

# deps de prod uniquement
FROM base AS deps
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --no-audit --no-fund

# toutes les deps + lint + tests
FROM base AS test
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --no-fund
COPY src ./src
COPY test ./test
RUN npm run lint && npm test

FROM node:20.17.0-alpine3.20 AS runtime
ARG APP_VERSION=dev
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.title="shopapi" \
      org.opencontainers.image.description="API catalogue produits Shop SAS" \
      org.opencontainers.image.vendor="Shop SAS" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="https://github.com/Maksenoff/docker-ynov-tp"
ENV NODE_ENV=production \
    APP_VERSION=${APP_VERSION} \
    PORT=3000
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
# package.json recupere depuis le stage test : ca oblige buildkit a executer les tests
COPY --from=test /app/package.json ./package.json
COPY src ./src
USER node
EXPOSE 3000
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/health || exit 1
CMD ["node", "src/server.js"]
