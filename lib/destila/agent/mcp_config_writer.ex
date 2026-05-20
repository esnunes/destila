defmodule Destila.Agent.McpConfigWriter do
  @moduledoc """
  Writes a per-session `.mcp.json` for the embedded `claude` agent and the
  system-prompt file. Both files live in a per-session tmpdir.
  """

  @doc """
  Writes the `.mcp.json` and system-prompt files for the given session/phase.

  Returns `{:ok, %{mcp_config_path: ..., system_prompt_path: ..., tmpdir: ...}}`.
  """
  def write(session_id, phase) do
    tmpdir = Path.join([System.tmp_dir!(), "destila-mcp-#{session_id}"])
    File.mkdir_p!(tmpdir)

    mcp_config_path = Path.join(tmpdir, "mcp.json")
    system_prompt_path = Path.join(tmpdir, "system_prompt.md")

    File.write!(mcp_config_path, render_mcp_config(session_id))
    File.write!(system_prompt_path, phase.system_prompt)

    {:ok,
     %{
       mcp_config_path: mcp_config_path,
       system_prompt_path: system_prompt_path,
       tmpdir: tmpdir
     }}
  end

  def cleanup(session_id) do
    tmpdir = Path.join([System.tmp_dir!(), "destila-mcp-#{session_id}"])
    File.rm_rf(tmpdir)
    :ok
  end

  defp render_mcp_config(session_id) do
    bridge_path =
      Application.get_env(:destila, :mcp_bridge_path) ||
        Path.expand("../cmd/destila-mcp/destila-mcp", __DIR__)

    token = Application.fetch_env!(:destila, :mcp_token)

    url =
      System.get_env("DESTILA_MCP_URL") ||
        "http://127.0.0.1:#{port_from_env()}/mcp"

    config = %{
      "mcpServers" => %{
        "destila" => %{
          "command" => bridge_path,
          "args" => [],
          "env" => %{
            "DESTILA_SESSION_ID" => session_id,
            "DESTILA_MCP_TOKEN" => token,
            "DESTILA_MCP_URL" => url
          }
        }
      }
    }

    Jason.encode!(config, pretty: true)
  end

  defp port_from_env do
    case Application.get_env(:destila, DestilaWeb.Endpoint) do
      nil -> "4000"
      endpoint -> endpoint |> Keyword.get(:http, []) |> Keyword.get(:port, 4000) |> to_string()
    end
  end
end
