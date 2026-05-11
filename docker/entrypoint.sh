#!/bin/sh
#
# Destila container entrypoint.
#
# 1. Runs Ecto migrations against the database at $DATABASE_PATH.
# 2. Boots the server with the same command Destila uses to launch its
#    own managed services, redirecting all output to
#    $HOME/.cache/destila/services/project-destila-main.log so the log
#    surfaces on the host through the /root/.cache/destila volume.
#
# `set -eu` ensures migration failure exits non-zero so Docker surfaces
# the problem instead of serving against an unmigrated DB.

set -eu

cd -P -- "$(dirname -- "$0")"

LOG_DIR="$HOME/.cache/destila/services"
LOG_FILE="$LOG_DIR/project-destila-main.log"
mkdir -p "$LOG_DIR"

echo "[destila] running migrations"
mix ecto.migrate

echo "[destila] starting server (logs: $LOG_FILE)"
exec elixir --sname destila -S mix phx.server >"$LOG_FILE" 2>&1
