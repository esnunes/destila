defmodule Destila.AI.AuthLogin do
  @moduledoc """
  Globally-named singleton GenServer that drives the Claude OAuth login
  flow natively (without spawning `claude auth login`).

  The CLI's interactive prompt for the authorization code is unreliable
  over a PTY in current versions, so this module owns the OAuth dance
  end-to-end:

    * generate a PKCE code_verifier / code_challenge pair
    * build the authorization URL (`https://claude.com/cai/oauth/authorize?...`)
      and broadcast it for the UI to display
    * accept an authorization code via `submit_token/1` (the modal still
      calls it "token" for UX continuity; we accept either `<code>` or
      `<code>#<state>`)
    * POST `grant_type=authorization_code` with `code_verifier` to the
      token endpoint and persist the resulting credentials where the
      `claude` CLI looks for them: macOS keychain on Darwin,
      `~/.claude/.credentials.json` elsewhere
    * broadcast every state transition on
      `Destila.PubSubHelper.claude_auth_login_topic/0`

  ## Lifecycle

  Started lazily on demand. The first caller to `start/0` brings the
  server up; subsequent `start/0` calls are no-ops while the named
  process is alive. `stop/0` terminates the GenServer.
  """

  use GenServer

  alias Destila.PubSubHelper

  @authorize_url "https://claude.com/cai/oauth/authorize"
  @token_url "https://api.anthropic.com/v1/oauth/token"
  @client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  @redirect_uri "https://platform.claude.com/oauth/code/callback"
  @scopes "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

  @code_timeout_ms 600_000
  @exchange_timeout_ms 30_000
  @http_timeout_ms 25_000

  @type fsm_state ::
          :awaiting_token
          | :verifying
          | :invalid_token
          | :cli_failed
          | :succeeded

  @type snapshot :: %{
          state: fsm_state() | :idle,
          url: nil | binary(),
          error_message: nil | binary()
        }

  # --- Public API ---

  @doc """
  Starts the singleton, or no-ops if it is already running.
  """
  @spec start() :: :ok
  def start do
    case GenServer.start(__MODULE__, [], name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @doc """
  Returns the current snapshot. Returns the idle snapshot if the
  GenServer is not running.
  """
  @spec current() :: snapshot()
  def current do
    case Process.whereis(__MODULE__) do
      nil -> %{state: :idle, url: nil, error_message: nil}
      pid -> GenServer.call(pid, :current)
    end
  end

  @doc """
  Submits an authorization code. Only valid in the `:awaiting_token`
  state. Accepts the code in either `<code>` or `<code>#<state>` form.
  """
  @spec submit_token(binary()) :: :ok | {:error, :wrong_state | :not_running}
  def submit_token(code) when is_binary(code) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, {:submit_token, code})
    end
  end

  @doc """
  Restarts the auth flow with a fresh PKCE pair and URL.
  """
  @spec restart() :: :ok | {:error, :not_running}
  def restart do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, :restart)
    end
  end

  @doc """
  Stops the GenServer. No-op if not running.
  """
  @spec stop() :: :ok
  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    {:ok, fresh_state()}
  end

  @impl true
  def handle_call(:current, _from, state) do
    {:reply, snapshot(state), state}
  end

  def handle_call({:submit_token, raw}, _from, %{state: :awaiting_token} = state) do
    {code, returned_state} = parse_code_input(raw)

    cond do
      code == "" ->
        new_state = %{
          state
          | state: :invalid_token,
            error_message: "Authorization code is empty."
        }

        broadcast(new_state)
        {:reply, :ok, new_state}

      returned_state != nil and returned_state != state.oauth_state ->
        new_state = %{
          state
          | state: :invalid_token,
            error_message:
              "OAuth state mismatch — the code was issued in a different session. Restart and try again from the new URL."
        }

        broadcast(new_state)
        {:reply, :ok, new_state}

      true ->
        cancel_timer(state.code_timer)
        task = exchange_task(code, state.code_verifier, state.oauth_state)
        verdict_timer = Process.send_after(self(), :exchange_timeout, @exchange_timeout_ms)

        new_state = %{
          state
          | state: :verifying,
            code_timer: nil,
            verdict_timer: verdict_timer,
            exchange_task: task
        }

        broadcast(new_state)
        {:reply, :ok, new_state}
    end
  end

  def handle_call({:submit_token, _code}, _from, state) do
    {:reply, {:error, :wrong_state}, state}
  end

  def handle_call(:restart, _from, state) do
    cancel_timer(state.code_timer)
    cancel_timer(state.verdict_timer)
    cancel_task(state.exchange_task)

    new_state = fresh_state()
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:code_timeout, %{state: :awaiting_token} = state) do
    new_state = %{
      state
      | state: :cli_failed,
        code_timer: nil,
        error_message: "No authorization code submitted within 10 minutes. Restart to try again."
    }

    broadcast(new_state)
    {:noreply, new_state}
  end

  def handle_info(:code_timeout, state), do: {:noreply, %{state | code_timer: nil}}

  def handle_info(:exchange_timeout, %{state: :verifying} = state) do
    cancel_task(state.exchange_task)

    new_state = %{
      state
      | state: :cli_failed,
        verdict_timer: nil,
        exchange_task: nil,
        error_message: "Token exchange timed out after 30 seconds. Restart to try again."
    }

    broadcast(new_state)
    {:noreply, new_state}
  end

  def handle_info(:exchange_timeout, state), do: {:noreply, %{state | verdict_timer: nil}}

  def handle_info({ref, result}, %{exchange_task: %Task{ref: tref}} = state) when ref == tref do
    Process.demonitor(ref, [:flush])
    cancel_timer(state.verdict_timer)
    {:noreply, handle_exchange_result(state, result)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{exchange_task: %Task{ref: tref}} = state
      )
      when ref == tref do
    cancel_timer(state.verdict_timer)

    new_state = %{
      state
      | state: :cli_failed,
        verdict_timer: nil,
        exchange_task: nil,
        error_message: "Token exchange process crashed."
    }

    broadcast(new_state)
    {:noreply, new_state}
  end

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.code_timer)
    cancel_timer(state.verdict_timer)
    cancel_task(state.exchange_task)
    :ok
  end

  # --- Internal helpers ---

  defp fresh_state do
    verifier = random_token()
    challenge = code_challenge(verifier)
    oauth_state = random_token()
    url = build_authorize_url(challenge, oauth_state)
    code_timer = Process.send_after(self(), :code_timeout, @code_timeout_ms)

    state = %{
      state: :awaiting_token,
      url: url,
      code_verifier: verifier,
      oauth_state: oauth_state,
      error_message: nil,
      code_timer: code_timer,
      verdict_timer: nil,
      exchange_task: nil
    }

    broadcast(state)
    state
  end

  defp random_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp code_challenge(verifier) do
    :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
  end

  defp build_authorize_url(challenge, oauth_state) do
    query =
      URI.encode_query(%{
        "code" => "true",
        "client_id" => @client_id,
        "response_type" => "code",
        "redirect_uri" => @redirect_uri,
        "scope" => @scopes,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => oauth_state
      })

    @authorize_url <> "?" <> query
  end

  defp parse_code_input(input) do
    case input |> String.trim() |> String.split("#", parts: 2) do
      [code, state] -> {String.trim(code), String.trim(state)}
      [code] -> {String.trim(code), nil}
    end
  end

  defp exchange_task(code, verifier, oauth_state) do
    Task.async(fn -> exchange_code(code, verifier, oauth_state) end)
  end

  defp exchange_code(code, verifier, oauth_state) do
    body = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "state" => oauth_state,
      "redirect_uri" => @redirect_uri,
      "client_id" => @client_id,
      "code_verifier" => verifier
    }

    opts = [
      json: body,
      headers: [{"accept", "application/json"}],
      receive_timeout: @http_timeout_ms
    ]

    case http_client().post(@token_url, opts) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:status, status, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp http_client, do: Application.get_env(:destila, :auth_login_http_client, Req)

  defp handle_exchange_result(state, {:ok, body}) do
    case persist_credentials(body) do
      :ok ->
        new_state = %{
          state
          | state: :succeeded,
            verdict_timer: nil,
            exchange_task: nil,
            error_message: nil
        }

        broadcast(new_state)
        new_state

      {:error, reason} ->
        new_state = %{
          state
          | state: :cli_failed,
            verdict_timer: nil,
            exchange_task: nil,
            error_message: "Failed to persist credentials: #{reason}"
        }

        broadcast(new_state)
        new_state
    end
  end

  defp handle_exchange_result(state, {:error, {:status, status, body}}) do
    msg = error_message_from_response(status, body)

    fsm =
      case status do
        s when s in 400..499 -> :invalid_token
        _ -> :cli_failed
      end

    new_state = %{
      state
      | state: fsm,
        verdict_timer: nil,
        exchange_task: nil,
        error_message: msg
    }

    broadcast(new_state)
    new_state
  end

  defp handle_exchange_result(state, {:error, {:transport, reason}}) do
    new_state = %{
      state
      | state: :cli_failed,
        verdict_timer: nil,
        exchange_task: nil,
        error_message: "Token exchange failed: #{inspect(reason)}"
    }

    broadcast(new_state)
    new_state
  end

  defp error_message_from_response(status, %{"error_description" => desc}) when is_binary(desc),
    do: "Auth server returned #{status}: #{desc}"

  defp error_message_from_response(status, %{"error" => %{"message" => msg, "type" => type}})
       when is_binary(msg),
       do: "Auth server returned #{status} (#{type}): #{msg}"

  defp error_message_from_response(status, %{"error" => %{"message" => msg}}) when is_binary(msg),
    do: "Auth server returned #{status}: #{msg}"

  defp error_message_from_response(status, %{"error" => err}) when is_binary(err),
    do: "Auth server returned #{status}: #{err}"

  defp error_message_from_response(status, %{"message" => msg}) when is_binary(msg),
    do: "Auth server returned #{status}: #{msg}"

  defp error_message_from_response(status, body) when is_binary(body) and body != "",
    do: "Auth server returned #{status}: #{String.slice(body, 0, 200)}"

  defp error_message_from_response(status, body) when is_map(body) and map_size(body) > 0,
    do: "Auth server returned #{status}: #{Jason.encode!(body) |> String.slice(0, 200)}"

  defp error_message_from_response(status, _), do: "Auth server returned #{status}."

  defp persist_credentials(body) do
    payload = %{
      "claudeAiOauth" => %{
        "accessToken" => body["access_token"],
        "refreshToken" => body["refresh_token"],
        "expiresAt" => expires_at_ms(body["expires_in"]),
        "scopes" => body |> Map.get("scope", "") |> String.split(" ", trim: true),
        "subscriptionType" => body["subscription_type"],
        "rateLimitTier" => body["rate_limit_tier"]
      }
    }

    json = Jason.encode!(payload)

    case credential_store() do
      :macos_keychain -> persist_macos(json)
      :file -> persist_file(json)
    end
  end

  defp credential_store do
    case Application.get_env(:destila, :auth_login_credential_store) do
      nil ->
        case :os.type() do
          {:unix, :darwin} -> :macos_keychain
          _ -> :file
        end

      override ->
        override
    end
  end

  defp expires_at_ms(seconds) when is_integer(seconds),
    do: System.system_time(:millisecond) + seconds * 1000

  defp expires_at_ms(_), do: nil

  defp persist_macos(json) do
    user = System.get_env("USER") || System.get_env("LOGNAME") || "claude"

    args = [
      "add-generic-password",
      "-s",
      "Claude Code-credentials",
      "-a",
      user,
      "-w",
      json,
      "-U"
    ]

    case System.cmd("security", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, "security exited #{code}: #{String.trim(out)}"}
    end
  rescue
    e in ErlangError -> {:error, "security command failed: #{Exception.message(e)}"}
  end

  defp persist_file(json) do
    path = credentials_file_path()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, json),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} -> {:error, "writing #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp credentials_file_path do
    Application.get_env(
      :destila,
      :auth_login_credentials_path,
      Path.join(System.user_home!(), ".claude/.credentials.json")
    )
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp cancel_task(nil), do: :ok

  defp cancel_task(%Task{} = task) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp snapshot(state) do
    %{state: state.state, url: state.url, error_message: state.error_message}
  end

  defp broadcast(state) do
    PubSubHelper.broadcast_claude_auth_login(snapshot(state))
  end
end
