// Package mcpstdio implements LSP-style framed JSON-RPC over stdio.
//
// Each message is preceded by a `Content-Length: <N>\r\n\r\n` header.
// This is the framing the Claude Code MCP client uses on stdio transports.
package mcpstdio

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// ReadMessage reads one framed JSON message from r. Returns the raw JSON body.
func ReadMessage(r *bufio.Reader) (json.RawMessage, error) {
	var contentLength int

	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return nil, err
		}
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			break
		}
		if strings.HasPrefix(strings.ToLower(line), "content-length:") {
			v := strings.TrimSpace(line[len("Content-Length:"):])
			n, err := strconv.Atoi(v)
			if err != nil {
				return nil, fmt.Errorf("invalid Content-Length: %w", err)
			}
			contentLength = n
		}
	}

	if contentLength <= 0 {
		return nil, fmt.Errorf("missing or zero Content-Length")
	}

	buf := make([]byte, contentLength)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, err
	}

	return buf, nil
}

// WriteMessage writes one framed JSON message to w.
func WriteMessage(w io.Writer, payload []byte) error {
	header := fmt.Sprintf("Content-Length: %d\r\n\r\n", len(payload))
	if _, err := w.Write([]byte(header)); err != nil {
		return err
	}
	_, err := w.Write(payload)
	return err
}
