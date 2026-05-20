defmodule DestilaWeb.MCP.RpcControllerTest do
  use DestilaWeb.ConnCase

  alias Destila.Agent.Sessions

  @token "rpc-test-token"

  setup do
    prev_token = Application.get_env(:destila, :mcp_token)
    Application.put_env(:destila, :mcp_token, @token)
    on_exit(fn -> Application.put_env(:destila, :mcp_token, prev_token) end)
    :ok
  end

  test "POST tools/list with valid token returns the tool list", %{conn: conn} do
    {:ok, session} = Sessions.create_session(valid_attrs())

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{@token}")
      |> put_req_header("content-type", "application/json")
      |> post("/mcp/#{session.id}/rpc", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list"
      })

    assert json_response(conn, 200)["result"]["tools"] |> length() == 4
  end

  test "POST without token returns 401", %{conn: conn} do
    conn = post(conn, "/mcp/whatever/rpc", %{})
    assert conn.status == 401
  end

  test "X-Destila-Session-Id mismatch returns 400", %{conn: conn} do
    {:ok, session} = Sessions.create_session(valid_attrs())

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{@token}")
      |> put_req_header("x-destila-session-id", "OTHER-ID")
      |> put_req_header("content-type", "application/json")
      |> post("/mcp/#{session.id}/rpc", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list"
      })

    assert conn.status == 400
  end

  defp valid_attrs do
    %{workflow_name: "example", host_mode: :embedded, total_phases: 1}
  end
end
