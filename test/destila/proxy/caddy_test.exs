defmodule Destila.Proxy.CaddyTest do
  @moduledoc """
  Tests for `Destila.Proxy.Caddy` — covers pure helpers, the probe-then-call
  HTTP path, idempotent DELETE-then-POST, and basic-auth credential
  preflighting.

  Stubs HTTP via `Req.Test` plug — see
  https://hexdocs.pm/req/Req.Test.html. The Caddy admin URL points at the
  stub plug owner and `Application.put_env/3` injects `plug:` into every
  Req call through `Destila.Proxy.Config.req_options/0`.

  Feature: features/caddy_proxy.feature
  """

  use ExUnit.Case, async: false

  alias Destila.Projects.Project
  alias Destila.Proxy.Caddy
  alias Destila.Services.Target

  @feature "caddy_proxy"

  setup do
    original = Application.get_env(:destila, :proxy)

    Application.put_env(:destila, :proxy,
      base_domain: "example.com",
      admin_url: "http://caddy.test:2019",
      basic_auth_user: "alice",
      basic_auth_password: "secret",
      req_options: [plug: {Req.Test, Caddy}]
    )

    # Reset cached bcrypt hash between tests so the first hash counter starts fresh.
    :persistent_term.erase({Caddy, :password_hash})

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:destila, :proxy)
      else
        Application.put_env(:destila, :proxy, original)
      end
    end)

    :ok
  end

  defp project_target(domain \\ "myapp.example.com", basic_auth_enabled \\ false) do
    %Target{
      kind: :project,
      id: "abc-123",
      cwd: "/tmp",
      tmux_session_name: "destila-service-project-abc-123",
      tmux_window: 0,
      log_key: "project-abc-123",
      pubsub_topic: "service:project-abc-123",
      run_command: "mix phx.server",
      setup_command: nil,
      service_env_var: "PORT",
      project: %Project{
        id: "abc-123",
        name: "Test",
        domain: domain,
        basic_auth_enabled: basic_auth_enabled
      },
      workflow_session: nil
    }
  end

  defp session_target(id \\ "sess-1") do
    %Target{
      kind: :session,
      id: id,
      cwd: "/tmp",
      tmux_session_name: "session-" <> id,
      tmux_window: 9,
      log_key: "session-" <> id,
      pubsub_topic: "service:" <> id,
      run_command: "mix phx.server",
      setup_command: nil,
      service_env_var: "PORT",
      project: nil,
      workflow_session: nil
    }
  end

  defp set_credentials(user, password) do
    proxy = Application.get_env(:destila, :proxy)

    Application.put_env(
      :destila,
      :proxy,
      proxy
      |> Keyword.put(:basic_auth_user, user)
      |> Keyword.put(:basic_auth_password, password)
    )
  end

  defp record_call(conn, agent) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    Agent.update(agent, fn calls -> calls ++ [{conn.method, conn.request_path, body}] end)
    conn
  end

  defp recorded_calls(agent), do: Agent.get(agent, & &1)

  defp start_call_recorder do
    {:ok, pid} = Agent.start_link(fn -> [] end)
    pid
  end

  defp existing_config do
    %{
      "apps" => %{
        "http" => %{"servers" => %{"srv0" => %{"listen" => [":80"], "routes" => []}}}
      }
    }
  end

  describe "route_id/1" do
    @tag feature: @feature,
         scenario:
           "Project service start registers a Caddy route with a deterministic @id when domain is set"
    test "returns deterministic id for project target" do
      assert Caddy.route_id(project_target()) == "destila-project-abc-123"
    end

    @tag feature: @feature,
         scenario: "Session service start always registers a route at <session_id>.<base_domain>"
    test "returns deterministic id for session target" do
      assert Caddy.route_id(session_target("sess-xyz")) == "destila-session-sess-xyz"
    end
  end

  describe "host_for/1" do
    test "session target uses <id>.<base_domain>" do
      assert Caddy.host_for(session_target("sess-1")) == "sess-1.example.com"
    end

    test "project target uses project.domain" do
      assert Caddy.host_for(project_target("myapp.example.com")) == "myapp.example.com"
    end

    test "project target with blank domain returns nil" do
      assert Caddy.host_for(project_target("")) == nil
    end

    test "project target with nil domain returns nil" do
      assert Caddy.host_for(project_target(nil)) == nil
    end
  end

  describe "scheme_for/1" do
    test "returns http for localhost family" do
      assert Caddy.scheme_for("localhost") == "http"
      assert Caddy.scheme_for("x.localhost") == "http"
      assert Caddy.scheme_for("deep.nested.localhost") == "http"
    end

    test "returns https for non-localhost" do
      assert Caddy.scheme_for("example.com") == "https"
      assert Caddy.scheme_for("x.example.com") == "https"
    end
  end

  describe "register/2 with no domain" do
    @tag feature: @feature,
         scenario: "Project service start makes no Caddy calls when no domain is set"
    test "project with no domain returns :no_proxy and makes zero HTTP calls" do
      agent = start_call_recorder()

      Req.Test.stub(Caddy, fn conn ->
        record_call(conn, agent)
        Req.Test.json(conn, %{})
      end)

      assert Caddy.register(project_target(""), 4321) == {:ok, :no_proxy}
      assert recorded_calls(agent) == []
    end

    test "project with no domain ignores missing creds" do
      set_credentials(nil, nil)

      assert Caddy.register(project_target("", true), 4321) == {:ok, :no_proxy}
    end
  end

  describe "register/2 happy path" do
    @tag feature: @feature,
         scenario: "Session service start always wraps the route in basic auth"
    test "session: probe + DELETE + POST in order with valid payload" do
      agent = start_call_recorder()

      Req.Test.stub(Caddy, fn conn ->
        record_call(conn, agent)

        case {conn.method, conn.request_path} do
          {"GET", "/config/"} ->
            Req.Test.json(conn, existing_config())

          {"DELETE", "/id/destila-session-sess-1"} ->
            Req.Test.json(conn, %{})

          {"POST", "/config/apps/http/servers/srv0/routes"} ->
            Req.Test.json(conn, %{})
        end
      end)

      assert Caddy.register(session_target("sess-1"), 4321) == {:ok, :registered}

      calls = recorded_calls(agent)
      assert length(calls) == 3
      [{m1, p1, _}, {m2, p2, _}, {m3, p3, body3}] = calls

      assert {m1, p1} == {"GET", "/config/"}
      assert {m2, p2} == {"DELETE", "/id/destila-session-sess-1"}
      assert {m3, p3} == {"POST", "/config/apps/http/servers/srv0/routes"}

      payload = Jason.decode!(body3)
      assert payload["@id"] == "destila-session-sess-1"
      assert payload["match"] == [%{"host" => ["sess-1.example.com"]}]
      assert payload["terminal"] == true
      handlers = payload["handle"]
      assert length(handlers) == 2
      [auth, proxy] = handlers
      assert auth["handler"] == "authentication"
      [account] = auth["providers"]["http_basic"]["accounts"]
      assert account["username"] == "alice"
      assert String.starts_with?(account["password"], "$2")
      assert proxy["handler"] == "reverse_proxy"
      assert proxy["upstreams"] == [%{"dial" => "127.0.0.1:4321"}]
    end

    @tag feature: @feature,
         scenario: "Two projects sharing the same domain both register their routes"
    test "two projects with the same domain both register under distinct @ids" do
      agent = start_call_recorder()

      Req.Test.stub(Caddy, fn conn ->
        record_call(conn, agent)

        case {conn.method, conn.request_path} do
          {"GET", "/config/"} -> Req.Test.json(conn, existing_config())
          {"DELETE", _} -> Req.Test.json(conn, %{})
          {"POST", _} -> Req.Test.json(conn, %{})
        end
      end)

      base = project_target("shared.example.com", false)
      target_a = %{base | id: "proj-a", project: %{base.project | id: "proj-a"}}
      target_b = %{base | id: "proj-b", project: %{base.project | id: "proj-b"}}

      assert Caddy.register(target_a, 4321) == {:ok, :registered}
      assert Caddy.register(target_b, 4322) == {:ok, :registered}

      posts =
        agent
        |> recorded_calls()
        |> Enum.filter(fn {method, _, _} -> method == "POST" end)

      assert length(posts) == 2
      [{_, _, body_a}, {_, _, body_b}] = posts

      payload_a = Jason.decode!(body_a)
      payload_b = Jason.decode!(body_b)

      assert payload_a["@id"] == "destila-project-proj-a"
      assert payload_b["@id"] == "destila-project-proj-b"
      assert payload_a["match"] == [%{"host" => ["shared.example.com"]}]
      assert payload_b["match"] == [%{"host" => ["shared.example.com"]}]
    end

    @tag feature: @feature,
         scenario:
           "Project service start wraps the route in basic auth when basic_auth_enabled is true"
    test "project with basic_auth_enabled=true produces handle with auth handler" do
      target = project_target("myapp.example.com", true)
      payload = Caddy.route_json(target, 4321, true)

      handlers = payload["handle"]
      assert length(handlers) == 2
      [auth, proxy] = handlers
      assert auth["handler"] == "authentication"
      [account] = auth["providers"]["http_basic"]["accounts"]
      assert account["username"] == "alice"
      assert String.starts_with?(account["password"], "$2")
      assert proxy["handler"] == "reverse_proxy"
      assert proxy["upstreams"] == [%{"dial" => "127.0.0.1:4321"}]
    end

    @tag feature: @feature,
         scenario:
           "Project service start does not wrap the route in basic auth when basic_auth_enabled is false"
    test "register payload for project without basic auth has only reverse_proxy handler" do
      target = project_target("myapp.example.com", false)
      payload = Caddy.route_json(target, 4321, false)

      assert length(payload["handle"]) == 1
      [proxy] = payload["handle"]
      assert proxy["handler"] == "reverse_proxy"
    end

    @tag feature: @feature,
         scenario: "Service restart deletes then re-adds the route under the same @id"
    test "DELETE 404 is treated as success (idempotent cleanup)" do
      Req.Test.stub(Caddy, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/config/"} ->
            Req.Test.json(conn, existing_config())

          {"DELETE", _} ->
            conn
            |> Plug.Conn.put_status(404)
            |> Req.Test.json(%{"error" => "not found"})

          {"POST", _} ->
            Req.Test.json(conn, %{})
        end
      end)

      assert Caddy.register(session_target(), 4321) == {:ok, :registered}
    end

    @tag feature: @feature,
         scenario: "Bootstrap base config when srv0 is missing on first registration"
    test "bootstraps srv0 via POST /load when current config has no srv0" do
      agent = start_call_recorder()

      Req.Test.stub(Caddy, fn conn ->
        record_call(conn, agent)

        case {conn.method, conn.request_path} do
          {"GET", "/config/"} -> Req.Test.json(conn, %{})
          {"POST", "/load"} -> Req.Test.json(conn, %{})
          {"DELETE", _} -> Req.Test.json(conn, %{})
          {"POST", "/config/apps/http/servers/srv0/routes"} -> Req.Test.json(conn, %{})
        end
      end)

      assert Caddy.register(session_target("sess-1"), 4321) == {:ok, :registered}

      calls = recorded_calls(agent)
      paths = Enum.map(calls, fn {method, path, _} -> {method, path} end)

      assert paths == [
               {"GET", "/config/"},
               {"POST", "/load"},
               {"DELETE", "/id/destila-session-sess-1"},
               {"POST", "/config/apps/http/servers/srv0/routes"}
             ]

      [_, {_, _, load_body}, _, _] = calls
      load_payload = Jason.decode!(load_body)
      assert get_in(load_payload, ["apps", "http", "servers", "srv0", "routes"]) == []

      assert get_in(load_payload, ["apps", "http", "servers", "srv0", "listen"]) == [
               ":80",
               ":443"
             ]
    end
  end

  describe "register/2 missing credentials" do
    test "session target with nil user returns :missing_credentials, no HTTP" do
      set_credentials(nil, "secret")

      agent = start_call_recorder()

      Req.Test.stub(Caddy, fn conn ->
        record_call(conn, agent)
        Req.Test.json(conn, %{})
      end)

      assert Caddy.register(session_target(), 4321) == {:error, :missing_credentials}
      assert recorded_calls(agent) == []
    end

    test "session target with nil password returns :missing_credentials" do
      set_credentials("alice", nil)
      assert Caddy.register(session_target(), 4321) == {:error, :missing_credentials}
    end
  end

  describe "register/2 silent no-op on probe failure" do
    @tag feature: @feature,
         scenario: "Register is a silent no-op when the Caddy admin URL is unreachable"
    test "returns :no_proxy and only the probe call when admin URL fails at TCP layer" do
      agent = start_call_recorder()

      Req.Test.stub(Caddy, fn conn ->
        record_call(conn, agent)
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert Caddy.register(session_target(), 4321) == {:ok, :no_proxy}
      assert length(recorded_calls(agent)) == 1
      [{method, path, _}] = recorded_calls(agent)
      assert method == "GET"
      assert path == "/config/"
    end
  end

  describe "register/2 non-2xx POST" do
    test "returns {:error, {:caddy_status, 400, body}}" do
      Req.Test.stub(Caddy, fn conn ->
        case conn.method do
          "GET" ->
            Req.Test.json(conn, existing_config())

          "DELETE" ->
            Req.Test.json(conn, %{})

          "POST" ->
            conn
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{"error" => "invalid"})
        end
      end)

      assert {:error, {:caddy_status, 400, body}} =
               Caddy.register(session_target(), 4321)

      assert is_map(body)
    end
  end

  describe "unregister/1" do
    @tag feature: @feature,
         scenario: "Service stop unregisters the route via DELETE /id/<route_id>"
    test "returns :ok on 200" do
      Req.Test.stub(Caddy, fn conn ->
        case conn.method do
          "GET" -> Req.Test.json(conn, %{})
          "DELETE" -> Req.Test.json(conn, %{})
        end
      end)

      assert Caddy.unregister(session_target()) == :ok
    end

    test "returns :ok on 404" do
      Req.Test.stub(Caddy, fn conn ->
        case conn.method do
          "GET" ->
            Req.Test.json(conn, %{})

          "DELETE" ->
            conn
            |> Plug.Conn.put_status(404)
            |> Req.Test.json(%{})
        end
      end)

      assert Caddy.unregister(session_target()) == :ok
    end

    @tag feature: @feature,
         scenario: "Unregister is a silent no-op when the Caddy admin URL is unreachable"
    test "returns :ok and only probe call when admin URL is unreachable" do
      agent = start_call_recorder()

      Req.Test.stub(Caddy, fn conn ->
        record_call(conn, agent)
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert Caddy.unregister(session_target()) == :ok
      assert length(recorded_calls(agent)) == 1
    end

    test "returns {:error, {:caddy_status, 500, _}} when DELETE returns 500" do
      Req.Test.stub(Caddy, fn conn ->
        case conn.method do
          "GET" ->
            Req.Test.json(conn, %{})

          "DELETE" ->
            conn
            |> Plug.Conn.put_status(500)
            |> Req.Test.json(%{"error" => "boom"})
        end
      end)

      assert {:error, {:caddy_status, 500, _}} = Caddy.unregister(session_target())
    end
  end

  describe "password hashing" do
    test "password is hashed only once across multiple register calls" do
      Req.Test.stub(Caddy, fn conn ->
        case conn.method do
          "GET" -> Req.Test.json(conn, %{})
          "DELETE" -> Req.Test.json(conn, %{})
          "POST" -> Req.Test.json(conn, %{})
        end
      end)

      assert {:ok, :registered} = Caddy.register(session_target("sess-a"), 4321)
      {_, hash1} = :persistent_term.get({Caddy, :password_hash})

      assert {:ok, :registered} = Caddy.register(session_target("sess-b"), 4321)
      {_, hash2} = :persistent_term.get({Caddy, :password_hash})

      assert hash1 == hash2
    end
  end

  describe "preflight/1" do
    test "session with both creds returns :ok without probing Caddy" do
      agent = start_call_recorder()

      Req.Test.stub(Caddy, fn conn ->
        record_call(conn, agent)
        Req.Test.json(conn, %{})
      end)

      assert Caddy.preflight(session_target()) == :ok
      assert recorded_calls(agent) == []
    end

    test "project target with no domain returns :ok regardless of creds" do
      set_credentials(nil, nil)
      assert Caddy.preflight(project_target("")) == :ok
    end

    test "project target with domain and basic_auth_enabled=false returns :ok regardless of creds" do
      set_credentials(nil, nil)
      assert Caddy.preflight(project_target("myapp.example.com", false)) == :ok
    end

    test "session target with missing password returns :missing_credentials when Caddy is reachable" do
      set_credentials("alice", nil)

      Req.Test.stub(Caddy, fn conn ->
        Req.Test.json(conn, %{})
      end)

      assert Caddy.preflight(session_target()) == {:error, :missing_credentials}
    end

    test "session target with missing creds returns :ok when Caddy is unreachable" do
      set_credentials(nil, nil)

      Req.Test.stub(Caddy, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert Caddy.preflight(session_target()) == :ok
    end

    test "project target with domain + basic_auth + missing user returns :missing_credentials when Caddy is reachable" do
      set_credentials(nil, "secret")

      Req.Test.stub(Caddy, fn conn ->
        Req.Test.json(conn, %{})
      end)

      assert Caddy.preflight(project_target("myapp.example.com", true)) ==
               {:error, :missing_credentials}
    end
  end
end
