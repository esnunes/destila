#!/bin/sh
#
# Destila container entrypoint.
#
# Runs database migrations (via `Destila.Release.migrate/0`), then
# replaces the shell with the release start script. Migration failure
# must exit non-zero so Docker surfaces the problem instead of serving
# against an unmigrated DB.

set -eu

cd -P -- "$(dirname -- "$0")/.."

echo "[destila] running migrations"
./bin/migrate

echo "[destila] starting server"
exec ./bin/destila start
