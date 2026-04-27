defmodule Destila.Proxy.ConfigTest do
  @moduledoc """
  Tests for `Destila.Proxy.Config`. The accessors are pure reads from
  Application env; we override that env per-test and restore on exit.

  Feature: features/caddy_proxy.feature
  """

  use ExUnit.Case, async: false

  alias Destila.Proxy.Config

  @feature "caddy_proxy"

  setup do
    original = Application.get_env(:destila, :proxy)
    Application.delete_env(:destila, :proxy)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:destila, :proxy)
      else
        Application.put_env(:destila, :proxy, original)
      end
    end)

    :ok
  end

  @tag feature: @feature, scenario: "Config returns the documented defaults"
  test "default base_domain is localhost" do
    assert Config.base_domain() == "localhost"
  end

  @tag feature: @feature, scenario: "Config returns the documented defaults"
  test "default admin_url is http://localhost:2019" do
    assert Config.admin_url() == "http://localhost:2019"
  end

  @tag feature: @feature, scenario: "Config returns nil for unset basic_auth credentials"
  test "basic_auth_user defaults to nil" do
    assert Config.basic_auth_user() == nil
  end

  test "basic_auth_password defaults to nil" do
    assert Config.basic_auth_password() == nil
  end

  test "req_options defaults to empty list" do
    assert Config.req_options() == []
  end

  @tag feature: @feature,
       scenario: "The Caddy admin URL is configurable via DESTILA_CADDY_ADMIN_URL"
  test "overrides via Application.put_env are returned by accessors" do
    Application.put_env(:destila, :proxy,
      base_domain: "example.com",
      admin_url: "http://caddy:2019",
      basic_auth_user: "alice",
      basic_auth_password: "secret",
      req_options: [plug: {SomePlug, :id}]
    )

    assert Config.base_domain() == "example.com"
    assert Config.admin_url() == "http://caddy:2019"
    assert Config.basic_auth_user() == "alice"
    assert Config.basic_auth_password() == "secret"
    assert Config.req_options() == [plug: {SomePlug, :id}]
  end
end
