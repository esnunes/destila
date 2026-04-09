defmodule DestilaWeb.MediaController do
  use DestilaWeb, :controller

  alias Destila.Workflows

  def show(conn, %{"id" => id}) do
    metadata = Workflows.get_metadata!(id)
    path = metadata.value["video_file"]
    %{size: size} = File.stat!(path)

    conn = put_resp_header(conn, "accept-ranges", "bytes")

    case get_req_header(conn, "range") do
      ["bytes=" <> range_spec] ->
        {start_pos, end_pos} = parse_range(range_spec, size)
        length = end_pos - start_pos + 1

        conn
        |> put_resp_header("content-type", "video/mp4")
        |> put_resp_header("content-range", "bytes #{start_pos}-#{end_pos}/#{size}")
        |> send_file(206, path, start_pos, length)

      _ ->
        conn
        |> put_resp_header("content-type", "video/mp4")
        |> send_file(200, path, 0, size)
    end
  end

  defp parse_range(range_spec, size) do
    case String.split(range_spec, "-", parts: 2) do
      [start_str, ""] ->
        start_pos = String.to_integer(start_str)
        {start_pos, size - 1}

      [start_str, end_str] ->
        {String.to_integer(start_str), String.to_integer(end_str)}
    end
  end
end
