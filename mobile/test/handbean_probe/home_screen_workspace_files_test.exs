defmodule HandbeanProbe.HomeScreenWorkspaceFilesTest do
  use Mob.ScreenCase, async: false
  use Gettext, backend: HandbeanProbe.Gettext

  alias HandbeanProbe.{HomeScreen, NativeWorkspaceOpen}

  defmodule ProviderFixture do
    def init(owner), do: owner

    def call(conn, owner) do
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:provider_request, self(), %{}})

      receive do
        :respond -> :ok
      after
        5_000 -> :ok
      end

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_chunked(200)

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          "data: " <>
            Jason.encode!(%{
              choices: [%{delta: %{content: "Native fixture"}, finish_reason: nil}]
            }) <> "\n\n"
        )

      receive do
        :finish -> :ok
      after
        5_000 -> :ok
      end

      reply =
        "data: " <>
          Jason.encode!(%{
            choices: [%{delta: %{content: " answer"}, finish_reason: nil}]
          }) <>
          "\n\n" <>
          "data: " <>
          Jason.encode!(%{choices: [%{delta: %{}, finish_reason: "stop"}]}) <>
          "\n\ndata: [DONE]\n\n"

      {:ok, conn} = Plug.Conn.chunk(conn, reply)
      conn
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "ws_files_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    host = Application.get_env(:handbean, :host)
    previous_platform = Application.get_env(:handbean_probe, :native_platform)
    HandbeanProbe.NativePlatform.put!(:android)
    Handbean.Host.put!(%{data_dir: dir, shell: false, mcp: false})

    vars = %{
      "HANDBEAN_WORKSPACE" => Path.join(dir, "workspace"),
      "HANDBEAN_MODELS_FILE" => Path.join(dir, "models.json"),
      "HANDBEAN_WORKSPACES_FILE" => Path.join(dir, "workspaces.json"),
      "HANDBEAN_GLOBAL_SETTINGS_FILE" => Path.join(dir, "settings.json")
    }

    previous = Map.new(vars, fn {key, _} -> {key, System.get_env(key)} end)
    Enum.each(vars, fn {key, value} -> System.put_env(key, value) end)

    Application.put_env(:handbean_probe, :file_tree_max_entries, 2)

    on_exit(fn ->
      HandbeanProbe.RuntimeCleanup.stop!()
      Application.delete_env(:handbean_probe, :file_tree_max_entries)

      if host,
        do: Application.put_env(:handbean, :host, host),
        else: Application.delete_env(:handbean, :host)

      if previous_platform,
        do: Application.put_env(:handbean_probe, :native_platform, previous_platform),
        else: Application.delete_env(:handbean_probe, :native_platform)

      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      _ = File.rm_rf(dir)
    end)

    %{view: mount_screen(HomeScreen), dir: dir}
  end

  test "chat open, close keeps draft, PDF uses snake_case snapshot, tree shares viewer", %{
    view: view,
    dir: dir
  } do
    parent = self()

    install_platform_fake(fn req, _opts ->
      send(parent, {:platform_cmd, req})
      {:ok, :async}
    end)

    workspace = assigns(view).workspace
    File.write!(Path.join(workspace["path"], "note.txt"), "你好")
    File.write!(Path.join(workspace["path"], "doc.pdf"), "%PDF")
    File.mkdir_p!(Path.join(workspace["path"], "sub"))
    File.write!(Path.join(workspace["path"], "sub/inner.txt"), "in")
    File.write!(Path.join(workspace["path"], ".dot"), "h")
    File.write!(Path.join(workspace["path"], "a.txt"), "a")
    File.write!(Path.join(workspace["path"], "b.txt"), "b")
    File.write!(Path.join(workspace["path"], "c.txt"), "c")

    {:ok, conv} = Handbean.ConversationStore.create(workspace["id"], title: "Files")
    view = render_info(view, {:tap, {:conversation, conv["id"]}})
    view = render_info(view, {:change, :draft, "keep-draft"})

    chat = %{
      assigns(view).chat
      | entries: [
          %{
            "id" => "t-write",
            "role" => "tool",
            "content_type" => "tool",
            "tool_name" => "write",
            "tool_status" => "done",
            "input" => %{"file_path" => "note.txt"},
            "content" => "wrote"
          }
        ]
    }

    view = %{
      view
      | socket: Mob.Socket.assign(view.socket, chat: chat, work_groups: %{"t-write" => true})
    }

    encoded = inspect(tree(view), limit: :infinity)
    assert encoded =~ gettext("Open")
    assert encoded =~ gettext("Open in another app")

    spec =
      NativeWorkspaceOpen.spec(:timeline, "note.txt", workspace["id"], conv["id"])

    view = view |> render_info({:tap, {:workspace_open, :view, spec}}) |> drain_open()
    assert_renderable(view, extra: [:icon, :settings_select, :settings_button, :file_viewer])
    assert assigns(view).file_viewer.status == :ready
    assert find(view, :file_viewer)
    refute Map.has_key?(find(view, :file_viewer).props, :text)
    assert assigns(view).draft == "keep-draft"
    assert assigns(view).chat.conversation["id"] == conv["id"]

    view = render_info(view, {:tap, :file_viewer_share})
    assert_receive {:platform_cmd, share_export}, 1_000
    assert share_export.op == "platform_export"

    view =
      render_info(
        view,
        {:platform, :result, share_export.request_id,
         {:ok,
          %{
            "snapshot_id" => "snap-share",
            "owner_request_id" => share_export.request_id
          }}}
      )

    assert_receive {:platform_cmd, share_req}, 1_000
    assert share_req.op == "platform_share_snapshot"
    assert share_req.payload["snapshot_id"] == "snap-share"
    assert share_req.payload["owner_request_id"] == share_export.request_id

    stale =
      NativeWorkspaceOpen.spec(:timeline, "note.txt", workspace["id"], "old-conversation")

    rejected = render_info(view, {:tap, {:workspace_open, :view, stale}})
    assert assigns(rejected).notice
    refute NativeWorkspaceOpen.overlay?(assigns(rejected))

    abs = NativeWorkspaceOpen.spec(:tree, "/etc/passwd", workspace["id"])
    rejected = render_info(view, {:tap, {:workspace_open, :view, abs}})
    assert assigns(rejected).notice

    view = render_info(view, {:tap, :close_file_viewer})
    refute NativeWorkspaceOpen.overlay?(assigns(view))
    assert assigns(view).draft == "keep-draft"
    assert assigns(view).page == :chat

    pdf = NativeWorkspaceOpen.spec(:timeline, "doc.pdf", workspace["id"], conv["id"])
    view = view |> render_info({:tap, {:workspace_open, :view, pdf}}) |> drain_open()
    refute NativeWorkspaceOpen.overlay?(assigns(view))
    assert_receive {:platform_cmd, export_req}, 1_000
    assert export_req.op == "platform_export"
    assert export_req.payload["relative_path"] == "doc.pdf"

    view =
      render_info(
        view,
        {:platform, :result, export_req.request_id,
         {:ok,
          %{
            "snapshot_id" => "snap-pdf",
            "owner_request_id" => export_req.request_id
          }}}
      )

    assert_receive {:platform_cmd, open_req}, 1_000
    assert open_req.op == "platform_open_snapshot"
    assert open_req.payload["snapshot_id"] == "snap-pdf"
    assert open_req.payload["owner_request_id"] == export_req.request_id
    refute Map.has_key?(open_req.payload, "snapshotId")

    view = view |> render_info({:tap, {:page, :files}}) |> drain_tree(1)
    assert assigns(view).page == :files
    tree_text = text(view)
    refute tree_text =~ ".dot"

    assert tree_text =~ "sub" or inspect(tree(view), limit: :infinity) =~ "a_dir" or
             inspect(tree(view), limit: :infinity) =~ "Folder"

    view =
      view
      |> render_info({:tap, tree_event(view, %{op: :toggle, relative_dir: "sub"})})
      |> drain_tree(1)

    assert MapSet.member?(assigns(view).workspace_tree.expanded, "sub")
    assert text(view) =~ "inner.txt"

    view =
      view
      |> render_info({:tap, tree_event(view, %{op: :open, relative_path: "sub/inner.txt"})})
      |> drain_open()

    assert assigns(view).file_viewer.status == :ready
    assert assigns(view).file_viewer.identity.relative_path == "sub/inner.txt"
    assert assigns(view).draft == "keep-draft"
    view = render_info(view, {:tap, :close_file_viewer})
    assert assigns(view).page == :files
    assert assigns(view).draft == "keep-draft"

    view = view |> render_info({:tap, tree_event(view, %{op: :toggle_hidden})}) |> drain_tree(2)
    assert assigns(view).workspace_tree.show_hidden
    assert text(view) =~ ".handbean" or text(view) =~ ".dot"

    expanded = MapSet.size(assigns(view).workspace_tree.expanded)
    view = view |> render_info({:tap, tree_event(view, %{op: :refresh})}) |> drain_tree(expanded)
    assert assigns(view).workspace_tree.dirs[""]

    view =
      view
      |> render_info({:tap, tree_event(view, %{op: :load_more, relative_dir: ""})})
      |> drain_tree(1)

    names = Enum.map(assigns(view).workspace_tree.dirs[""].entries, & &1.name)
    assert length(names) >= 3

    listed_dir = assigns(view).workspace_tree.dirs[""]

    view =
      render_info(view, {
        :file_tree_listed,
        %{
          epoch: assigns(view).workspace_tree.epoch,
          workspace_id: workspace["id"],
          relative_dir: "",
          offset: 0,
          request: listed_dir.request,
          result:
            {:ok,
             %{
               entries: [%{name: "ghost", kind: :file, relative_path: "ghost"}],
               next_offset: 1,
               offset: 0,
               truncated: false
             }}
        }
      })

    refute Enum.any?(assigns(view).workspace_tree.dirs[""].entries, &(&1.name == "ghost"))

    path_b = Path.join(dir, "workspace_b")
    File.mkdir_p!(path_b)
    File.write!(Path.join(path_b, "only-b.txt"), "b")
    {:ok, workspace_b} = Handbean.WorkspaceStore.add(path_b, name: "Project B")
    {:ok, _conv_b} = Handbean.ConversationStore.create(workspace_b["id"], title: "B")

    previous_tree_id = assigns(view).workspace_tree.workspace_id
    view = render_info(view, {:tap, {:workspace, workspace_b["id"]}})
    assert assigns(view).workspace["id"] == workspace_b["id"]
    assert assigns(view).workspace_tree.workspace_id == workspace_b["id"]
    assert assigns(view).workspace_tree.workspace_id != previous_tree_id
    assert assigns(view).workspace_tree.dirs == %{}
    refute NativeWorkspaceOpen.overlay?(assigns(view))
  end

  test "opening the viewer does not stop a running chat", %{view: view} do
    server =
      start_supervised!({Bandit, plug: {ProviderFixture, self()}, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    assert :ok =
             Handbean.Agent.ModelConfig.write_config(%{
               "defaultProvider" => "fixture",
               "defaultModel" => "native-model",
               "providers" => %{
                 "fixture" => %{
                   "api" => "openai-chat-completions",
                   "apiKey" => "fixture-key",
                   "baseUrl" => "http://127.0.0.1:#{port}/v1",
                   "models" => [%{"id" => "native-model", "name" => "Fixture"}]
                 }
               }
             })

    view =
      view
      |> render_info({:models_updated})
      |> HandbeanProbe.ScreenSettle.settle()

    workspace = assigns(view).workspace
    File.write!(Path.join(workspace["path"], "note.txt"), "hi")
    {:ok, conversation} = Handbean.ConversationStore.create(workspace["id"], title: "Viewer run")

    view =
      view
      |> render_info({:tap, {:conversation, conversation["id"]}})
      |> HandbeanProbe.ScreenSettle.settle()
      |> render_info({:change, :draft, "run please"})
      |> render_info({:tap, :send})

    assert assigns(view).chat.running
    assert_receive {:provider_request, request, _body}, 5_000

    spec =
      NativeWorkspaceOpen.spec(
        :timeline,
        "note.txt",
        workspace["id"],
        assigns(view).chat.conversation["id"]
      )

    view = view |> render_info({:tap, {:workspace_open, :view, spec}}) |> drain_open()
    assert assigns(view).file_viewer.status == :ready
    assert assigns(view).chat.running

    assert {:ok, %{running?: true}} =
             Handbean.Agent.Coordinator.status(assigns(view).chat.conversation["id"])

    view = render_info(view, {:tap, :close_file_viewer})
    assert assigns(view).chat.running
    send(request, :respond)
    send(request, :finish)
  end

  defp drain_open(view) do
    assert_receive {:workspace_open_ready, generation, result}, 1_000
    render_info(view, {:workspace_open_ready, generation, result})
  end

  defp drain_tree(view, n) do
    Enum.reduce(1..n, view, fn _, acc ->
      assert_receive {:file_tree_listed, payload}, 1_000
      render_info(acc, {:file_tree_listed, payload})
    end)
  end

  defp tree_event(view, op) do
    tree = assigns(view).workspace_tree
    {:file_tree, Map.merge(%{workspace_id: tree.workspace_id, epoch: tree.epoch}, op)}
  end

  defp install_platform_fake(fun) do
    Application.put_env(:handbean_probe, :platform_fake, fun)
    on_exit(fn -> Application.delete_env(:handbean_probe, :platform_fake) end)
  end
end
