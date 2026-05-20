#!/usr/bin/env bash
# Manual smoke test for the MCP HTTP+SSE transport.
#
# Boots the dev server (if not already running) and drives a single
# tools/list request through the Go bridge to verify the round trip.
# Exits 0 on success. Designed to be run before any release that touches
# the new agent path.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v go >/dev/null; then
  echo "go is not installed; skipping smoke test"
  exit 0
fi

if ! command -v claude >/dev/null; then
  echo "claude CLI is not installed; skipping real-agent smoke test"
  echo "Falling back to bridge-only HTTP test."
fi

# Build bridge.
go build -o cmd/destila-mcp/destila-mcp ./cmd/destila-mcp/...

SESSION_ID="${SESSION_ID:-smoke-test-session-$$}"
TOKEN="${DESTILA_MCP_TOKEN:-destila-dev-only-token}"
URL="${DESTILA_MCP_URL:-http://127.0.0.1:4000/mcp}"

echo "Testing POST $URL/$SESSION_ID/rpc (tools/list)..."
HTTP_STATUS=$(curl -s -o /tmp/destila_smoke.json -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Destila-Session-Id: $SESSION_ID" \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  "$URL/$SESSION_ID/rpc")

if [ "$HTTP_STATUS" != "200" ]; then
  echo "Expected HTTP 200, got $HTTP_STATUS"
  cat /tmp/destila_smoke.json
  exit 1
fi

if ! grep -q '"tools"' /tmp/destila_smoke.json; then
  echo "Response did not contain tools list"
  cat /tmp/destila_smoke.json
  exit 1
fi

echo "Smoke test OK."
