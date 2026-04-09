defmodule DestilaWeb.MediaControllerTest do
  use DestilaWeb.ConnCase, async: false

  @feature "video_metadata_viewing"

  setup %{conn: conn} do
    path = Path.join(System.tmp_dir!(), "test_video_#{System.unique_integer([:positive])}.mp4")
    File.write!(path, :crypto.strong_rand_bytes(1024))
    on_exit(fn -> File.rm(path) end)

    {:ok, ws} =
      Destila.Workflows.insert_workflow_session(%{
        title: "Test",
        workflow_type: :brainstorm_idea,
        project_id: nil,
        current_phase: 1,
        total_phases: 1
      })

    {:ok, meta} =
      Destila.Workflows.upsert_metadata(ws.id, "phase_1", "demo_video", %{"video_file" => path},
        exported: true
      )

    {:ok, conn: conn, meta: meta, video_path: path}
  end

  describe "full request" do
    @tag feature: @feature, scenario: "Video file is streamed from disk"
    test "returns 200 with video/mp4 content type", %{conn: conn, meta: meta, video_path: path} do
      conn = get(conn, "/media/#{meta.id}")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["video/mp4"]
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      assert conn.resp_body == File.read!(path)
    end
  end

  describe "range request" do
    @tag feature: @feature, scenario: "Video file is streamed from disk"
    test "returns 206 with content-range for bounded range", %{conn: conn, meta: meta} do
      conn =
        conn
        |> put_req_header("range", "bytes=0-99")
        |> get("/media/#{meta.id}")

      assert conn.status == 206
      assert get_resp_header(conn, "content-range") == ["bytes 0-99/1024"]
      assert byte_size(conn.resp_body) == 100
    end

    @tag feature: @feature, scenario: "Video file is streamed from disk"
    test "returns bytes from offset to EOF for open-ended range", %{conn: conn, meta: meta} do
      conn =
        conn
        |> put_req_header("range", "bytes=100-")
        |> get("/media/#{meta.id}")

      assert conn.status == 206
      assert get_resp_header(conn, "content-range") == ["bytes 100-1023/1024"]
      assert byte_size(conn.resp_body) == 924
    end
  end
end
