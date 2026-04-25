# syntax=docker/dockerfile:1.7
#
# Multi-stage Dockerfile for Destila.
#
# Stage 1 ("build") fetches and compiles deps + the application for
# `MIX_ENV=prod` and deploys assets. Erlang, Elixir, and Node come from
# `mise.toml` via mise — the same source of truth used in dev — so OTP
# versions cannot drift between local and CI.
#
# Stage 2 ("runtime") ships the compiled source tree alongside every CLI
# Destila expects on `PATH` (`claude`, `tmux`, `ffmpeg`, `agent-browser`,
# `git`) plus Chromium for `agent-browser`. The container runs the server
# with `elixir --sname destila -S mix phx.server`, redirected to
# /root/.cache/destila/services/project-destila-main.log, so the start
# command matches how Destila launches its own managed services.
#
# Tool sourcing strategy:
#   - mise: erlang, elixir, node (from `mise.toml`); ffmpeg, tmux at runtime
#   - apt:  system libraries the BEAM/chromium link against, tini for PID 1,
#           build deps required to compile OTP from source, plus git/curl
#   - npm (via mise's node): @every/agent-browser
#   - Anthropic install script: claude CLI
#
# Published image: ghcr.io/esnunes/destila
#
# See `.github/workflows/docker-publish.yml` for the CI build.

ARG DEBIAN_IMAGE=debian:bookworm-slim

# -----------------------------------------------------------------------------
# Build stage
# -----------------------------------------------------------------------------
FROM ${DEBIAN_IMAGE} AS build

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    MIX_ENV=prod \
    MISE_DATA_DIR=/mise \
    MISE_CONFIG_DIR=/mise \
    MISE_CACHE_DIR=/mise/cache \
    MISE_INSTALL_PATH=/usr/local/bin/mise \
    PATH=/mise/shims:/usr/local/bin:/usr/bin:/bin

# System deps mise cannot provide: compilers, headers, and helpers required to
# build OTP from source (kerl) and compile native Elixir deps.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      autoconf \
      build-essential \
      ca-certificates \
      cmake \
      curl \
      git \
      libncurses-dev \
      libssl-dev \
      m4 \
      pkg-config \
      unzip \
 && rm -rf /var/lib/apt/lists/*

RUN curl https://mise.run | sh

WORKDIR /app

# `mise install` reads mise.toml — so erlang, elixir, and node all come from
# the same pinned versions used in development.
COPY mise.toml ./
RUN mise trust mise.toml \
 && mise install

RUN mix local.hex --force \
 && mix local.rebar --force

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

# Runtime config is evaluated at boot, not build — copy last so it does
# not bust the compile cache.
COPY config/runtime.exs config/

RUN mix compile
RUN mix assets.deploy

# -----------------------------------------------------------------------------
# Runtime stage
# -----------------------------------------------------------------------------
FROM ${DEBIAN_IMAGE} AS runtime

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/root \
    MIX_ENV=prod \
    MISE_DATA_DIR=/mise \
    MISE_CONFIG_DIR=/mise \
    MISE_CACHE_DIR=/mise/cache \
    MISE_INSTALL_PATH=/usr/local/bin/mise \
    PATH=/root/.local/bin:/mise/shims:/usr/local/bin:/usr/bin:/bin \
    DATABASE_PATH=/data/destila.db \
    PHX_SERVER=true \
    PHX_HOST=localhost \
    PORT=4000 \
    PUPPETEER_SKIP_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium \
    CHROME_PATH=/usr/bin/chromium

# System deps mise cannot replace: chromium (apt-only), the runtime libs the
# BEAM links against (ncurses/libstdc++/openssl), locales, tini for PID 1,
# git for `Destila.Git`, plus ca-certificates / curl for the claude installer.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      chromium \
      curl \
      git \
      libncurses6 \
      libstdc++6 \
      locales \
      openssl \
      tini \
 && rm -rf /var/lib/apt/lists/*

# Reuse erlang/elixir/node from the build stage to avoid recompiling OTP.
COPY --from=build /usr/local/bin/mise /usr/local/bin/mise
COPY --from=build /mise /mise

# Add ffmpeg and tmux from mise — quick aqua downloads, no compilation.
RUN mise use --global ffmpeg tmux \
 && mise install

# agent-browser — installed via npm using mise's node. `mise reshim` ensures
# the new bin is exposed via /mise/shims.
RUN npm install -g --omit=dev @every/agent-browser \
 && npm cache clean --force \
 && mise reshim

# Claude Code CLI — official installer; no mise plugin available.
RUN curl -fsSL https://claude.ai/install.sh | bash \
 && test -x /root/.local/bin/claude

WORKDIR /app

# Ship the compiled source tree from build (lib, _build/prod, deps, priv,
# config, mix.exs/mix.lock) so `mix phx.server` can boot directly. mtimes are
# preserved by the stage-to-stage COPY, so mix's incremental compiler does
# not rebuild on first start.
COPY --from=build /app /app

COPY docker/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

VOLUME ["/root/.claude", "/root/.cache/destila", "/data"]

EXPOSE 4000

ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
