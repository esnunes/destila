# destila-mcp

Stdio MCP bridge that translates `claude` CLI tool calls to Destila's
HTTP+SSE endpoint.

## Build

```sh
cd cmd/destila-mcp
go build -o destila-mcp ./...
```

The resulting binary is referenced from Destila's per-session
`.mcp.json` files (see `Destila.Agent.McpConfigWriter`).

## Environment

| Variable             | Purpose                                       |
|----------------------|-----------------------------------------------|
| `DESTILA_SESSION_ID` | The agent session id chosen by Destila        |
| `DESTILA_MCP_TOKEN`  | Bearer token (same as `:destila, :mcp_token`) |
| `DESTILA_MCP_URL`    | e.g. `http://127.0.0.1:4000/mcp`              |

## Scope

This bridge implements only the subset of MCP needed by Claude Code:

- `initialize`
- `tools/list`
- `tools/call`
- `notifications/initialized`
- `notifications/cancelled`
- `ping`

It forwards each frame verbatim to Destila — wire-protocol changes can be
absorbed here without touching the Elixir code.
