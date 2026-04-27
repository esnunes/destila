defmodule Destila.Services.Url do
  @moduledoc """
  Single, side-effect-free helper that computes the advertised URL for a
  project or session service.

  Resolution order:

    1. If service_state is missing, status is not "running", or port is not
       an integer — return `nil`.
    2. If `service_state["caddy_route"]` is not `true` — return the
       localhost URL `"http://localhost:<port>"`.
    3. For sessions: host = `"<id>.<base_domain>"`.
    4. For projects: host = the project's `domain` (trimmed). If blank,
       fall back to localhost.
    5. Scheme is `"http"` for hosts in the localhost family
       (`localhost` or `*.localhost`), else `"https"`.
  """

  alias Destila.Projects.Project
  alias Destila.Proxy.Caddy
  alias Destila.Proxy.Config

  @spec for_session(map()) :: String.t() | nil
  def for_session(%{id: id, service_state: state}) when is_binary(id) do
    case localhost_url(state) do
      nil -> nil
      localhost -> resolve_session(id, state, localhost)
    end
  end

  def for_session(_), do: nil

  @spec for_project(Project.t()) :: String.t() | nil
  def for_project(%Project{service_state: state, domain: domain}) do
    case localhost_url(state) do
      nil -> nil
      localhost -> resolve_project(domain, state, localhost)
    end
  end

  def for_project(_), do: nil

  defp localhost_url(state) do
    with state when is_map(state) <- state,
         "running" <- Map.get(state, "status"),
         port when is_integer(port) <- Map.get(state, "port") do
      "http://localhost:#{port}"
    else
      _ -> nil
    end
  end

  defp resolve_session(id, state, localhost) do
    if state["caddy_route"] == true do
      build_url(id <> "." <> Config.base_domain())
    else
      localhost
    end
  end

  defp resolve_project(domain, state, localhost) do
    cond do
      state["caddy_route"] != true -> localhost
      blank?(domain) -> localhost
      true -> build_url(String.trim(domain))
    end
  end

  defp build_url(host) do
    Caddy.scheme_for(host) <> "://" <> host
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: true
end
