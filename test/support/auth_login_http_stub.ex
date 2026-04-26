defmodule Destila.AI.AuthLoginHttpStub do
  @moduledoc """
  Stub HTTP client for `Destila.AI.AuthLogin` unit tests.

  Tests configure the next response via `set_response/1` and the pid that
  should receive `{:http_post, url, opts}` messages via `set_caller/1`.
  Wired up in tests by setting `:auth_login_http_client` to this module.
  """

  def set_response(response) do
    config = Application.get_env(:destila, __MODULE__, [])
    Application.put_env(:destila, __MODULE__, Keyword.put(config, :response, response))
  end

  def set_caller(pid) do
    config = Application.get_env(:destila, __MODULE__, [])
    Application.put_env(:destila, __MODULE__, Keyword.put(config, :caller, pid))
  end

  def post(url, opts) do
    config = Application.fetch_env!(:destila, __MODULE__)

    if caller = Keyword.get(config, :caller) do
      send(caller, {:http_post, url, opts})
    end

    Keyword.fetch!(config, :response)
  end
end
