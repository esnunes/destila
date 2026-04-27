defmodule Destila.Proxy.Caddy do
  @moduledoc """
  Wraps Caddy's admin HTTP API for register / unregister of single routes
  associated with Destila project and session services.

  Public surface:

    * `register/2` — given a `%Destila.Services.Target{}` and a port, probe
      Caddy and POST a route under a deterministic `@id`. Returns
      `{:ok, :registered | :no_proxy} | {:error, term}`.
    * `unregister/1` — DELETE the route by deterministic `@id`. Returns
      `:ok | {:error, term}`.
    * `preflight/1` — checks that basic-auth credentials are configured
      when the target requires them. Probes Caddy first; when Caddy is
      unreachable, returns `:ok` so the local service can still start
      (it will register with `:no_proxy`). Missing credentials only
      block start when a proxy is actually available.
    * `probe/0` — TCP/HTTP reachability probe of the admin URL.

  All HTTP calls go through `Req`. Tests inject a `plug` via
  `Destila.Proxy.Config.req_options/0`.

  Routes are inserted into the fixed Caddy server name `srv0`.
  """

  alias Destila.Proxy.Config
  alias Destila.Services.Target
  import Destila.StringHelper, only: [blank?: 1]
  require Logger

  @server_name "srv0"
  @probe_timeout_ms 500
  @persistent_term_key {__MODULE__, :password_hash}

  # ─── Public API ────────────────────────────────────────────────────────

  @spec register(Target.t(), pos_integer()) ::
          {:ok, :registered | :no_proxy} | {:error, term()}
  def register(%Target{} = target, port) when is_integer(port) do
    cond do
      is_nil(host_for(target)) ->
        {:ok, :no_proxy}

      basic_auth_required?(target) and not credentials_configured?() ->
        {:error, :missing_credentials}

      true ->
        case probe() do
          :ok -> do_register(target, port)
          :unreachable -> {:ok, :no_proxy}
        end
    end
  end

  @spec unregister(Target.t()) :: :ok | {:error, term()}
  def unregister(%Target{} = target) do
    case probe() do
      :unreachable ->
        :ok

      :ok ->
        case delete_route(route_id(target)) do
          :ok -> :ok
          {:error, _} = err -> err
        end
    end
  end

  @spec preflight(Target.t()) :: :ok | {:error, :missing_credentials}
  def preflight(%Target{} = target) do
    cond do
      is_nil(host_for(target)) -> :ok
      not basic_auth_required?(target) -> :ok
      credentials_configured?() -> :ok
      probe() == :unreachable -> :ok
      true -> {:error, :missing_credentials}
    end
  end

  @spec probe() :: :ok | :unreachable
  def probe do
    options =
      [
        url: Config.admin_url() <> "/config/",
        connect_options: [timeout: @probe_timeout_ms],
        receive_timeout: @probe_timeout_ms,
        retry: false
      ]
      |> Keyword.merge(Config.req_options())

    case Req.request(Keyword.put(options, :method, :get)) do
      {:ok, %Req.Response{status: 200}} -> :ok
      _ -> :unreachable
    end
  end

  # ─── Pure helpers ──────────────────────────────────────────────────────

  @spec route_id(Target.t()) :: String.t()
  def route_id(%Target{kind: :project, id: id}), do: "destila-project-" <> id
  def route_id(%Target{kind: :session, id: id}), do: "destila-session-" <> id

  @spec host_for(Target.t()) :: String.t() | nil
  def host_for(%Target{kind: :session, id: id}) do
    id <> "." <> Config.base_domain()
  end

  def host_for(%Target{kind: :project, project: %{domain: domain}}) when is_binary(domain) do
    case String.trim(domain) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def host_for(%Target{kind: :project}), do: nil

  @spec scheme_for(String.t()) :: String.t()
  def scheme_for(host) when is_binary(host) do
    if host == "localhost" or String.ends_with?(host, ".localhost") do
      "http"
    else
      "https"
    end
  end

  @spec basic_auth_required?(Target.t()) :: boolean()
  def basic_auth_required?(%Target{kind: :session}), do: true

  def basic_auth_required?(%Target{kind: :project, project: %{basic_auth_enabled: enabled}}) do
    enabled == true
  end

  def basic_auth_required?(%Target{kind: :project}), do: false

  @doc """
  Builds the Caddy admin route JSON payload for the given target.
  """
  @spec route_json(Target.t(), pos_integer(), boolean()) :: map()
  def route_json(%Target{} = target, port, basic_auth?) when is_integer(port) do
    host = host_for(target)
    auth_handler = if basic_auth?, do: [authentication_handler()], else: []

    %{
      "@id" => route_id(target),
      "match" => [%{"host" => [host]}],
      "handle" =>
        auth_handler ++
          [
            %{
              "handler" => "reverse_proxy",
              "upstreams" => [%{"dial" => "127.0.0.1:" <> Integer.to_string(port)}]
            }
          ],
      "terminal" => true
    }
  end

  # ─── Private ───────────────────────────────────────────────────────────

  defp do_register(target, port) do
    route_id = route_id(target)
    basic_auth? = basic_auth_required?(target)

    case delete_route(route_id) do
      :ok ->
        :ok

      {:error, {:caddy_status, status, _body}} ->
        Logger.warning(
          "Destila.Proxy.Caddy: pre-register DELETE returned #{status} for #{route_id}; continuing"
        )

      {:error, {:transport, reason}} ->
        Logger.warning(
          "Destila.Proxy.Caddy: pre-register DELETE transport error for #{route_id}: #{inspect(reason)}; continuing"
        )
    end

    payload = route_json(target, port, basic_auth?)
    post_route(payload)
  end

  defp post_route(payload) do
    options =
      [
        url: Config.admin_url() <> "/config/apps/http/servers/" <> @server_name <> "/routes",
        json: payload,
        headers: [{"accept", "application/json"}],
        connect_options: [timeout: 5_000],
        receive_timeout: 5_000,
        retry: false
      ]
      |> Keyword.merge(Config.req_options())

    case Req.request(Keyword.put(options, :method, :post)) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:ok, :registered}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:caddy_status, status, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp delete_route(route_id) do
    options =
      [
        url: Config.admin_url() <> "/id/" <> route_id,
        connect_options: [timeout: 5_000],
        receive_timeout: 5_000,
        retry: false
      ]
      |> Keyword.merge(Config.req_options())

    case Req.request(Keyword.put(options, :method, :delete)) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: 404}} -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:caddy_status, status, body}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  defp credentials_configured? do
    not blank?(Config.basic_auth_user()) and not blank?(Config.basic_auth_password())
  end

  defp authentication_handler do
    %{
      "handler" => "authentication",
      "providers" => %{
        "http_basic" => %{
          "realm" => "Destila",
          "accounts" => [
            %{
              "username" => Config.basic_auth_user(),
              "password" => password_hash()
            }
          ]
        }
      }
    }
  end

  defp password_hash do
    raw = Config.basic_auth_password()
    fingerprint = :crypto.hash(:sha256, raw || "")

    case :persistent_term.get(@persistent_term_key, :none) do
      {^fingerprint, hash} ->
        hash

      _ ->
        hash = Bcrypt.hash_pwd_salt(raw || "")
        :persistent_term.put(@persistent_term_key, {fingerprint, hash})
        hash
    end
  end
end
