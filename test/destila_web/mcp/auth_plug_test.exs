defmodule DestilaWeb.MCP.AuthPlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias DestilaWeb.MCP.AuthPlug

  setup do
    Application.put_env(:destila, :mcp_token, "test-token-abc")
    on_exit(fn -> Application.delete_env(:destila, :mcp_token) end)
    :ok
  end

  test "missing header returns 401" do
    conn = conn(:post, "/mcp/foo/rpc") |> AuthPlug.call(nil)
    assert conn.status == 401
    assert conn.halted
  end

  test "wrong token returns 401" do
    conn =
      conn(:post, "/mcp/foo/rpc")
      |> put_req_header("authorization", "Bearer wrong")
      |> AuthPlug.call(nil)

    assert conn.status == 401
    assert conn.halted
  end

  test "correct token passes through" do
    conn =
      conn(:post, "/mcp/foo/rpc")
      |> put_req_header("authorization", "Bearer test-token-abc")
      |> AuthPlug.call(nil)

    refute conn.halted
  end
end
