defmodule DestilaWeb.WorkflowTypeSelectionLiveTest do
  @moduledoc """
  LiveView tests for the workflow type selection page.
  Feature: features/workflow_type_selection.feature
  """
  use DestilaWeb.ConnCase

  import Phoenix.LiveViewTest

  @feature "workflow_type_selection"

  # Ensure the atom exists
  _ = :prompt_chore_task

  setup %{conn: conn} do
    conn = post(conn, "/login", %{"email" => "test@example.com"})
    {:ok, conn: conn}
  end

  describe "workflow type selection" do
    @tag feature: @feature, scenario: "View available workflow types"
    test "shows available workflow types with labels and descriptions", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/workflows")

      assert html =~ "What are you creating?"
      assert html =~ "Prompt for a Chore / Task"
      assert html =~ "Straightforward coding tasks"
      assert has_element?(live(conn, ~p"/workflows") |> elem(1), "#type-prompt_chore_task")
    end

    @tag feature: @feature, scenario: "Select a workflow type to start"
    test "clicking a type navigates to its wizard", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workflows")

      view |> element("#type-prompt_chore_task") |> render_click()

      {path, _flash} = assert_redirect(view)
      assert path == "/workflows/prompt_chore_task"
    end
  end
end
