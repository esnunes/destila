# MCP smoke test

Manual smoke test for the HTTP+SSE MCP transport. Lives in
`scripts/mcp_smoke.sh`.

## When to run it

Before any release that touches the new agent path (anything under
`lib/destila/agent/`, `lib/destila_web/mcp/`, or `cmd/destila-mcp/`).

## How to run it

1. Start the dev server:
   ```sh
   elixir --sname destila -S mix phx.server
   ```
2. In another shell:
   ```sh
   ./scripts/mcp_smoke.sh
   ```

The script:
- Builds the Go bridge into `cmd/destila-mcp/destila-mcp`.
- POSTs a `tools/list` JSON-RPC envelope at `/mcp/<session_id>/rpc` with the
  default dev token.
- Asserts HTTP 200 and a `"tools"` field in the response.

Set `DESTILA_MCP_TOKEN` and `DESTILA_MCP_URL` to override defaults.

## Troubleshooting

- `401 unauthorized` — your `DESTILA_MCP_TOKEN` doesn't match the dev
  default `destila-dev-only-token`. Set the env var to match.
- `connection refused` — the dev server isn't running, or it's on a
  different port. Check `config/dev.exs` and `PORT`.
- The script intentionally does not attempt to drive a real `claude`
  CLI when the binary is not installed.
