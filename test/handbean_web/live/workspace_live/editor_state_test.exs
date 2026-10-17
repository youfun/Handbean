defmodule HandbeanWeb.WorkspaceLive.EditorStateTest do
  use ExUnit.Case, async: false

  alias Handbean.ConversationStore
  alias HandbeanWeb.WorkspaceLive.ConversationState
  alias HandbeanWeb.WorkspaceLive.EditorProjection

  setup tags do
    Handbean.DataCase.setup_sandbox(tags)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "editor-state-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.fetch_env(:handbean, :host)
    Application.put_env(:handbean, :host, %{data_dir: root})

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:handbean, :host, value)
        :error -> Application.delete_env(:handbean, :host)
      end

      File.rm_rf!(root)
    end)

    {:ok, conversation} = ConversationStore.create("editor-workspace")

    socket = %Phoenix.LiveView.Socket{
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}},
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_conversation_id: conversation["id"],
        current_workspace_id: "editor-workspace",
        chat_scope: :workspace,
        workspace_root: root,
        conversations_by_workspace: %{"editor-workspace" => [conversation]},
        editor_files: [],
        active_file: nil,
        file_preview: nil,
        file_preview_error: nil,
        selected_model: nil,
        selected_reasoning_level: nil,
        timeline: []
      }
    }

    socket = Phoenix.LiveView.stream_configure(socket, :timeline, dom_id: & &1["id"])
    for name <- ["a.ex", "b.ex", "c.ex"], do: File.write!(Path.join(root, name), name)
    %{root: root, socket: socket, conversation: conversation}
  end

  test "selection deduplicates without reordering and persists relative paths only", %{
    root: root,
    socket: socket
  } do
    socket =
      socket
      |> select("a.ex", root)
      |> select("b.ex", root)
      |> select(Path.join(root, "a.ex"), root)

    assert paths(socket) == ["a.ex", "b.ex"]
    assert socket.assigns.active_file == "a.ex"
    stored = ConversationStore.load_files(socket.assigns.current_conversation_id)
    assert stored["active_file"] == "a.ex"
    assert Enum.map(stored["editor_files"], & &1["path"]) == ["a.ex", "b.ex"]
    assert stored["file_preview_error"] == nil
  end

  test "closing a deleted active tab chooses right then left then nil", %{
    root: root,
    socket: socket
  } do
    socket =
      socket
      |> select("a.ex", root)
      |> select("b.ex", root)
      |> select("c.ex", root)
      |> select("b.ex", root)

    File.rm!(Path.join(root, "b.ex"))
    socket = ConversationState.close_file(socket, "b.ex", root)
    assert paths(socket) == ["a.ex", "c.ex"]
    assert socket.assigns.active_file == "c.ex"
    socket = ConversationState.close_file(socket, "c.ex", root)
    assert socket.assigns.active_file == "a.ex"
    socket = ConversationState.close_file(socket, "a.ex", root)
    assert socket.assigns.active_file == nil
    assert socket.assigns.file_preview == nil
  end

  test "closing an inactive tab preserves selection and unknown close is ignored", %{
    root: root,
    socket: socket
  } do
    socket = socket |> select("a.ex", root) |> select("b.ex", root)
    socket = ConversationState.close_file(socket, "a.ex", root)
    assert socket.assigns.active_file == "b.ex"
    assert ConversationState.close_file(socket, "unknown.ex", root) == socket
  end

  test "twenty tabs cap reports user feedback while Agent is silent and preserves active", %{
    root: root,
    socket: socket
  } do
    socket =
      Enum.reduce(1..20, socket, fn i, acc ->
        name = "file#{i}.ex"
        File.write!(Path.join(root, name), name)
        select(acc, name, root)
      end)

    user = select(socket, "a.ex", root)
    assert user.assigns.flash["error"] =~ "20"
    assert paths(user) == paths(socket)
    assert user.assigns.active_file == "file20.ex"

    agent =
      EditorProjection.maybe_add_diff_file(socket, Path.join(root, "a.ex"), ["+change"], root)

    assert agent == socket
    assert select(socket, "file1.ex", root).assigns.active_file == "file1.ex"
  end

  test "Agent adds background tabs and refreshes edits of the selected file", %{
    root: root,
    socket: socket
  } do
    socket = select(socket, "a.ex", root)

    socket =
      EditorProjection.maybe_add_diff_file(socket, Path.join(root, "b.ex"), ["+change"], root)

    assert paths(socket) == ["a.ex", "b.ex"]
    assert socket.assigns.active_file == "a.ex"
    File.write!(Path.join(root, "a.ex"), "updated")

    socket =
      EditorProjection.maybe_add_diff_file(socket, Path.join(root, "a.ex"), ["+updated"], root)

    assert socket.assigns.file_preview.content == "updated"
    assert paths(socket) == ["a.ex", "b.ex"]
  end

  test "sync reloads editor state missing from sidebar summaries instead of clearing tabs", %{
    root: root,
    socket: socket
  } do
    socket = socket |> select("a.ex", root) |> select("b.ex", root)
    conv = ConversationState.current_conv_map(socket)
    summary = Map.drop(conv, ["editor_files", "active_file", "timeline"])

    socket =
      Phoenix.Component.assign(socket, :conversations_by_workspace, %{
        "editor-workspace" => [summary]
      })

    socket =
      ConversationState.sync_conv_state(socket,
        transcript_page: %{entries: [], before: nil, has_more?: false},
        sync_reasoning_for_conversation: fn socket, _, _ -> socket end,
        load_effective_settings: & &1
      )

    assert paths(socket) == ["a.ex", "b.ex"]
    assert socket.assigns.active_file == "b.ex"
    assert socket.assigns.file_preview.content == "b.ex"
    assert ConversationState.current_conv_map(socket)["active_file"] == "b.ex"
  end

  test "persisted editor state ignores absolute paths instead of migrating them", %{
    root: root,
    socket: socket,
    conversation: conversation
  } do
    conv =
      Map.merge(conversation, %{
        "editor_files" => [%{"path" => Path.join(root, "a.ex")}, %{"path" => "a.ex"}],
        "active_file" => Path.join(root, "b.ex"),
        "file_preview_error" => :stale
      })

    socket = sync(socket, conv)
    assert paths(socket) == ["a.ex"]
    assert socket.assigns.active_file == nil
    assert socket.assigns.file_preview == nil
    assert socket.assigns.file_preview_error == nil
  end

  test "missing persisted files display a textual error and remain closable", %{
    root: root,
    socket: socket,
    conversation: conversation
  } do
    conv = Map.merge(conversation, %{"editor_files" => [], "active_file" => "missing.ex"})
    socket = sync(socket, conv)
    assert paths(socket) == ["missing.ex"]
    assert is_binary(socket.assigns.file_preview_error)
    assert {:safe, _} = Phoenix.HTML.html_escape(socket.assigns.file_preview_error)
    socket = ConversationState.close_file(socket, "missing.ex", root)
    assert socket.assigns.active_file == nil
  end

  test "outside, traversal, symlink and sensitive files cannot enter editor state", %{
    root: root,
    socket: socket,
    conversation: conversation
  } do
    File.ln_s!(Path.join(root, "a.ex"), Path.join(root, "link.ex"))
    denied = ["../outside.ex", "/etc/passwd", "link.ex", ".env", "nested/.ssh/id_rsa"]

    for path <- denied do
      selected = select(socket, path, root)
      assert paths(selected) == []
      assert is_binary(selected.assigns.flash["error"])
      assert selected.assigns.file_preview == socket.assigns.file_preview
      assert selected.assigns.file_preview_error == socket.assigns.file_preview_error
      assert EditorProjection.maybe_add_diff_file(socket, path, ["+x"], root) == socket
    end

    conv =
      Map.merge(conversation, %{
        "editor_files" => Enum.map(denied, &%{"path" => &1}),
        "active_file" => "link.ex"
      })

    normalized = sync(socket, conv)
    assert paths(normalized) == []
    assert normalized.assigns.active_file == nil
  end

  test "revert refreshes selected file and Agent deletion shows an error", %{
    root: root,
    socket: socket
  } do
    socket = select(socket, "a.ex", root)
    File.write!(Path.join(root, "a.ex"), "reverted")

    socket =
      EditorProjection.apply_revert_result(
        socket,
        %{"file_path" => Path.join(root, "a.ex")},
        {:ok, %{}},
        root
      )

    assert socket.assigns.file_preview.content == "reverted"
    File.rm!(Path.join(root, "a.ex"))

    socket =
      EditorProjection.maybe_add_diff_file(socket, Path.join(root, "a.ex"), ["-deleted"], root)

    assert socket.assigns.active_file == "a.ex"
    assert is_binary(socket.assigns.file_preview_error)
  end

  test "preview cache uses workspace root as well as relative path", %{
    root: root,
    socket: socket,
    conversation: conversation
  } do
    conv = Map.put(conversation, "active_file", "a.ex")
    socket = sync(socket, conv)
    other_root = Path.join(root, "other")
    File.mkdir_p!(other_root)
    File.write!(Path.join(other_root, "a.ex"), "another workspace")
    socket = socket |> Phoenix.Component.assign(:workspace_root, other_root) |> sync(conv)
    assert socket.assigns.file_preview.content == "another workspace"
  end

  test "normalization retains a missing active file when stored tabs exceed the cap", %{
    socket: socket,
    conversation: conversation
  } do
    files = Enum.map(1..25, &%{"path" => "old#{&1}.ex"})
    conv = Map.merge(conversation, %{"editor_files" => files, "active_file" => "a.ex"})
    socket = sync(socket, conv)
    assert length(paths(socket)) == 20
    assert List.last(paths(socket)) == "a.ex"
    assert socket.assigns.active_file == "a.ex"
  end

  test "switching projections back to the same path restores a cleared preview", %{
    root: root,
    socket: socket,
    conversation: conversation
  } do
    conv = Map.put(conversation, "active_file", "a.ex")
    socket = sync(socket, conv)

    socket =
      socket
      |> Phoenix.Component.assign(:file_preview, nil)
      |> Phoenix.Component.assign(:editor_files, [])
      |> Phoenix.Component.assign(:active_file, nil)

    socket = sync(socket, conv)
    assert socket.assigns.file_preview.content == "a.ex"
    assert paths(socket) == ["a.ex"]
    assert socket.assigns.file_preview.path == Path.join(root, "a.ex")
  end

  test "FreeChat ignores selection, close and Agent changes", %{root: root, socket: socket} do
    socket = Phoenix.Component.assign(socket, :chat_scope, :free)
    assert select(socket, "a.ex", root) == socket
    assert ConversationState.close_file(socket, "a.ex", root) == socket
    assert ConversationState.select_editor_file(socket, "a.ex", root) == socket
    assert EditorProjection.maybe_add_diff_file(socket, "a.ex", ["+x"], root) == socket
  end

  defp paths(socket), do: Enum.map(socket.assigns.editor_files, & &1.path)
  defp select(socket, path, root), do: ConversationState.select_file(socket, path, root)

  defp sync(socket, conv) do
    ConversationState.sync_conv_from(socket, conv,
      transcript_page: %{entries: [], before: nil, has_more?: false},
      sync_reasoning_for_conversation: fn socket, _, _ -> socket end,
      load_effective_settings: & &1
    )
  end
end
