defmodule HandbeanWeb.WorkspaceMediaControllerTest do
  use HandbeanWeb.ConnCase, async: false

  alias Handbean.WorkspaceStore

  @png <<137, 80, 78, 71, 13, 10, 26, 10>>
  @jpeg <<255, 216, 255, 224, 0, 16>>
  @gif "GIF89a"
  @webp <<"RIFF", 4::little-32, "WEBP">>
  @max_bytes 25 * 1024 * 1024

  setup do
    root =
      Path.join(System.tmp_dir!(), "workspace-media-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    previous_config = Application.fetch_env(:handbean, :workspaces_file)
    Application.put_env(:handbean, :workspaces_file, Path.join(root, "workspaces.json"))
    {:ok, ws} = WorkspaceStore.add(workspace)

    {:ok, conversation} =
      Handbean.ConversationStore.create(ws["id"], checkout_path: workspace)

    Process.put(:workspace_media_conversation_id, conversation["id"])

    on_exit(fn ->
      restore_config(:workspaces_file, previous_config)
      File.rm_rf!(root)
    end)

    %{root: root, workspace: workspace, ws_id: ws["id"]}
  end

  test "serves supported image bytes with private cache and nosniff headers", context do
    images = [
      {"nested/a space.PNG", @png, "image/png"},
      {"图像 #?%.png", @png, "image/png"},
      {"photo.jpg", @jpeg, "image/jpeg"},
      {"photo.jpeg", @jpeg, "image/jpeg"},
      {"animated.gif", @gif, "image/gif"},
      {"picture.webp", @webp, "image/webp"}
    ]

    for {path, bytes, mime} <- images do
      write_image(context.workspace, path, bytes)

      conn =
        context.conn
        |> put_req_header("accept", "image/avif,image/webp,image/*,*/*;q=0.8")
        |> get(media_url(context.ws_id, path))

      assert response(conn, 200) == bytes
      assert [content_type] = get_resp_header(conn, "content-type")
      assert String.starts_with?(content_type, mime)
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end
  end

  test "rejects unsupported extensions, mismatched magic and empty images", context do
    for {name, bytes} <- [
          {"image.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>"},
          {"image.html", @png},
          {"image.png", @jpeg},
          {"image.gif", @png},
          {"image.webp", "<html>unsafe</html>"},
          {"empty.png", ""}
        ] do
      write_image(context.workspace, name, bytes)
      conn = get(context.conn, media_url(context.ws_id, name))
      assert response(conn, 404) == "Not Found"
    end
  end

  test "accepts exactly 25 MiB and rejects a larger image", context do
    bytes = @png <> :binary.copy(<<0>>, @max_bytes - byte_size(@png))
    write_image(context.workspace, "limit.png", bytes)
    conn = get(context.conn, media_url(context.ws_id, "limit.png"))
    assert response(conn, 200) == bytes

    File.write!(Path.join(context.workspace, "limit.png"), <<0>>, [:append])
    conn = get(context.conn, media_url(context.ws_id, "limit.png"))
    assert response(conn, 404) == "Not Found"
  end

  test "resolves only the stored workspace and requires a regular relative file", context do
    write_image(context.root, "outside.png", @png)
    File.mkdir_p!(Path.join(context.workspace, "directory.png"))

    for path <- [
          "../outside.png",
          Path.join(context.root, "outside.png"),
          "missing.png",
          "directory.png",
          "",
          "bad" <> <<0>> <> ".png"
        ] do
      conn = get(context.conn, media_url(context.ws_id, path))
      assert response(conn, 404) == "Not Found"
    end

    assert context.conn |> get("/workspace-files/#{context.ws_id}") |> response(404) ==
             "Not Found"

    assert context.conn |> get(media_url("unknown", "outside.png")) |> response(404) ==
             "Not Found"
  end

  test "rejects both leaf and intermediate symlinks", context do
    write_image(context.root, "outside.png", @png)
    File.ln_s!(Path.join(context.root, "outside.png"), Path.join(context.workspace, "leaf.png"))
    File.ln_s!(context.root, Path.join(context.workspace, "escape"))

    for path <- ["leaf.png", "escape/outside.png"] do
      conn = get(context.conn, media_url(context.ws_id, path))
      assert response(conn, 404) == "Not Found"
    end
  end

  test "rejects sensitive components through the existing path policy", context do
    for path <- [".ssh/picture.png", ".env.png", ".aws/picture.png"] do
      write_image(context.workspace, path, @png)
      conn = get(context.conn, media_url(context.ws_id, path))
      assert response(conn, 404) == "Not Found"
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    end
  end

  test "checks sensitive canonical ancestors of the workspace root", context do
    sensitive = Path.join(context.root, ".ssh")
    write_image(sensitive, "project/picture.png", @png)
    File.ln_s!(sensitive, Path.join(context.root, "alias"))
    {:ok, ws} = WorkspaceStore.add(Path.join(context.root, "alias/project"))

    {:ok, conversation} =
      Handbean.ConversationStore.create(ws["id"],
        checkout_path: Path.join(context.root, "alias/project")
      )

    Process.put(:workspace_media_conversation_id, conversation["id"])
    conn = get(context.conn, media_url(ws["id"], "picture.png"))
    assert response(conn, 404) == "Not Found"
  end

  test "browser pipeline enforces local access boundaries", context do
    previous_access = Application.fetch_env(:handbean, :access)
    Application.put_env(:handbean, :access, mode: :local)
    on_exit(fn -> restore_config(:access, previous_access) end)
    write_image(context.workspace, "picture.png", @png)
    url = media_url(context.ws_id, "picture.png")

    conn =
      build_conn()
      |> Map.put(:host, "localhost")
      |> Map.put(:remote_ip, {192, 0, 2, 1})
      |> get(url)

    assert response(conn, 403) =~ "Local access only"

    conn =
      build_conn()
      |> Map.put(:host, "localhost")
      |> put_req_header("origin", "https://other.example")
      |> get(url)

    assert response(conn, 403) =~ "Local access only"
  end

  test "browser pipeline requires authentication before serving bytes", context do
    previous_access = Application.fetch_env(:handbean, :access)

    Application.put_env(:handbean, :access,
      mode: :password,
      username: "media-test",
      password: "media-password"
    )

    on_exit(fn -> restore_config(:access, previous_access) end)
    write_image(context.workspace, "picture.png", @png)
    url = media_url(context.ws_id, "picture.png")
    conn = build_conn() |> Map.put(:host, "localhost") |> get(url)
    assert response(conn, 401) =~ "Authentication required"
    refute conn.resp_body == @png

    conn = build_conn() |> Map.put(:host, "localhost") |> authenticate() |> get(url)
    assert response(conn, 200) == @png
  end

  defp media_url(workspace_id, path) do
    encoded_path =
      path |> String.split("/") |> Enum.map_join("/", &URI.encode(&1, fn _ -> false end))

    conversation_id =
      Process.get(:workspace_media_conversation_id) || raise "missing media conversation"

    "/workspace-files/#{workspace_id}/#{encoded_path}?conversation_id=#{conversation_id}"
  end

  defp write_image(root, path, bytes) do
    full_path = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, bytes)
  end

  defp restore_config(key, {:ok, value}), do: Application.put_env(:handbean, key, value)
  defp restore_config(key, :error), do: Application.delete_env(:handbean, key)
end
