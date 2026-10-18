defmodule HandbeanProbe.WorkspaceMemoryTest do
  use ExUnit.Case, async: false
  use Gettext, backend: HandbeanProbe.Gettext

  import Ecto.Query
  import HandbeanProbe.ScreenSettle

  alias Handbean.Memory.{Engram, MemoryStore, Synapse}
  alias HandbeanProbe.{HomeScreen, WorkspaceMemory}
  alias HandbeanProbe.HomeScreen.State

  setup do
    previous_locale = HandbeanProbe.Gettext.locale()
    previous_platform = Application.get_env(:handbean_probe, :native_platform)
    previous_clipboard = Application.get_env(:handbean_probe, :clipboard_put)
    HandbeanProbe.NativePlatform.put!(:android)
    Gettext.put_locale(HandbeanProbe.Gettext, "en")

    on_exit(fn ->
      Gettext.put_locale(HandbeanProbe.Gettext, previous_locale)
      restore_env(:native_platform, previous_platform)
      restore_env(:clipboard_put, previous_clipboard)
    end)

    :ok
  end

  test "renders statistics, lifecycle, associations, and native actions" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    inserted_at = DateTime.to_naive(now)

    engram = %Engram{
      id: 42,
      content: "Remember the mobile memory browser",
      kind: :preference,
      short_term: false,
      reinforced_count: 2,
      metadata: %{"scope" => "global", "source" => "agent"},
      source_synapses: [%Synapse{target_id: 20, kind: :context_for}],
      target_synapses: [],
      inserted_at: inserted_at,
      updated_at: inserted_at
    }

    state =
      WorkspaceMemory.new()
      |> WorkspaceMemory.loaded({
        :ok,
        %{
          items: [engram],
          summary: %{
            active: 1,
            long_term: 1,
            short_term: 0,
            expired: 0,
            by_kind: %{preference: 1, rule: 0, pattern: 0, fact: 0, context: 0}
          },
          now: now
        }
      })

    tree =
      WorkspaceMemory.render(state, %{
        "id" => "workspace-a",
        "name" => "Handbean",
        "path" => "/tmp/handbean"
      })

    blob = flatten_text(tree)
    assert blob =~ "Workspace Memory"
    assert blob =~ "Use built-in memory"
    assert tap?(tree, {:memory_builtin, true})
    assert tap?(tree, {:memory_builtin, false})
    assert blob =~ "Current workspace: Handbean"
    assert blob =~ "Active memory  1"
    assert blob =~ "#42"
    assert blob =~ "preference · Preference"
    assert blob =~ "Long-term · reinforced ×2"
    assert blob =~ "Remember the mobile memory browser"
    assert blob =~ "Scope: Global · Source: Agent"
    assert blob =~ "↳ context_for #20"
    assert tap?(tree, {:memory_related, 20})
    assert tap?(tree, {:memory_edit, 42})
    assert tap?(tree, {:memory_ask_delete, 42})
    refute tap?(tree, {:memory_promote, 42})
    assert tap?(tree, {:memory_copy, :id, 42})
    assert tap?(tree, {:memory_copy, :content, 42})
  end

  test "renders Chinese labels from the native catalog" do
    Gettext.put_locale(HandbeanProbe.Gettext, "zh_CN")

    tree =
      WorkspaceMemory.render(WorkspaceMemory.new(), %{
        "id" => "workspace-a",
        "name" => "Handbean",
        "path" => "/tmp/handbean"
      })

    blob = flatten_text(tree)
    assert blob =~ "工作区记忆"
    assert blob =~ "当前工作区：Handbean"
    assert blob =~ "有效记忆  0"
    assert Enum.any?(walk(tree), &(&1.props[:placeholder] == "搜索内容或 #ID…"))
    assert blob =~ "没有符合筛选条件的记忆"
  end

  test "the shared memory tree renders with iOS-native controls" do
    HandbeanProbe.NativePlatform.put!(:ios)

    tree =
      WorkspaceMemory.render(WorkspaceMemory.new(), %{
        "id" => "workspace-a",
        "name" => "Handbean",
        "path" => "/tmp/handbean"
      })

    memory_tab =
      Enum.find(walk(tree), &match?(%{props: %{on_tap: {_, {:memory_scope, :both}}}}, &1))

    assert memory_tab.type == :button
    assert tap?(tree, {:memory_lifecycle, :active})
    assert tap?(tree, {:memory_kind, :preference})
  end

  test "HomeScreen persists the workspace-local built-in memory setting" do
    root =
      Path.join(System.tmp_dir!(), "mobile-memory-setting-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    workspace = %{"id" => "memory-setting", "name" => "Memory", "path" => root}
    socket = %Mob.Socket{assigns: State.new(page: :chat, workspace: workspace)}

    view = socket |> event({:tap, {:page, :memory}}) |> settle()
    assert view.socket.assigns.workspace_memory.builtin_memory_enabled

    view = event(view, {:tap, {:memory_builtin, false}})
    refute view.socket.assigns.workspace_memory.builtin_memory_enabled
    refute Handbean.WorkspaceSettings.builtin_memory_enabled(root)

    view = event(view, {:tap, {:memory_builtin, true}})
    assert view.socket.assigns.workspace_memory.builtin_memory_enabled
    assert Handbean.WorkspaceSettings.builtin_memory_enabled(root)
  end

  test "locating a connection widens filters and copy values stay scoped to loaded items" do
    state = %{
      WorkspaceMemory.new()
      | scope: :workspace,
        lifecycle: :expired,
        kind: :rule,
        items: [%Engram{id: 49, content: "Scoped content"}]
    }

    located = WorkspaceMemory.locate(state, 49)
    assert located.query == "#49"
    assert located.scope == :both
    assert located.lifecycle == :all
    assert located.kind == :all
    assert WorkspaceMemory.copy_value(state, 49, :id) == {:ok, "#49"}
    assert WorkspaceMemory.copy_value(state, 49, :content) == {:ok, "Scoped content"}
    assert WorkspaceMemory.copy_value(state, 50, :content) == :error
  end

  test "edit and delete state only opens for projected memories" do
    state = %{
      WorkspaceMemory.new()
      | items: [
          %Engram{
            id: 49,
            content: "Scoped content",
            kind: :fact,
            metadata: %{},
            source_synapses: [],
            target_synapses: []
          },
          %Engram{
            id: 50,
            content: "Reflected content",
            kind: :context,
            metadata: %{"scope" => "workspace", "source" => "reflection"},
            source_synapses: [],
            target_synapses: []
          }
        ]
    }

    assert WorkspaceMemory.memory_scope(hd(state.items)) == :workspace
    assert WorkspaceMemory.memory_source(hd(state.items)) == "Legacy"
    assert WorkspaceMemory.memory_source(List.last(state.items)) == "Reflection"

    editing = WorkspaceMemory.edit(state, 49)
    assert editing.editing == %{id: 49, content: "Scoped content", kind: :fact}
    assert WorkspaceMemory.edit(state, 500).editing == nil
    assert WorkspaceMemory.confirm_delete(state, 49).confirming_delete == 49
    assert WorkspaceMemory.confirm_delete(state, 500).confirming_delete == nil

    local_only = %{state | privacy_mode: :local_only, scope: :global}
    local_only = WorkspaceMemory.set_scope(local_only, :both)
    assert local_only.scope == :workspace
    assert WorkspaceMemory.locate(local_only, 50).scope == :workspace

    tree =
      WorkspaceMemory.render(local_only, %{
        "id" => "workspace-a",
        "name" => "Handbean",
        "path" => "/tmp/handbean"
      })

    assert tap?(tree, {:memory_scope, :workspace})
    refute tap?(tree, {:memory_scope, :both})
    refute tap?(tree, {:memory_scope, :global})
  end

  test "HomeScreen promotes, edits, and deletes through scoped memory events" do
    suffix = System.unique_integer([:positive])
    workspace_id = "mobile-memory-curation-#{suffix}"
    other_workspace_id = "mobile-memory-curation-other-#{suffix}"

    {:ok, memory} =
      MemoryStore.learn("Curate this mobile memory #{suffix}", :fact,
        short_term: true,
        memory_scope: :workspace,
        workspace_id: workspace_id,
        metadata: %{"source" => "agent"}
      )

    {:ok, other} =
      MemoryStore.learn("Do not curate this other memory #{suffix}", :rule,
        short_term: true,
        memory_scope: :workspace,
        workspace_id: other_workspace_id,
        metadata: %{"source" => "agent"}
      )

    ids = [memory.id, other.id]

    on_exit(fn ->
      Handbean.Repo.delete_all(from(e in Engram, where: e.id in ^ids))
    end)

    workspace = %{"id" => workspace_id, "name" => "Mobile", "path" => "/tmp/mobile"}
    socket = %Mob.Socket{assigns: State.new(page: :chat, workspace: workspace)}
    view = socket |> event({:tap, {:page, :memory}}) |> settle()

    tree = HomeScreen.render(view.socket.assigns)
    assert flatten_text(tree) =~ "Scope: Workspace · Source: Agent"
    assert tap?(tree, {:memory_promote, memory.id})

    view = view |> event({:tap, {:memory_promote, other.id}}) |> settle()
    assert Handbean.Repo.get!(Engram, other.id).short_term
    assert view.socket.assigns.workspace_memory.error == ":not_found"

    view = view |> event({:tap, {:memory_promote, memory.id}}) |> settle()
    promoted = Handbean.Repo.get!(Engram, memory.id)
    refute promoted.short_term
    assert promoted.reinforced_count == 1

    view = event(view, {:tap, {:memory_edit, memory.id}})
    assert view.socket.assigns.workspace_memory.editing.id == memory.id
    assert flatten_text(HomeScreen.render(view.socket.assigns)) =~ "Edit memory ##{memory.id}"

    view = event(view, {:change, :memory_edit_content, ""})
    view = view |> event({:tap, :memory_save_edit}) |> settle()
    assert view.socket.assigns.workspace_memory.error == "Memory content and type are required"
    assert Handbean.Repo.get!(Engram, memory.id).content == memory.content

    view = event(view, {:change, :memory_edit_content, "Corrected mobile memory #{suffix}"})
    view = event(view, {:tap, {:memory_edit_kind, :preference}})
    view = view |> event({:tap, :memory_save_edit}) |> settle()

    updated = Handbean.Repo.get!(Engram, memory.id)
    assert updated.content == "Corrected mobile memory #{suffix}"
    assert updated.kind == :preference
    assert view.socket.assigns.workspace_memory.editing == nil

    view = event(view, {:tap, {:memory_ask_delete, memory.id}})
    tree = HomeScreen.render(view.socket.assigns)

    assert Enum.any?(
             walk(tree),
             &(&1.type == :sheet and &1.props[:id] == "memory-delete-confirm")
           )

    assert tap?(tree, :memory_delete)

    view = event(view, {:dismiss, :memory_dismiss_confirm})
    assert view.socket.assigns.workspace_memory.confirming_delete == nil

    view = event(view, {:tap, {:memory_ask_delete, memory.id}})
    view = view |> event({:tap, :memory_delete}) |> settle()
    assert Handbean.Repo.get(Engram, memory.id) == nil
    assert view.socket.assigns.workspace_memory.confirming_delete == nil
  end

  test "HomeScreen loads and filters the current workspace without leaking another workspace" do
    suffix = System.unique_integer([:positive])
    workspace_id = "mobile-memory-#{suffix}"
    other_workspace_id = "mobile-memory-other-#{suffix}"

    {:ok, long_term} =
      MemoryStore.learn("Mobile memory long term #{suffix}", :fact,
        short_term: false,
        memory_scope: :workspace,
        workspace_id: workspace_id,
        metadata: %{"source" => "agent"}
      )

    {:ok, short_term} =
      MemoryStore.learn("Mobile memory short term #{suffix}", :pattern,
        short_term: true,
        memory_scope: :workspace,
        workspace_id: workspace_id,
        metadata: %{"source" => "agent"}
      )

    {:ok, other} =
      MemoryStore.learn("Other workspace memory #{suffix}", :rule,
        short_term: false,
        memory_scope: :workspace,
        workspace_id: other_workspace_id,
        metadata: %{"source" => "agent"}
      )

    {:ok, global} =
      MemoryStore.learn("Global mobile memory #{suffix}", :preference,
        short_term: false,
        memory_scope: :global,
        metadata: %{"source" => "user"}
      )

    expired_at = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)

    {:ok, expired} =
      Handbean.Repo.insert(%Engram{
        content: "Expired mobile memory #{suffix}",
        kind: :context,
        short_term: true,
        expires_at: expired_at,
        metadata: %{scope: "workspace", workspace_id: workspace_id}
      })

    ids = Enum.map([long_term, short_term, other, global, expired], & &1.id)

    on_exit(fn ->
      Handbean.Repo.delete_all(from(e in Engram, where: e.id in ^ids))
    end)

    workspace = %{"id" => workspace_id, "name" => "Mobile", "path" => "/tmp/mobile"}
    socket = %Mob.Socket{assigns: State.new(page: :chat, workspace: workspace)}

    view = socket |> event({:tap, {:page, :memory}}) |> settle()
    assert view.socket.assigns.page == :memory
    refute view.socket.assigns.workspace_memory.loading?

    assert MapSet.new(Enum.map(view.socket.assigns.workspace_memory.items, & &1.id)) ==
             MapSet.new([long_term.id, short_term.id])

    refute Enum.any?(view.socket.assigns.workspace_memory.items, &(&1.id == other.id))
    refute Enum.any?(view.socket.assigns.workspace_memory.items, &(&1.id == global.id))

    view = view |> event({:change, :memory_query, "##{long_term.id}"}) |> settle()
    assert Enum.map(view.socket.assigns.workspace_memory.items, & &1.id) == [long_term.id]

    view = view |> event({:change, :memory_query, ""}) |> settle()
    view = view |> event({:tap, {:memory_lifecycle, :expired}}) |> settle()
    assert Enum.map(view.socket.assigns.workspace_memory.items, & &1.id) == [expired.id]

    view = view |> event({:tap, {:memory_lifecycle, :active}}) |> settle()
    view = view |> event({:tap, {:memory_scope, :both}}) |> settle()
    ids_in_both = Enum.map(view.socket.assigns.workspace_memory.items, & &1.id)
    assert global.id in ids_in_both
    refute other.id in ids_in_both

    view = view |> event({:tap, {:memory_kind, :preference}}) |> settle()
    assert Enum.any?(view.socket.assigns.workspace_memory.items, &(&1.id == global.id))
    refute Enum.any?(view.socket.assigns.workspace_memory.items, &(&1.id == long_term.id))

    owner = self()
    Application.put_env(:handbean_probe, :clipboard_put, &send(owner, {:copied, &1}))
    view = event(view, {:tap, {:memory_copy, :content, global.id}})
    assert_receive {:copied, copied}
    assert copied == global.content
    assert view.socket.assigns.notice

    tree = HomeScreen.render(view.socket.assigns)
    assert flatten_text(tree) =~ "Workspace Memory"
    assert tap?(tree, {:page, :memory})
  end

  defp event(%{socket: socket} = view, message) do
    {:noreply, socket} = HomeScreen.handle_info(message, socket)
    %{view | socket: socket}
  end

  defp event(socket, message) do
    {:noreply, socket} = HomeScreen.handle_info(message, socket)
    %{module: HomeScreen, socket: socket}
  end

  defp tap?(node, tag),
    do: Enum.any?(walk(node), &match?(%{props: %{on_tap: {_, ^tag}}}, &1))

  defp flatten_text(node) do
    node
    |> walk()
    |> Enum.map(& &1.props[:text])
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp walk(list) when is_list(list), do: Enum.flat_map(list, &walk/1)
  defp walk(%{children: children} = node), do: [node | walk(children)]
  defp walk(%{} = node), do: [node]
  defp walk(_), do: []

  defp restore_env(key, nil), do: Application.delete_env(:handbean_probe, key)
  defp restore_env(key, value), do: Application.put_env(:handbean_probe, key, value)
end
