defmodule Destila.Services.UrlTest do
  @moduledoc """
  Pure unit tests for `Destila.Services.Url`.

  Feature: features/caddy_proxy.feature
  """

  use ExUnit.Case, async: false

  alias Destila.Projects.Project
  alias Destila.Services.Url

  @feature "caddy_proxy"

  setup do
    original = Application.get_env(:destila, :proxy)

    Application.put_env(:destila, :proxy,
      base_domain: "example.com",
      admin_url: "http://caddy.test:2019"
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:destila, :proxy)
      else
        Application.put_env(:destila, :proxy, original)
      end
    end)

    :ok
  end

  defp running_state(extra \\ %{}) do
    Map.merge(%{"status" => "running", "port" => 4321}, extra)
  end

  defp project(domain, state) do
    %Project{id: "p1", name: "Test", domain: domain, service_state: state}
  end

  describe "for_session/1" do
    @tag feature: @feature,
         scenario: "Domain-based URL uses https for non-localhost hosts"
    test "session with caddy_route true and base_domain example.com returns https URL" do
      state = running_state(%{"caddy_route" => true})

      assert Url.for_session(%{id: "sess-1", service_state: state}) ==
               "https://sess-1.example.com"
    end

    @tag feature: @feature,
         scenario: "Domain-based URL uses http for *.localhost hosts"
    test "session with base_domain localhost returns http URL" do
      Application.put_env(:destila, :proxy,
        base_domain: "localhost",
        admin_url: "http://caddy.test:2019"
      )

      state = running_state(%{"caddy_route" => true})

      assert Url.for_session(%{id: "sess-1", service_state: state}) ==
               "http://sess-1.localhost"
    end

    test "session with caddy_route false falls back to localhost URL" do
      state = running_state(%{"caddy_route" => false})

      assert Url.for_session(%{id: "sess-1", service_state: state}) ==
               "http://localhost:4321"
    end
  end

  describe "for_project/1" do
    test "project with caddy_route true returns https URL for non-localhost domain" do
      state = running_state(%{"caddy_route" => true})

      assert Url.for_project(project("myapp.example.com", state)) ==
               "https://myapp.example.com"
    end

    test "project with caddy_route true returns http URL for *.localhost" do
      state = running_state(%{"caddy_route" => true})

      assert Url.for_project(project("x.localhost", state)) ==
               "http://x.localhost"
    end

    test "project with caddy_route false falls back to localhost URL" do
      state = running_state(%{"caddy_route" => false})

      assert Url.for_project(project("myapp.example.com", state)) ==
               "http://localhost:4321"
    end

    test "project without caddy_route key falls back to localhost URL" do
      state = running_state()

      assert Url.for_project(project("myapp.example.com", state)) ==
               "http://localhost:4321"
    end

    test "project with caddy_route true but blank domain falls back to localhost URL" do
      state = running_state(%{"caddy_route" => true})

      assert Url.for_project(project("", state)) == "http://localhost:4321"
      assert Url.for_project(project(nil, state)) == "http://localhost:4321"
    end

    test "project preserves mixed-case domain in URL" do
      state = running_state(%{"caddy_route" => true})

      assert Url.for_project(project("App.Example.COM", state)) ==
               "https://App.Example.COM"
    end
  end

  describe "non-running states" do
    test "stopped state returns nil" do
      state = %{"status" => "stopped"}

      assert Url.for_project(project("myapp.example.com", state)) == nil
      assert Url.for_session(%{id: "s1", service_state: state}) == nil
    end

    test "nil service_state returns nil" do
      assert Url.for_project(project("myapp.example.com", nil)) == nil
      assert Url.for_session(%{id: "s1", service_state: nil}) == nil
    end

    test "running state with non-integer port returns nil" do
      state = %{"status" => "running", "port" => "not-an-int"}

      assert Url.for_project(project("myapp.example.com", state)) == nil
    end

    test "session with caddy_route false falls back to localhost even though sessions normally register" do
      state = running_state(%{"caddy_route" => false})

      assert Url.for_session(%{id: "sess-1", service_state: state}) ==
               "http://localhost:4321"
    end
  end
end
