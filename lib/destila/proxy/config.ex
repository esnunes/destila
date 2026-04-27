defmodule Destila.Proxy.Config do
  @moduledoc """
  Reads runtime configuration for the Caddy reverse proxy integration.

  The four advertised env vars are populated into `Application.get_env(:destila, :proxy, [])`
  at boot from `config/runtime.exs`. Tests inject overrides via `Application.put_env/3`.
  """

  @default_base_domain "localhost"
  @default_admin_url "http://localhost:2019"

  def base_domain, do: get(:base_domain, @default_base_domain)

  def admin_url, do: get(:admin_url, @default_admin_url)

  def basic_auth_user, do: get(:basic_auth_user, nil)

  def basic_auth_password, do: get(:basic_auth_password, nil)

  @doc """
  Extra options merged into every Caddy `Req` request. Tests override this
  with `plug: {Req.Test, Destila.Proxy.Caddy}` to stub HTTP responses.
  """
  def req_options, do: get(:req_options, [])

  defp get(key, default) do
    :destila
    |> Application.get_env(:proxy, [])
    |> Keyword.get(key, default)
  end
end
