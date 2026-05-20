// Package httpclient is the bridge's outward face to Destila.
//
// Sends each JSON-RPC message as a POST to /mcp/<sessionID>/rpc with a
// Bearer token, an X-Destila-Session-Id header, and an X-Destila-Bridge-Version
// header. Returns the raw response body (or empty for HTTP 204).
package httpclient

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
)

const BridgeVersion = "0.1.0"

type Client struct {
	BaseURL   string
	Token     string
	SessionID string
	HTTP      *http.Client
}

func New(baseURL, token, sessionID string, httpClient *http.Client) *Client {
	if httpClient == nil {
		httpClient = http.DefaultClient
	}
	return &Client{BaseURL: baseURL, Token: token, SessionID: sessionID, HTTP: httpClient}
}

func (c *Client) PostRPC(payload json.RawMessage) ([]byte, error) {
	url := fmt.Sprintf("%s/%s/rpc", c.BaseURL, c.SessionID)

	req, err := http.NewRequest("POST", url, bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+c.Token)
	req.Header.Set("X-Destila-Session-Id", c.SessionID)
	req.Header.Set("X-Destila-Bridge-Version", BridgeVersion)

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	if resp.StatusCode == http.StatusNoContent {
		return nil, nil
	}

	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("destila returned HTTP %d: %s", resp.StatusCode, string(body))
	}

	return body, nil
}
