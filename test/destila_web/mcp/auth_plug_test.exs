defmodule DestilaWeb.MCP.AuthPlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias DestilaWeb.MCP.AuthPlug

  setup do
    prev = Application.get_env(:destila, :mcp_token)
    Application.put_env(:destila, :mcp_token, "test-token-abc")

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:destila, :mcp_token)
        v -> Application.put_env(:destila, :mcp_token, v)
      end
    end)

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
