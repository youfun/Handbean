defmodule HandbeanWeb.WorkspaceLive.WorkspaceNavigation do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [connected?: 1, push_event: 3, push_patch: 2, put_flash: 3]

  alias HandbeanWeb.WorkspaceLive.CliSelection
  alias HandbeanWeb.WorkspaceLive.ConversationState
  alias HandbeanWeb.WorkspaceLive.ConversationSwitching
  alias HandbeanWeb.WorkspaceLive.ModelSelection
  alias HandbeanWeb.WorkspaceLive.RuntimeProjection
  alias HandbeanWeb.WorkspaceLive.Skills
  alias Handbean.WorkspaceFiles
  alias HandbeanWeb.WorkspaceLive.SessionMemory

  def after_switch(socket) do
    socket
    |> ConversationState.sync_conv_state(
      Keyword.merge(ModelSelection.state_opts(), reload?: true)
    )
    |> assign(:workspace_tree, %{})
    |> assign(:expanded_workspace_dirs, MapSet.new())
    |> load_workspace_tree("")
    |> ModelSelection.reload_workspace_models()
    |> ModelSelection.reload_workspace_counts()
    |> load_skills()
    |> load_permission_mode_into_socket()
    |> CliSelection.restore_current()
  end

  def open_add_project(socket) do
    socket
    |> assign(:show_add_project, true)
    |> assign(:add_project_form, new_project_form())
    |> assign(:show_file_browser, false)
  end

  def drop_workspace_path(socket, path) when is_binary(path) do
    if socket.assigns.sandbox_workspace? do
      socket
    else
      path = String.trim(path)

      socket =
        socket
        |> open_add_project()

      if path == "", do: socket, else: update_add_path(socket, path)
    end
  end

  def drop_workspace_path(socket, _path), do: socket

  def confirm_add_event(socket) do
    if socket.assigns.sandbox_workspace? and
         String.trim(socket.assigns.add_project_form["path"] || "") == "" do
      request_sandbox_directory_picker()
      {:noreply, socket}
    else
      confirm_add_project(socket)
    end
  end

  def cancel_add_project(socket) do
    socket
    |> assign(:show_add_project, false)
    |> assign(:show_file_browser, false)
    |> assign(:add_project_form, new_project_form())
  end

  def update_add_path(socket, path) do
    form = socket.assigns.add_project_form |> Map.put("path", path) |> Map.put("error", nil)
    assign(socket, :add_project_form, form)
  end

  def update_add_name(socket, name) do
    form = socket.assigns.add_project_form |> Map.put("name", name) |> Map.put("error", nil)
    assign(socket, :add_project_form, form)
  end

  def toggle_add_project_memory(socket) do
    form =
      Map.update(
        socket.assigns.add_project_form,
        "builtin_memory_enabled",
        false,
        &(&1 != true)
      )

    assign(socket, :add_project_form, form)
  end

  def browse_folder(socket) do
    if socket.assigns.sandbox_workspace? do
      request_sandbox_directory_picker()
      socket
    else
      current = Map.get(socket.assigns.add_project_form, "path", "")

      socket
      |> assign(:show_file_browser, true)
      |> assign(
        :file_browser_path,
        if(current != "" and File.dir?(current), do: current, else: nil)
      )
    end
  end

  def folder_selected(socket, path) do
    form =
      socket.assigns.add_project_form
      |> Map.put("path", path)
      |> Map.put("error", nil)

    socket
    |> assign(:add_project_form, form)
    |> assign(:show_file_browser, false)
  end

  def close_file_browser(socket), do: assign(socket, :show_file_browser, false)

  def import_workspace(socket, item) when is_map(item) do
    path = Handbean.Utils.SafeMap.get_any(item, :path, "path")

    name =
      Handbean.Utils.SafeMap.get_any(item, :name, "name") ||
        Path.basename(to_string(path || ""))

    cond do
      not is_binary(path) or path == "" ->
        socket

      not File.dir?(path) ->
        form = Map.put(socket.assigns.add_project_form, "error", "导入失败：目录不可读")
        assign(socket, :add_project_form, form)

      true ->
        case Handbean.WorkspaceStore.add_selection(path,
               name: name,
               builtin_memory_enabled: socket.assigns.add_project_form["builtin_memory_enabled"]
             ) do
          {:ok, new_ws, checkout_path} ->
            workspaces = Handbean.WorkspaceStore.list()

            socket
            |> ConversationSwitching.select_new_workspace_without_conversation(
              new_ws,
              workspaces,
              checkout_path
            )
            |> cancel_add_project()
            |> ConversationState.sync_conv_state(ModelSelection.state_opts())
            |> ModelSelection.reload_workspace_models()
            |> ModelSelection.reload_workspace_counts()
            |> RuntimeProjection.subscribe_session()

          {:error, reason} ->
            assign(
              socket,
              :add_project_form,
              Map.put(socket.assigns.add_project_form, "error", workspace_error(reason))
            )
        end
    end
  end

  def toggle_directory(socket, relative_path) do
    expanded = socket.assigns.expanded_workspace_dirs

    if MapSet.member?(expanded, relative_path) do
      assign(socket, :expanded_workspace_dirs, MapSet.delete(expanded, relative_path))
    else
      socket
      |> load_workspace_tree(relative_path)
      |> update(:expanded_workspace_dirs, &MapSet.put(&1, relative_path))
    end
  end

  def select_panel(socket, view) when view in ["changes", "files", "browser"] do
    socket
    |> assign(:right_panel_view, String.to_existing_atom(view))
    |> assign(:right_panel_collapsed, false)
    |> assign(:show_terminal, false)
  end

  def reveal_files_panel(socket) do
    socket =
      socket
      |> select_panel("files")

    if Map.get(socket.assigns, :mobile_mode) do
      assign(socket, :mobile_right_panel_open, true)
    else
      socket
    end
  end

  def show_files_mobile(socket) do
    socket
    |> close_sheet_panels()
    |> assign(:mobile_right_panel_open, true)
    |> select_panel("files")
  end

  def show_terminal(socket, mobile? \\ false), do: show_terminal_panel(socket, mobile?)

  def close_mobile_panel(socket), do: assign(socket, :mobile_right_panel_open, false)

  def toggle_file_drawer(socket), do: update(socket, :show_file_drawer, &(!&1))

  def toggle_right_panel(socket) do
    collapsed = !socket.assigns.right_panel_collapsed

    socket
    |> assign(:right_panel_collapsed, collapsed)
    |> push_event("persist_collapsed", %{collapsed: collapsed})
  end

  def set_right_panel_collapsed(socket, collapsed),
    do: assign(socket, :right_panel_collapsed, collapsed)

  def open_sheet(socket, type) do
    case type do
      "workspace" -> assign(socket, :show_workspace_sheet, true)
      "model" -> assign(socket, :show_model_sheet, true)
      "reasoning" -> assign(socket, :show_reasoning_sheet, true)
      _ -> socket
    end
  end

  def close_sheet_panels(socket) do
    socket
    |> assign(:show_workspace_sheet, false)
    |> assign(:show_model_sheet, false)
    |> assign(:show_reasoning_sheet, false)
    |> assign(:show_permission_menu, false)
    |> assign(:show_file_drawer, false)
  end

  def toggle_group(socket, id), do: toggle_workspace_group(socket, id)
  def expand_group(socket, id), do: expand_workspace_group(socket, id)

  def open_remove_workspace(socket, ws_id) do
    case Handbean.WorkspaceStore.get(ws_id) do
      {:ok, %{"default" => true}} ->
        socket

      {:ok, ws} ->
        assign(socket, :remove_workspace, %{id: ws["id"], name: ws["name"]})

      {:error, :not_found} ->
        socket
    end
  end

  def cancel_remove_workspace(socket), do: assign(socket, :remove_workspace, nil)

  def sandbox_workspace?, do: Handbean.Host.configured?() and not Handbean.Host.shell?()

  defp load_skills(socket) do
    checkout_path = ConversationState.current_checkout_path(socket)

    if ConversationState.free_chat?(socket) or not is_binary(checkout_path),
      do: assign(socket, :available_skills, []),
      else: Skills.load(socket, checkout_path)
  end

  defp request_sandbox_directory_picker do
    _ = Handbean.Host.request_directory_picker(%{purpose: :add_workspace})
    :ok
  end

  def confirm_add_project(socket) do
    form = socket.assigns.add_project_form
    path = String.trim(form["path"] || "")
    name = String.trim(form["name"] || "")

    cond do
      path == "" ->
        form = Map.put(form, "error", "请输入项目路径")
        {:noreply, assign(socket, :add_project_form, form)}

      not File.exists?(path) ->
        form = Map.put(form, "error", "目录不存在: #{path}")
        {:noreply, assign(socket, :add_project_form, form)}

      not File.dir?(path) ->
        form = Map.put(form, "error", "路径不是一个目录")
        {:noreply, assign(socket, :add_project_form, form)}

      true ->
        case Handbean.WorkspaceStore.add_selection(path,
               name: if(name != "", do: name, else: Path.basename(path)),
               builtin_memory_enabled: form["builtin_memory_enabled"]
             ) do
          {:ok, new_ws, checkout_path} ->
            workspaces = Handbean.WorkspaceStore.list()

            socket =
              socket
              |> ConversationSwitching.select_new_workspace_without_conversation(
                new_ws,
                workspaces,
                checkout_path
              )
              |> assign(:show_add_project, false)
              |> assign(:show_file_browser, false)
              |> assign(:add_project_form, new_project_form())
              |> ConversationState.sync_conv_state()
              |> ModelSelection.reload_workspace_models()
              |> ModelSelection.reload_workspace_counts()
              |> RuntimeProjection.subscribe_session()

            {:noreply, socket}

          {:error, reason} ->
            form = Map.put(form, "error", workspace_error(reason))
            {:noreply, assign(socket, :add_project_form, form)}
        end
    end
  end

  defp workspace_error(:workspace_format_outdated),
    do: "工作区格式已更新，请重新添加工作区"

  defp workspace_error(:workspace_repo_conflict),
    do: "该仓库已关联到另一个工作区，请使用已有工作区"

  defp workspace_error(reason) when is_binary(reason), do: reason
  defp workspace_error(reason), do: inspect(reason)

  defp new_project_form do
    %{
      "path" => "",
      "name" => "",
      "builtin_memory_enabled" => true,
      "error" => nil
    }
  end

  def switch_away_from_removed_workspace(socket) do
    case Enum.find(socket.assigns.workspaces, & &1["default"]) ||
           List.first(socket.assigns.workspaces) do
      nil ->
        socket

      ws ->
        socket = CliSelection.prepare_switch(socket)
        {socket, conv_id} = ConversationSwitching.select_workspace(socket, ws["id"])

        socket =
          socket
          |> after_switch()
          |> RuntimeProjection.subscribe_session()
          |> RuntimeProjection.restore_active_session()
          |> finish_runtime()
          |> close_mobile_sheets()

        path =
          if conv_id do
            "/w/#{ws["id"]}/c/#{conv_id}"
          else
            "/"
          end

        push_patch(socket, to: path)
    end
  end

  def load_workspace_tree(socket, relative_dir) do
    path = ConversationState.current_checkout_path(socket)

    if is_binary(path) do
      load_workspace_tree(socket, path, relative_dir)
    else
      socket
    end
  end

  defp load_workspace_tree(socket, path, relative_dir) do
    case WorkspaceFiles.list(path, relative_dir, show_hidden: true) do
      {:ok, %{entries: entries}} ->
        socket
        |> update(:workspace_tree, &Map.put(&1, relative_dir, entries))
        |> assign(:workspace_tree_error, nil)

      {:error, reason} ->
        assign(socket, :workspace_tree_error, reason)
    end
  end

  def show_terminal_panel(socket, mobile? \\ false) do
    if Handbean.Terminal.available?() do
      open_terminal_panel(socket, mobile?)
    else
      socket
    end
  end

  def open_terminal_panel(socket, mobile?) do
    checkout_path = ConversationState.current_checkout_path(socket)

    if connected?(socket) and is_binary(checkout_path) do
      with {:ok, checkout} <- Handbean.CheckoutScope.resolve(checkout_path) do
        Phoenix.PubSub.subscribe(
          Handbean.PubSub,
          Handbean.CheckoutScope.terminal_topic(
            socket.assigns.current_workspace_id,
            checkout.key
          )
        )
      end
    end

    socket
    |> then(fn socket ->
      if mobile?, do: close_sheet_panels(socket), else: socket
    end)
    |> assign(:show_terminal, true)
    |> assign(:right_panel_view, :terminal)
    |> assign(:right_panel_collapsed, false)
    |> assign(:mobile_right_panel_open, mobile? or socket.assigns.mobile_right_panel_open)
  end

  def enter_free_chat(socket) do
    socket
    |> assign(:chat_scope, :free)
    |> assign(:right_panel_collapsed, true)
    |> assign(:show_file_drawer, false)
    |> assign(:mobile_right_panel_open, false)
    |> ConversationState.sync_conv_state(reload?: true)
    |> ModelSelection.reload_free_models()
    |> CliSelection.restore_current()
    |> assign(:skill_suggestions, [])
    |> assign(:workspace_tree, %{})
  end

  def toggle_workspace_group(socket, id) do
    id = to_string(id)

    socket
    |> update(:collapsed_workspace_ids, fn collapsed ->
      collapsed = collapsed || MapSet.new()

      if MapSet.member?(collapsed, id),
        do: MapSet.delete(collapsed, id),
        else: MapSet.put(collapsed, id)
    end)
    |> SessionMemory.persist_collapsed()
  end

  def expand_workspace_group(socket, id) do
    id = to_string(id)

    socket
    |> update(:collapsed_workspace_ids, fn collapsed ->
      MapSet.delete(collapsed || MapSet.new(), id)
    end)
    |> SessionMemory.persist_collapsed()
  end

  def close_mobile_sheets(socket) do
    socket
    |> assign(:show_workspace_sheet, false)
    |> assign(:show_model_sheet, false)
    |> assign(:show_reasoning_sheet, false)
    |> assign(:show_permission_menu, false)
    |> assign(:show_file_drawer, false)
    |> assign(:mobile_right_panel_open, false)
    |> assign(:conversation_menu_id, nil)
    |> assign(:new_conversation_draft, nil)
  end

  def open_preview_display(socket, preview_id, client) do
    conversation_id = socket.assigns.current_conversation_id

    case Handbean.Preview.fetch_open(preview_id) do
      {:ok, record} ->
        if record.conversation_id != conversation_id do
          put_flash(socket, :error, "preview belongs to another conversation")
        else
          url = Handbean.Preview.shell_url(preview_id, HandbeanWeb.Endpoint.url())

          meta = %{
            conversation_id: conversation_id,
            preview_id: preview_id,
            url: url,
            client: client,
            bind_listen?: false
          }

          case Handbean.NativeDisplay.command(
                 %{
                   op: if(client == :external, do: :open_external, else: :show),
                   owner: :preview,
                   id: preview_id,
                   url: url,
                   conversation_id: conversation_id,
                   generation: 1
                 },
                 []
               ) do
            {:error, :not_configured} ->
              _ = Handbean.Browser.Display.show(:preview, preview_id, meta)

              if client == :external do
                push_event(socket, "open_preview_url", %{url: url, bind_listen: false})
              else
                socket
              end

            {:ok, _} ->
              _ = Handbean.Browser.Display.show(:preview, preview_id, meta)
              socket

            :ok ->
              _ = Handbean.Browser.Display.show(:preview, preview_id, meta)
              socket

            {:error, reason} ->
              put_flash(socket, :error, "preview display failed: #{inspect(reason)}")
          end
        end

      {:error, :closed} ->
        put_flash(socket, :error, "preview is closed")

      {:error, :not_found} ->
        put_flash(socket, :error, "preview not found")
    end
  end

  def mobile_mode_from_ua(nil), do: false

  def mobile_mode_from_ua(%{"uastring" => ua}) when is_binary(ua) do
    mobile_pattern = ~r/(iPhone|iPad|iPod|Android|Mobile|webOS|BlackBerry|Windows Phone)/i
    String.match?(ua, mobile_pattern)
  end

  def mobile_mode_from_ua(_), do: false

  def finish_runtime(socket) do
    case socket.assigns[:refresh_tree_parent] do
      path when is_binary(path) ->
        socket
        |> assign(:refresh_tree_parent, nil)
        |> refresh_loaded_tree_parent(path)

      _ ->
        socket
    end
  end

  def refresh_loaded_tree_parent(socket, abs_path) do
    case ConversationState.current_checkout_path(socket) do
      checkout_path when is_binary(checkout_path) ->
        relative = Path.relative_to(abs_path, checkout_path)
        refresh_relative_tree_parent(socket, relative)

      _ ->
        socket
    end
  end

  defp refresh_relative_tree_parent(socket, relative) do
    parent =
      case Path.dirname(relative) do
        "." -> ""
        directory -> directory
      end

    if Map.has_key?(socket.assigns.workspace_tree, parent) do
      load_workspace_tree(socket, parent)
    else
      socket
    end
  end

  def load_permission_mode_into_socket(socket) do
    permission_mode =
      socket.assigns.current_conversation_id
      |> Handbean.Permissions.ConversationMode.get()
      |> then(fn mode -> if ConversationState.free_chat?(socket), do: :deny, else: mode end)

    assign(socket, :permission_mode, permission_mode)
  end

  def load_permission_mode(conversation) do
    Handbean.Permissions.ConversationMode.get(conversation)
  end
end
