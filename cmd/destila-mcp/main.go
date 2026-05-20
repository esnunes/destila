// Destila MCP bridge.
//
// Speaks stdio-MCP on its inward face (to claude) and translates each
// tools/call (and other JSON-RPC methods) to Destila's HTTP+SSE endpoint
// on its outward face. The bridge insulates Destila from changes in the
// MCP wire protocol — only this binary needs to track upstream MCP drift.
//
// Environment variables required:
//   DESTILA_SESSION_ID  - per-session id chosen by Destila
//   DESTILA_MCP_TOKEN   - global bearer token
//   DESTILA_MCP_URL     - e.g. http://127.0.0.1:4000/mcp
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"

	"github.com/destila/destila-mcp/internal/httpclient"
	"github.com/destila/destila-mcp/internal/mcpstdio"
)

func main() {
	sessionID := os.Getenv("DESTILA_SESSION_ID")
	token := os.Getenv("DESTILA_MCP_TOKEN")
	url := os.Getenv("DESTILA_MCP_URL")

	if sessionID == "" || token == "" || url == "" {
		fmt.Fprintln(os.Stderr, "DESTILA_SESSION_ID, DESTILA_MCP_TOKEN, DESTILA_MCP_URL must be set")
		os.Exit(2)
	}

	client := httpclient.New(url, token, sessionID, http.DefaultClient)

	stdin := bufio.NewReader(os.Stdin)
	stdout := os.Stdout

	for {
		msg, err := mcpstdio.ReadMessage(stdin)
		if err == io.EOF {
			return
		}
		if err != nil {
			fmt.Fprintf(os.Stderr, "bridge read error: %v\n", err)
			return
		}

		// Forward to Destila as JSON-RPC over HTTP.
		respBody, err := client.PostRPC(msg)
		if err != nil {
			writeErrorResponse(stdout, msg, fmt.Sprintf("HTTP error: %v", err))
			continue
		}

		if len(respBody) == 0 {
			// 204 No Content — notifications produce no reply.
			continue
		}

		// Validate JSON and forward verbatim.
		var anyJSON json.RawMessage
		if err := json.Unmarshal(respBody, &anyJSON); err != nil {
			writeErrorResponse(stdout, msg, fmt.Sprintf("invalid response from server: %v", err))
			continue
		}

		if err := mcpstdio.WriteMessage(stdout, respBody); err != nil {
			fmt.Fprintf(os.Stderr, "bridge write error: %v\n", err)
			return
		}
	}
}

func writeErrorResponse(w io.Writer, req json.RawMessage, message string) {
	var parsed struct {
		ID json.RawMessage `json:"id"`
	}
	_ = json.Unmarshal(req, &parsed)

	resp, _ := json.Marshal(map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      parsed.ID,
		"error":   map[string]interface{}{"code": -32603, "message": message},
	})

	_ = mcpstdio.WriteMessage(w, resp)
}
