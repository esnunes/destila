defmodule DestilaWeb.ClaudeAuthLoginLiveTest do
  @moduledoc """
  LiveView tests for the in-app Claude CLI auth login modal.
  Feature: features/claude_auth_login.feature
  """

  use DestilaWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias Destila.AI
  alias Destila.AI.AuthLogin
  alias Destila.Executions
  alias Destila.PubSubHelper
  alias Destila.Sessions.SessionProcess
  alias Destila.Workflows

  @feature "Claude Auth Login Modal"

  setup :set_mimic_global

  setup do
    ClaudeCode.Test.set_mode_to_shared()

    ClaudeCode.Test.stub(ClaudeCode, fn _query, _opts ->
      [
        ClaudeCode.Test.text("AI response"),
        ClaudeCode.Test.result("AI response")
      ]
    end)

    test_pid = self()

    stub(AuthLogin, :start, fn ->
      send(test_pid, {:auth_login, :start})
      :ok
    end)

    stub(AuthLogin, :current, fn ->
      %{state: :awaiting_token, url: nil, error_message: nil}
    end)

    stub(AuthLogin, :submit_token, fn token ->
      send(test_pid, {:auth_login, {:submit_token, token}})
      :ok
    end)

    stub(AuthLogin, :restart, fn ->
      send(test_pid, {:auth_login, :restart})
      :ok
    end)

    stub(AuthLogin, :stop, fn ->
      send(test_pid, {:auth_login, :stop})
      :ok
    end)

    :ok
  end

  # --- Helpers ---

  defp create_session_with_auth_error(opts \\ []) do
    extra_messages? = Keyword.get(opts, :extra_messages?, false)

    {:ok, ws} =
      Workflows.insert_workflow_session(%{
        title: "Test Auth Session",
        workflow_type: :brainstorm_idea,
        current_phase: 1,
        total_phases: 4
      })

    {:ok, _pe} = Executions.create_phase_execution(ws, 1, %{status: :awaiting_input})
    {:ok, ai_session} = AI.get_or_create_ai_session(ws.id)

    {:ok, user_msg} =
      AI.create_message(ai_session.id, %{
        role: :user,
        content: "the original message",
        phase: 1,
        workflow_session_id: ws.id
      })

    if extra_messages? do
      {:ok, _} =
        AI.create_message(ai_session.id, %{
          role: :system,
          content: "Some normal system message",
          phase: 1,
          workflow_session_id: ws.id
        })
    end

    {:ok, auth_msg} =
      AI.create_message(ai_session.id, %{
        role: :system,
        content: "Claude authentication failed: 401",
        message_type: :auth_error,
        phase: 1,
        workflow_session_id: ws.id
      })

    %{ws: ws, auth_msg: auth_msg, user_msg: user_msg}
  end

  defp broadcast_state(state, opts \\ []) do
    snapshot = %{
      state: state,
      url: Keyword.get(opts, :url),
      error_message: Keyword.get(opts, :error)
    }

    Phoenix.PubSub.broadcast(
      Destila.PubSub,
      PubSubHelper.claude_auth_login_topic(),
      {:claude_auth_login_state, snapshot}
    )
  end

  # --- Action surface ---

  describe "Action surface" do
    @tag feature: @feature,
         scenario: "Login action appears below an auth_error message bubble"
    test "Login to Claude action appears only below auth_error bubbles",
         %{conn: conn} do
      %{ws: ws, auth_msg: auth_msg, user_msg: user_msg} =
        create_session_with_auth_error(extra_messages?: true)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      assert has_element?(view, "#open-claude-login-#{auth_msg.id}", "Login to Claude")
      refute has_element?(view, "#open-claude-login-#{user_msg.id}")
    end
  end

  # --- Opening the modal ---

  describe "Opening the modal" do
    @tag feature: @feature, scenario: "Clicking the login action opens the auth modal"
    test "clicking Login to Claude opens the modal and starts the CLI",
         %{conn: conn} do
      %{ws: ws, auth_msg: auth_msg} = create_session_with_auth_error()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      refute has_element?(view, "#claude-auth-login-modal")

      view |> element("#open-claude-login-#{auth_msg.id}") |> render_click()

      assert has_element?(view, "#claude-auth-login-modal")
      assert_received {:auth_login, :start}
    end

    @tag feature: @feature,
         scenario: "Modal displays the authentication URL printed by the CLI"
    test "URL and copy control appear after the awaiting_token broadcast",
         %{conn: conn} do
      %{ws: ws, auth_msg: auth_msg} = create_session_with_auth_error()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")
      view |> element("#open-claude-login-#{auth_msg.id}") |> render_click()

      url = "https://claude.com/cai/oauth/authorize?code=true&abc123"
      broadcast_state(:awaiting_token, url: url)

      html = render(view)
      assert html =~ "https://claude.com/cai/oauth/authorize?code=true"
      assert html =~ "abc123"
      assert has_element?(view, "#claude-login-url")
      assert has_element?(view, "#claude-login-copy-url")
      assert has_element?(view, "#claude-login-token-input")
    end
  end

  # --- Submitting a token ---

  describe "Submitting a token" do
    @tag feature: @feature, scenario: "User pastes a token and submits it"
    test "submitting the form forwards the trimmed token and shows verifying state",
         %{conn: conn} do
      %{ws: ws, auth_msg: auth_msg} = create_session_with_auth_error()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")
      view |> element("#open-claude-login-#{auth_msg.id}") |> render_click()
      broadcast_state(:awaiting_token, url: "https://claude.ai/oauth/authorize")

      view
      |> form("#claude-login-token-form", %{"claude_login" => %{"token" => "  my-token  "}})
      |> render_submit()

      assert_received {:auth_login, {:submit_token, "my-token"}}

      broadcast_state(:verifying)

      assert has_element?(view, "#claude-login-verifying")
      assert render(view) =~ "Exchanging code with Anthropic"
    end

    @tag feature: @feature,
         scenario: "Successful token closes the modal and retries the failed turn"
    test "succeeded broadcast closes the modal, retries the turn, and stops the CLI",
         %{conn: conn} do
      test_pid = self()

      expect(SessionProcess, :retry_after_auth, fn ws_id, msg_id ->
        send(test_pid, {:retry_after_auth, ws_id, msg_id})
        :ok
      end)

      %{ws: ws, auth_msg: auth_msg} = create_session_with_auth_error()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")
      view |> element("#open-claude-login-#{auth_msg.id}") |> render_click()
      broadcast_state(:awaiting_token, url: "https://claude.ai/oauth/authorize")
      broadcast_state(:succeeded)

      _ = render(view)
      refute has_element?(view, "#claude-auth-login-modal")
      ws_id = ws.id
      auth_id = auth_msg.id
      assert_received {:retry_after_auth, ^ws_id, ^auth_id}
      assert_received {:auth_login, :stop}
    end

    @tag feature: @feature,
         scenario: "Invalid token shows an error and forces a restart"
    test "invalid_token broadcast shows the error and the Restart action",
         %{conn: conn} do
      %{ws: ws, auth_msg: auth_msg} = create_session_with_auth_error()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")
      view |> element("#open-claude-login-#{auth_msg.id}") |> render_click()
      broadcast_state(:awaiting_token, url: "https://claude.ai/oauth/authorize")
      broadcast_state(:invalid_token, error: "Token rejected by Anthropic.")

      html = render(view)
      assert html =~ "Token rejected by Anthropic."
      assert has_element?(view, "#claude-login-error")
      assert has_element?(view, "#claude-login-restart")
      refute has_element?(view, "#claude-login-token-form")
    end
  end

  # --- Restart and lifecycle ---

  describe "Restart and lifecycle" do
    @tag feature: @feature,
         scenario: "Restarting the flow spawns a new login process"
    test "clicking Restart triggers AuthLogin.restart and renders a fresh URL",
         %{conn: conn} do
      %{ws: ws, auth_msg: auth_msg} = create_session_with_auth_error()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")
      view |> element("#open-claude-login-#{auth_msg.id}") |> render_click()
      broadcast_state(:awaiting_token, url: "https://claude.ai/old")
      broadcast_state(:invalid_token, error: "bad token")

      view |> element("#claude-login-restart") |> render_click()
      assert_received {:auth_login, :restart}

      fresh_url = "https://claude.ai/oauth/authorize?fresh"
      broadcast_state(:awaiting_token, url: fresh_url)

      assert render(view) =~ fresh_url
    end

    @tag feature: @feature, scenario: "Closing the modal preserves the OAuth state"
    test "closing the modal hides it without stopping AuthLogin",
         %{conn: conn} do
      %{ws: ws, auth_msg: auth_msg} = create_session_with_auth_error()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")
      view |> element("#open-claude-login-#{auth_msg.id}") |> render_click()

      view |> element("#claude-auth-login-modal-close-x") |> render_click()

      refute has_element?(view, "#claude-auth-login-modal")
      refute_received {:auth_login, :stop}
    end

    @tag feature: @feature, scenario: "Cancel button stops the spawned process"
    test "clicking Cancel stops AuthLogin and dismisses the modal",
         %{conn: conn} do
      %{ws: ws, auth_msg: auth_msg} = create_session_with_auth_error()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")
      view |> element("#open-claude-login-#{auth_msg.id}") |> render_click()
      broadcast_state(:awaiting_token, url: "https://claude.ai/oauth/authorize")

      view |> element("#claude-login-cancel") |> render_click()

      refute has_element?(view, "#claude-auth-login-modal")
      assert_received {:auth_login, :stop}
    end

    @tag feature: @feature, scenario: "Reopening the modal preserves the OAuth state"
    test "reopening the modal does not stop AuthLogin",
         %{conn: conn} do
      %{ws: ws, auth_msg: auth_msg} = create_session_with_auth_error()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")

      view |> element("#open-claude-login-#{auth_msg.id}") |> render_click()
      broadcast_state(:awaiting_token, url: "https://claude.ai/preserved")

      view |> element("#claude-auth-login-modal-close-x") |> render_click()

      assert_received {:auth_login, :start}
      refute_received {:auth_login, :stop}

      view |> element("#open-claude-login-#{auth_msg.id}") |> render_click()

      assert_received {:auth_login, :start}
    end
  end

  # --- CLI failures ---

  describe "CLI failures" do
    @tag feature: @feature, scenario: "CLI process exits before printing a URL"
    test "cli_failed broadcast shows the failure and the Restart action",
         %{conn: conn} do
      %{ws: ws, auth_msg: auth_msg} = create_session_with_auth_error()

      {:ok, view, _html} = live(conn, ~p"/sessions/#{ws.id}")
      view |> element("#open-claude-login-#{auth_msg.id}") |> render_click()
      broadcast_state(:cli_failed, error: "Claude CLI exited unexpectedly")

      html = render(view)
      assert html =~ "Claude CLI exited unexpectedly"
      assert has_element?(view, "#claude-login-error")
      assert has_element?(view, "#claude-login-restart")
    end
  end
end
