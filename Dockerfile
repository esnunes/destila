# syntax=docker/dockerfile:1.7
#
# Multi-stage Dockerfile for Destila.
#
# Stage 1 ("build") compiles a production `mix release`.
# Stage 2 ("runtime") ships the release alongside every CLI that
# `Destila.Deps` and `Destila.Git` expect on `PATH` (`claude`, `tmux`,
# `ffmpeg`, `agent-browser`, `git`) plus Chromium for `agent-browser`.
#
# Published image: ghcr.io/esnunes/destila
#
# Pair the Elixir/OTP versions here with `mise.toml`.
# See `.github/workflows/docker-publish.yml` for the CI build.

ARG ELIXIR_IMAGE=hexpm/elixir:1.19.0-erlang-28.4-debian-bookworm-20260421-slim
ARG RUNTIME_IMAGE=debian:bookworm-slim

# -----------------------------------------------------------------------------
# Build stage
# -----------------------------------------------------------------------------
FROM ${ELIXIR_IMAGE} AS build

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    MIX_ENV=prod

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      cmake \
      curl \
      git \
      libncurses-dev \
      nodejs \
      npm \
      pkg-config \
 && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force \
 && mix local.rebar --force

WORKDIR /app

# Dependency compilation layer — cached until mix.exs / mix.lock change.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

# JS deps for the asset pipeline.
COPY assets/package.json assets/package-lock.json assets/
RUN cd assets && npm ci --no-audit --no-fund

COPY priv priv
COPY lib lib
COPY assets assets
COPY rel rel

# Runtime config is evaluated at boot, not build — copy last so it does
# not bust the compile cache.
COPY config/runtime.exs config/

RUN mix assets.deploy
RUN mix release

# -----------------------------------------------------------------------------
# Runtime stage
# -----------------------------------------------------------------------------
FROM ${RUNTIME_IMAGE} AS runtime

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/root \
    PATH=/root/.local/bin:/usr/local/bin:/usr/bin:/bin \
    DATABASE_PATH=/data/destila.db \
    PHX_SERVER=true \
    PHX_HOST=localhost \
    PORT=4000 \
    PUPPETEER_SKIP_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
    CHROME_PATH=/usr/bin/chromium

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      chromium \
      curl \
      ffmpeg \
      git \
      libncurses6 \
      libstdc++6 \
      locales \
      nodejs \
      npm \
      openssl \
      tini \
      tmux \
 && rm -rf /var/lib/apt/lists/*

# agent-browser — required runtime CLI (see lib/destila/deps.ex).
RUN npm install -g --omit=dev @every/agent-browser \
 && npm cache clean --force

# Claude Code CLI — installs to /root/.local/bin/claude.
RUN curl -fsSL https://claude.ai/install.sh | bash \
 && test -x /root/.local/bin/claude

WORKDIR /app

COPY --from=build /app/_build/prod/rel/destila ./

VOLUME ["/root/.claude", "/root/.cache/destila", "/data"]

EXPOSE 4000

ENTRYPOINT ["/usr/bin/tini", "--", "/app/bin/entrypoint.sh"]
