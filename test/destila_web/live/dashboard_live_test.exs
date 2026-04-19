defmodule DestilaWeb.DashboardLiveTest do
  @moduledoc """
  Tests for DashboardLive (the landing page at /).
  Feature: features/dashboard.feature
  """

  use DestilaWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias Destila.Deps

  @feature "dashboard"

  @base_metadata %{
    "claude" => %{
      display_name: "Claude Code CLI",
      purpose: "Runs AI sessions inside Destila.",
      install_command: "npm install -g @anthropic-ai/claude-code",
      docs_url: "https://docs.claude.com/en/docs/claude-code/overview"
    },
    "tmux" => %{
      display_name: "tmux",
      purpose: "Terminal multiplexer used to host long-running workflow terminals.",
      install_command: "brew install tmux",
      docs_url: "https://github.com/tmux/tmux/wiki/Installing"
    },
    "ffmpeg" => %{
      display_name: "ffmpeg",
      purpose: "Media processing for workflow video artifacts.",
      install_command: "brew install ffmpeg",
      docs_url: "https://ffmpeg.org/download.html"
    },
    "agent-browser" => %{
      display_name: "agent-browser",
      purpose: "Headless browser automation used by the browser testing skills.",
      install_command: "npm install -g @every/agent-browser",
      docs_url: "https://www.npmjs.com/package/@every/agent-browser"
    }
  }

  defp stub_tools(availability) do
    tools =
      Enum.map(["claude", "tmux", "ffmpeg", "agent-browser"], fn name ->
        meta = Map.fetch!(@base_metadata, name)
        available? = Map.get(availability, name, true)
        Map.merge(%{name: name, available?: available?}, meta)
      end)

    stub(Deps, :check, fn -> tools end)
  end

  describe "Missing-tools banner" do
    @tag feature: @feature, scenario: "Banner is hidden when all required tools are available"
    test "banner is hidden when every tool is available", %{conn: conn} do
      stub_tools(%{})

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#missing-tools-banner")
    end

    @tag feature: @feature, scenario: "Banner lists each missing tool with an install hint"
    test "banner lists each missing tool with install hint and docs link", %{conn: conn} do
      stub_tools(%{"ffmpeg" => false, "agent-browser" => false})

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#missing-tools-banner")
      assert has_element?(view, "#tool-ffmpeg")
      assert has_element?(view, "#tool-agent-browser")
      refute has_element?(view, "#tool-claude")
      refute has_element?(view, "#tool-tmux")

      assert has_element?(view, "#copy-ffmpeg")
      assert has_element?(view, "#copy-agent-browser")

      html = view |> element("#tool-ffmpeg") |> render()
      assert html =~ "brew install ffmpeg"
      assert html =~ "https://ffmpeg.org/download.html"
    end

    @tag feature: @feature, scenario: "Banner is informational and does not disable any feature"
    test "missing tools do not disable any CTA card", %{conn: conn} do
      stub_tools(%{"claude" => false})

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#missing-tools-banner")
      assert has_element?(view, "#feature-card-crafting")
      assert has_element?(view, "#feature-card-drafts")
      assert has_element?(view, "#feature-card-new-workflow")
      assert has_element?(view, "#feature-card-projects")

      html = render(view)
      refute html =~ ~s(aria-disabled="true")
      refute html =~ ~s(disabled="disabled")
    end

    @tag feature: @feature, scenario: "Banner cannot be dismissed"
    test "banner has no dismiss or close control", %{conn: conn} do
      stub_tools(%{"tmux" => false})

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#missing-tools-banner [phx-click*='dismiss']")
      refute has_element?(view, "#missing-tools-banner button[aria-label*='dismiss']")
      refute has_element?(view, "#missing-tools-banner button[aria-label*='close']")
    end

    @tag feature: @feature, scenario: "Recheck refreshes the banner after I install a tool"
    test "clicking recheck picks up freshly-installed tools", %{conn: conn} do
      stub_tools(%{"ffmpeg" => false})

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#tool-ffmpeg")

      stub_tools(%{})

      view |> element("#recheck-tools") |> render_click()

      refute has_element?(view, "#missing-tools-banner")
      refute has_element?(view, "#tool-ffmpeg")
    end

    @tag feature: @feature, scenario: "Recheck still shows tools that remain missing"
    test "recheck keeps still-missing tools in the banner", %{conn: conn} do
      stub_tools(%{"ffmpeg" => false, "agent-browser" => false})

      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#recheck-tools") |> render_click()

      assert has_element?(view, "#missing-tools-banner")
      assert has_element?(view, "#tool-ffmpeg")
      assert has_element?(view, "#tool-agent-browser")
    end
  end

  describe "Feature overview" do
    setup do
      stub_tools(%{})
      :ok
    end

    @tag feature: @feature,
         scenario: "Dashboard shows call-to-action cards for the main features"
    test "renders all four CTA cards with descriptions", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#feature-overview")
      assert has_element?(view, "#feature-card-crafting")
      assert has_element?(view, "#feature-card-drafts")
      assert has_element?(view, "#feature-card-new-workflow")
      assert has_element?(view, "#feature-card-projects")

      for id <-
            ~w(feature-card-crafting feature-card-drafts feature-card-new-workflow feature-card-projects) do
        html = view |> element("##{id}") |> render()
        assert html =~ ~r/<p[^>]*>[^<]+<\/p>/
      end
    end

    @tag feature: @feature, scenario: "Crafting Board CTA navigates to the crafting board"
    test "Crafting Board card navigates to /crafting", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert {:error, {:live_redirect, %{to: "/crafting"}}} =
               view |> element("#feature-card-crafting") |> render_click()
    end

    @tag feature: @feature, scenario: "Drafts CTA navigates to the drafts board"
    test "Drafts card navigates to /drafts", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert {:error, {:live_redirect, %{to: "/drafts"}}} =
               view |> element("#feature-card-drafts") |> render_click()
    end

    @tag feature: @feature, scenario: "New Workflow CTA navigates to workflow creation"
    test "New Workflow card navigates to /workflows", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert {:error, {:live_redirect, %{to: "/workflows"}}} =
               view |> element("#feature-card-new-workflow") |> render_click()
    end

    @tag feature: @feature, scenario: "Projects CTA navigates to the projects page"
    test "Projects card navigates to /projects", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               view |> element("#feature-card-projects") |> render_click()
    end

    @tag feature: @feature,
         scenario: "Dashboard does not show live activity, stats, or a hero block"
    test "old crafting-summary content is gone", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")

      refute has_element?(view, "#hero")
      refute html =~ "Waiting for You"
      refute html =~ "card-body"
      refute html =~ "card-title"
    end
  end
end
