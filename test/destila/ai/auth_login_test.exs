defmodule Destila.AI.AuthLoginTest do
  use ExUnit.Case, async: false

  alias Destila.AI.AuthLogin
  alias Destila.AI.AuthLoginHttpStub
  alias Destila.PubSubHelper

  setup do
    Phoenix.PubSub.subscribe(Destila.PubSub, PubSubHelper.claude_auth_login_topic())

    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "destila-auth-login-test-#{System.unique_integer([:positive])}.json"
      )

    Application.put_env(:destila, :auth_login_credential_store, :file)
    Application.put_env(:destila, :auth_login_credentials_path, tmp_path)
    Application.put_env(:destila, :auth_login_http_client, AuthLoginHttpStub)

    AuthLoginHttpStub.set_caller(self())
    AuthLoginHttpStub.set_response({:ok, %{status: 200, body: default_token_body()}})

    on_exit(fn ->
      case Process.whereis(AuthLogin) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal)
      end

      Application.delete_env(:destila, :auth_login_credential_store)
      Application.delete_env(:destila, :auth_login_credentials_path)
      Application.delete_env(:destila, :auth_login_http_client)
      Application.delete_env(:destila, AuthLoginHttpStub)
      File.rm(tmp_path)
    end)

    {:ok, credentials_path: tmp_path, http: AuthLoginHttpStub}
  end

  defp default_token_body do
    %{
      "access_token" => "sk-ant-oat01-test-access",
      "refresh_token" => "sk-ant-ort01-test-refresh",
      "expires_in" => 3600,
      "scope" => "user:profile user:inference",
      "subscription_type" => "max",
      "rate_limit_tier" => "default_claude_max_5x"
    }
  end

  describe "start/0" do
    test "broadcasts :awaiting_token with a generated authorize URL on first start" do
      :ok = AuthLogin.start()

      assert_receive {:claude_auth_login_state, %{state: :awaiting_token, url: url}}, 1_000
      assert is_binary(url)
      assert url =~ "https://claude.com/cai/oauth/authorize"
      assert url =~ "client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e"
      assert url =~ "code_challenge_method=S256"
      assert url =~ "code_challenge="
      assert url =~ "state="
      assert url =~ "code=true"
    end

    test "is idempotent when already running" do
      :ok = AuthLogin.start()
      assert_receive {:claude_auth_login_state, %{state: :awaiting_token}}, 1_000

      :ok = AuthLogin.start()
      refute_receive {:claude_auth_login_state, _}, 100
    end
  end

  describe "current/0" do
    test "returns idle snapshot when not running" do
      assert %{state: :idle, url: nil, error_message: nil} = AuthLogin.current()
    end

    test "reflects the current snapshot" do
      :ok = AuthLogin.start()
      assert_receive {:claude_auth_login_state, _}, 1_000

      assert %{state: :awaiting_token, url: url, error_message: nil} = AuthLogin.current()
      assert is_binary(url)
    end
  end

  describe "submit_token/1 — success path" do
    test "exchanges the code, persists credentials, transitions to :succeeded",
         %{credentials_path: path} do
      :ok = AuthLogin.start()
      assert_receive {:claude_auth_login_state, %{state: :awaiting_token}}, 1_000

      :ok = AuthLogin.submit_token("good-code")

      assert_receive {:claude_auth_login_state, %{state: :verifying}}, 1_000
      assert_receive {:http_post, _url, _opts}, 1_000
      assert_receive {:claude_auth_login_state, %{state: :succeeded}}, 1_000

      assert {:ok, content} = File.read(path)
      assert {:ok, decoded} = Jason.decode(content)

      assert %{
               "claudeAiOauth" => %{
                 "accessToken" => "sk-ant-oat01-test-access",
                 "refreshToken" => "sk-ant-ort01-test-refresh",
                 "scopes" => ["user:profile", "user:inference"],
                 "subscriptionType" => "max",
                 "rateLimitTier" => "default_claude_max_5x"
               }
             } = decoded
    end

    test "POSTs the expected body to the token endpoint" do
      :ok = AuthLogin.start()
      assert_receive {:claude_auth_login_state, %{state: :awaiting_token}}, 1_000

      :ok = AuthLogin.submit_token("the-code")

      assert_receive {:http_post, url, opts}, 1_000
      assert url == "https://api.anthropic.com/v1/oauth/token"

      body = Keyword.fetch!(opts, :json)
      assert body["grant_type"] == "authorization_code"
      assert body["code"] == "the-code"
      assert body["client_id"] == "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
      assert body["redirect_uri"] == "https://platform.claude.com/oauth/code/callback"
      assert is_binary(body["code_verifier"])
      assert byte_size(body["code_verifier"]) > 30
      assert is_binary(body["state"]) and byte_size(body["state"]) > 30
    end

    test "strips whitespace and accepts <code>#<state> form" do
      :ok = AuthLogin.start()
      assert_receive {:claude_auth_login_state, %{state: :awaiting_token}}, 1_000

      %{url: url} = AuthLogin.current()
      %URI{query: query} = URI.parse(url)
      oauth_state = URI.decode_query(query) |> Map.fetch!("state")

      :ok = AuthLogin.submit_token("  raw-code##{oauth_state}  ")

      assert_receive {:http_post, _url, opts}, 1_000
      assert Keyword.fetch!(opts, :json)["code"] == "raw-code"
    end
  end

  describe "submit_token/1 — failure paths" do
    test "rejects empty input as :invalid_token without HTTP" do
      :ok = AuthLogin.start()
      assert_receive {:claude_auth_login_state, %{state: :awaiting_token}}, 1_000

      :ok = AuthLogin.submit_token("   ")

      assert_receive {:claude_auth_login_state,
                      %{state: :invalid_token, error_message: "Authorization code is empty."}},
                     1_000

      refute_receive {:http_post, _, _}, 100
    end

    test "rejects mismatched OAuth state without HTTP" do
      :ok = AuthLogin.start()
      assert_receive {:claude_auth_login_state, %{state: :awaiting_token}}, 1_000

      :ok = AuthLogin.submit_token("real-code#tampered-state")

      assert_receive {:claude_auth_login_state, %{state: :invalid_token, error_message: msg}},
                     1_000

      assert msg =~ "OAuth state mismatch"
      refute_receive {:http_post, _, _}, 100
    end

    test "4xx response transitions to :invalid_token with the server message", %{http: http} do
      http.set_response(
        {:ok,
         %{
           status: 400,
           body: %{"error" => "invalid_grant", "error_description" => "code already used"}
         }}
      )

      :ok = AuthLogin.start()
      assert_receive {:claude_auth_login_state, %{state: :awaiting_token}}, 1_000

      :ok = AuthLogin.submit_token("stale-code")
      assert_receive {:claude_auth_login_state, %{state: :verifying}}, 1_000

      assert_receive {:claude_auth_login_state, %{state: :invalid_token, error_message: msg}},
                     1_000

      assert msg =~ "400"
      assert msg =~ "code already used"
    end

    test "surfaces Anthropic's nested {error: {type, message}} body", %{http: http} do
      http.set_response(
        {:ok,
         %{
           status: 400,
           body: %{
             "error" => %{
               "type" => "invalid_request_error",
               "message" => "code_verifier does not match"
             }
           }
         }}
      )

      :ok = AuthLogin.start()
      assert_receive {:claude_auth_login_state, %{state: :awaiting_token}}, 1_000

      :ok = AuthLogin.submit_token("any")

      assert_receive {:claude_auth_login_state, %{state: :invalid_token, error_message: msg}},
                     1_000

      assert msg =~ "400"
      assert msg =~ "invalid_request_error"
      assert msg =~ "code_verifier does not match"
    end

    test "5xx response transitions to :cli_failed", %{http: http} do
      http.set_response({:ok, %{status: 502, body: "Bad gateway"}})

      :ok = AuthLogin.start()
      assert_receive {:claude_auth_login_state, %{state: :awaiting_token}}, 1_000

      :ok = AuthLogin.submit_token("any")

      assert_receive {:claude_auth_login_state, %{state: :cli_failed, error_message: msg}}, 1_000
      assert msg =~ "502"
    end

    test "transport error transitions to :cli_failed", %{http: http} do
      http.set_response({:error, %{reason: :timeout}})

      :ok = AuthLogin.start()
      assert_receive {:claude_auth_login_state, %{state: :awaiting_token}}, 1_000

      :ok = AuthLogin.submit_token("any")

      assert_receive {:claude_auth_login_state, %{state: :cli_failed, error_message: msg}}, 1_000
      assert msg =~ "Token exchange failed"
    end

    test "returns {:error, :wrong_state} after a successful exchange" do
      :ok = AuthLogin.start()
      assert_receive {:claude_auth_login_state, %{state: :awaiting_token}}, 1_000

      :ok = AuthLogin.submit_token("good")
      assert_receive {:claude_auth_login_state, %{state: :succeeded}}, 1_000

      assert {:error, :wrong_state} = AuthLogin.submit_token("anything")
    end

    test "returns {:error, :not_running} when the GenServer is down" do
      assert {:error, :not_running} = AuthLogin.submit_token("anything")
    end
  end

  describe "restart/0" do
    test "rolls a fresh URL and clears any error", %{http: http} do
      http.set_response({:ok, %{status: 400, body: %{"error" => "bad"}}})
      :ok = AuthLogin.start()
      assert_receive {:claude_auth_login_state, %{state: :awaiting_token, url: first_url}}, 1_000

      :ok = AuthLogin.submit_token("x")
      assert_receive {:claude_auth_login_state, %{state: :verifying}}, 1_000
      assert_receive {:claude_auth_login_state, %{state: :invalid_token}}, 1_000

      http.set_response({:ok, %{status: 200, body: default_token_body()}})

      :ok = AuthLogin.restart()
      assert_receive {:claude_auth_login_state, %{state: :awaiting_token, url: second_url}}, 1_000
      assert second_url != first_url
    end

    test "returns {:error, :not_running} when the GenServer is down" do
      assert {:error, :not_running} = AuthLogin.restart()
    end
  end

  describe "stop/0" do
    test "stops a running GenServer" do
      :ok = AuthLogin.start()
      assert_receive {:claude_auth_login_state, _}, 1_000

      :ok = AuthLogin.stop()
      assert Process.whereis(AuthLogin) == nil
    end

    test "is a no-op when not running" do
      assert :ok = AuthLogin.stop()
    end
  end
end
