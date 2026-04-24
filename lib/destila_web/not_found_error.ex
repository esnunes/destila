defmodule DestilaWeb.NotFoundError do
  @moduledoc """
  Raised from a LiveView mount to surface an HTTP 404 to the client.
  `Plug.Exception` maps this to status 404 via `plug_status: 404`.
  """

  defexception message: "Not Found", plug_status: 404
end
