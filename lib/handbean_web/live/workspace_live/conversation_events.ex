defmodule HandbeanWeb.WorkspaceLive.ConversationEvents do
  @moduledoc false

  use HandbeanWeb, :html

  import Phoenix.LiveView

  require Logger

  alias HandbeanWeb.WorkspaceLive.CliSelection
  alias HandbeanWeb.WorkspaceLive.ConversationRouting
  alias HandbeanWeb.WorkspaceLive.ConversationState
  alias HandbeanWeb.WorkspaceLive.ConversationSwitching
  alias HandbeanWeb.WorkspaceLive.ModelSelection
  alias HandbeanWeb.WorkspaceLive.RuntimeProjection
  alias HandbeanWeb.WorkspaceLive.ViewComponents
  alias HandbeanWeb.WorkspaceLive.WorkspaceNavigation

  def handle("open_add_project", _params, socket) do
    {:noreply, WorkspaceNavigation.open_add_project(socket)}
  end

  def handle("cancel_add_project", _params, socket) do
    {:noreply, WorkspaceNavigation.cancel_add_project(socket)}
  end

  def handle("update_add_path", %{"value" => path}, socket) do
    {:noreply, WorkspaceNavigation.update_add_path(socket, path)}
  end

  def handle("update_add_name", %{"value" => name}, socket) do
    {:noreply, WorkspaceNavigation.update_add_name(socket, name)}
  end

  def handle("toggle_add_project_memory", _params, socket) do
    {:noreply, WorkspaceNavigation.toggle_add_project_memory(socket)}
  end

  def handle("confirm_add_project", _params, socket) do
    WorkspaceNavigation.confirm_add_event(socket)
  end

  def handle("browse_folder", _params, socket) do
    {:noreply, WorkspaceNavigation.browse_folder(socket)}
  end

  def handle("select_workspace", %{"id" => ws_id}, socket) do
    socket = ConversationRouting.drop_composer_for_switch(socket)
    socket = WorkspaceNavigation.expand_group(socket, ws_id)
    {socket, conv_id} = ConversationSwitching.select_workspace(socket, ws_id)

    socket =
      socket
      |> WorkspaceNavigation.after_switch()
      |> RuntimeProjection.subscribe_session()
      |> ConversationRouting.restore_session()
      |> WorkspaceNavigation.close_mobile_sheets()

    {:noreply, push_patch(socket, to: "/w/#{ws_id}/c/#{conv_id}")}
  end

  def handle("load_older_history", _params, socket) do
    {:noreply, ConversationState.load_older_history(socket)}
  end

  def handle("select_conversation", %{"id" => conv_id, "ws_id" => ws_id}, socket) do
    with {:ok, %{"workspace_id" => ^ws_id}} <-
           Handbean.ConversationStore.get(conv_id, include_timeline?: false) do
      socket = ConversationRouting.drop_composer_for_switch(socket, conv_id)
      {socket, _conv_id} = ConversationSwitching.select_conversation(socket, ws_id, conv_id)

      socket =
        socket
        |> WorkspaceNavigation.after_switch()
        |> RuntimeProjection.subscribe_session()
        |> ConversationRouting.restore_session()
        |> WorkspaceNavigation.close_mobile_sheets()

      {:noreply, push_patch(socket, to: "/w/#{ws_id}/c/#{conv_id}")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle("select_archived_conversation", %{"id" => conv_id} = params, socket) do
    with {:ok, conv} <- Handbean.ConversationStore.get(conv_id, include_timeline?: false) do
      if Handbean.ConversationStore.free?(conv) do
        socket = ConversationRouting.drop_composer_for_switch(socket, conv_id)
        {socket, _conv_id} = ConversationSwitching.select_free_conversation(socket, conv_id)

        socket =
          socket
          |> WorkspaceNavigation.enter_free_chat()
          |> RuntimeProjection.subscribe_session()
          |> ConversationRouting.restore_session()
          |> WorkspaceNavigation.close_mobile_sheets()

        {:noreply, push_patch(socket, to: "/c/#{conv_id}")}
      else
        ws_id = params["ws"] || conv["workspace_id"]

        with true <- is_binary(ws_id),
             {:ok, %{"workspace_id" => ^ws_id}} <- {:ok, conv} do
          socket = ConversationRouting.drop_composer_for_switch(socket, conv_id)

          {socket, _conv_id} =
            ConversationSwitching.select_archived_conversation(socket, ws_id, conv_id)

          socket =
            socket
            |> WorkspaceNavigation.after_switch()
            |> RuntimeProjection.subscribe_session()
            |> ConversationRouting.restore_session()
            |> WorkspaceNavigation.close_mobile_sheets()

          {:noreply, push_patch(socket, to: "/w/#{ws_id}/c/#{conv_id}")}
        else
          _ -> {:noreply, socket}
        end
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle("toggle_conversation_menu", %{"id" => conv_id}, socket) do
    menu_id = if socket.assigns.conversation_menu_id == conv_id, do: nil, else: conv_id
    {:noreply, assign(socket, :conversation_menu_id, menu_id)}
  end

  def handle("open_conversation_context_menu", %{"id" => conv_id}, socket) do
    {:noreply, assign(socket, :conversation_menu_id, conv_id)}
  end

  def handle("close_conversation_menu", _params, socket) do
    {:noreply, assign(socket, :conversation_menu_id, nil)}
  end

  def handle("toggle_pin_conversation", %{"id" => conv_id}, socket) do
    socket = assign(socket, :conversation_menu_id, nil)

    socket =
      case Handbean.ConversationStore.get(conv_id, include_timeline?: false) do
        {:ok, conv} ->
          if Handbean.ConversationStore.internal?(conv) do
            socket
          else
            result =
              if Handbean.ConversationStore.pinned_conversation?(conv),
                do: Handbean.ConversationStore.unpin(conv_id),
                else: Handbean.ConversationStore.pin(conv_id)

            case result do
              {:ok, _} ->
                ConversationSwitching.refresh_conversation_in_sidebar(socket, conv_id)

              _ ->
                socket
            end
          end

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle("open_rename_conversation", %{"id" => conv_id} = params, socket) do
    case Handbean.ConversationStore.get(conv_id, include_timeline?: false) do
      {:ok, %{"title" => title} = conv} ->
        free? = Handbean.ConversationStore.free?(conv)
        ws_id = params["ws_id"]

        if free? or conv["workspace_id"] == ws_id do
          {:noreply,
           socket
           |> assign(:conversation_menu_id, nil)
           |> assign(:rename_conversation, %{
             id: conv_id,
             workspace_id: if(free?, do: nil, else: ws_id),
             title: title || "",
             error: nil
           })}
        else
          {:noreply, assign(socket, :conversation_menu_id, nil)}
        end

      _ ->
        {:noreply, assign(socket, :conversation_menu_id, nil)}
    end
  end

  def handle("cancel_rename_conversation", _params, socket) do
    {:noreply, assign(socket, :rename_conversation, nil)}
  end

  def handle("open_delete_conversation", %{"id" => conv_id} = params, socket) do
    case Handbean.ConversationStore.delete_preview(conv_id) do
      {:ok, preview} ->
        workspace_matches? =
          preview.scope == "free" or preview.workspace_id == params["ws_id"] or
            preview.workspace_id == socket.assigns.current_workspace_id

        if workspace_matches? do
          {:noreply,
           socket
           |> assign(:conversation_menu_id, nil)
           |> assign(:rename_conversation, nil)
           |> assign(:delete_conversation, Map.put(preview, :error, nil))}
        else
          {:noreply, assign(socket, :conversation_menu_id, nil)}
        end

      {:error, :not_found} ->
        {:noreply, assign(socket, :conversation_menu_id, nil)}
    end
  end

  def handle("cancel_delete_conversation", _params, socket) do
    {:noreply, assign(socket, :delete_conversation, nil)}
  end

  def handle("confirm_delete_conversation", _params, socket) do
    case socket.assigns.delete_conversation do
      %{id: conv_id} = pending ->
        case Handbean.ConversationStore.request_delete(conv_id) do
          {:ok, ids} ->
            {socket, next_id} =
              ConversationSwitching.conversations_pending_delete(
                socket,
                ids,
                ModelSelection.state_opts()
              )

            socket =
              socket
              |> assign(:delete_conversation, nil)
              |> ConversationRouting.navigate_after_delete(next_id)

            {:noreply, socket}

          {:error, :not_found} ->
            {:noreply, assign(socket, :delete_conversation, nil)}

          {:error, _reason} ->
            {:noreply,
             assign(socket, :delete_conversation, %{
               pending
               | error: gettext("删除请求失败，请重试")
             })}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle("confirm_rename_conversation", %{"title" => title}, socket) do
    case socket.assigns.rename_conversation do
      %{id: conv_id} = rename ->
        case Handbean.ConversationStore.rename(conv_id, title) do
          {:ok, meta} ->
            {:noreply,
             socket
             |> ConversationSwitching.refresh_conversation_in_sidebar(conv_id)
             |> ConversationState.maybe_patch_page_title(conv_id, meta["title"])
             |> assign(:rename_conversation, nil)}

          {:error, :empty} ->
            {:noreply,
             assign(socket, :rename_conversation, %{
               rename
               | title: title,
                 error: gettext("名称不能为空")
             })}

          {:error, :too_long} ->
            {:noreply,
             assign(socket, :rename_conversation, %{
               rename
               | title: title,
                 error: gettext("名称不能超过 80 个字符")
             })}

          {:error, _reason} ->
            {:noreply,
             assign(socket, :rename_conversation, %{
               rename
               | title: title,
                 error: gettext("重命名失败")
             })}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle("archive_conversation", %{"id" => conv_id} = params, socket) do
    socket =
      socket
      |> assign(:conversation_menu_id, nil)
      |> assign(:rename_conversation, nil)

    with {:ok, conv} <- Handbean.ConversationStore.get(conv_id, include_timeline?: false) do
      free? = Handbean.ConversationStore.free?(conv)
      ws_id = conv["workspace_id"] || params["ws_id"] || socket.assigns.current_workspace_id

      {socket, next_conv_id} =
        ConversationSwitching.archive_conversation(
          socket,
          conv_id,
          ws_id,
          ModelSelection.state_opts()
        )

      socket =
        cond do
          next_conv_id && free? ->
            socket
            |> WorkspaceNavigation.enter_free_chat()
            |> RuntimeProjection.subscribe_session()
            |> push_patch(to: "/c/#{next_conv_id}")

          next_conv_id && is_binary(ws_id) ->
            socket
            |> WorkspaceNavigation.after_switch()
            |> RuntimeProjection.subscribe_session()
            |> push_patch(to: "/w/#{ws_id}/c/#{next_conv_id}")

          true ->
            socket
        end

      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle("unarchive_conversation", %{"id" => conv_id}, socket) do
    {:noreply, ConversationSwitching.unarchive_conversation(socket, conv_id)}
  end

  # ── Archive toggle ──

  def handle("toggle_archive", _params, socket) do
    {:noreply, update(socket, :show_archive, &(!&1))}
  end

  def handle("toggle_workspace_group", %{"id" => id}, socket)
      when is_binary(id) do
    {:noreply, WorkspaceNavigation.toggle_group(socket, id)}
  end

  def handle("toggle_thread", %{"id" => id}, socket) when is_binary(id) do
    {:noreply, ConversationSwitching.toggle_thread(socket, id)}
  end

  def handle("show_more_conversations", %{"bucket" => bucket}, socket)
      when is_binary(bucket) do
    {:noreply, ConversationSwitching.show_more_conversations(socket, bucket)}
  end

  def handle("open_rename_workspace", %{"id" => ws_id}, socket) do
    case Handbean.WorkspaceStore.get(ws_id) do
      {:ok, ws} ->
        {:noreply,
         assign(socket, :rename_workspace, %{
           id: ws["id"],
           name: ws["name"] || "",
           error: nil
         })}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  def handle("cancel_rename_workspace", _params, socket) do
    {:noreply, assign(socket, :rename_workspace, nil)}
  end

  def handle("confirm_rename_workspace", %{"name" => name}, socket) do
    case socket.assigns.rename_workspace do
      %{id: ws_id} = rename ->
        case Handbean.WorkspaceStore.rename(ws_id, name) do
          {:ok, ws} ->
            socket =
              socket
              |> assign(:workspaces, Handbean.WorkspaceStore.list())
              |> assign(:rename_workspace, nil)

            socket =
              if socket.assigns.current_workspace_id == ws_id,
                do: assign(socket, :workspace_label, ws["name"]),
                else: socket

            {:noreply, socket}

          {:error, :empty} ->
            {:noreply,
             assign(socket, :rename_workspace, %{rename | name: name, error: gettext("名称不能为空")})}

          {:error, :too_long} ->
            {:noreply,
             assign(socket, :rename_workspace, %{
               rename
               | name: name,
                 error: gettext("名称不能超过 80 个字符")
             })}

          {:error, _reason} ->
            {:noreply,
             assign(socket, :rename_workspace, %{rename | name: name, error: gettext("重命名失败")})}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle("open_remove_workspace", %{"id" => ws_id}, socket) do
    {:noreply, WorkspaceNavigation.open_remove_workspace(socket, ws_id)}
  end

  def handle("cancel_remove_workspace", _params, socket) do
    {:noreply, WorkspaceNavigation.cancel_remove_workspace(socket)}
  end

  def handle("confirm_remove_workspace", _params, socket) do
    case socket.assigns.remove_workspace do
      %{id: ws_id} ->
        case ConversationSwitching.remove_workspace(socket, ws_id) do
          {:ok, socket, _removed} ->
            socket =
              if socket.assigns.current_workspace_id == ws_id do
                WorkspaceNavigation.switch_away_from_removed_workspace(socket)
              else
                socket
              end

            {:noreply, socket}

          {:error, :default_workspace} ->
            {:noreply,
             socket
             |> assign(:remove_workspace, nil)
             |> put_flash(:error, gettext("默认工作区不能移除"))}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(:remove_workspace, nil)
             |> put_flash(:error, gettext("移除工作区失败"))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle("retry_conversation_list", _params, socket) do
    {:noreply, ConversationSwitching.load_conversation_list(socket)}
  end

  def handle("new_conversation", _params, socket) do
    ConversationRouting.begin_conversation_in_workspace(
      socket,
      socket.assigns.current_workspace_id,
      source: :sidebar,
      close_sheets?: false
    )
  end

  def handle("toggle_new_conversation_picker", _params, socket) do
    {:noreply, ConversationSwitching.toggle_new_conversation_picker(socket)}
  end

  def handle("new_free_conversation", _params, socket) do
    socket = ConversationRouting.drop_composer_for_switch(socket)

    {socket, conv_id} =
      ConversationSwitching.new_free_conversation(socket, ModelSelection.switching_opts())

    socket =
      socket
      |> WorkspaceNavigation.expand_group("free")
      |> WorkspaceNavigation.enter_free_chat()
      |> RuntimeProjection.subscribe_session()
      |> WorkspaceNavigation.close_mobile_sheets()

    {:noreply, push_patch(socket, to: "/c/#{conv_id}")}
  end

  def handle("select_free_conversation", %{"id" => conv_id}, socket) do
    with {:ok, conv} <- Handbean.ConversationStore.get(conv_id, include_timeline?: false),
         true <- Handbean.ConversationStore.free?(conv) do
      socket = ConversationRouting.drop_composer_for_switch(socket, conv_id)
      {socket, _conv_id} = ConversationSwitching.select_free_conversation(socket, conv_id)

      socket =
        socket
        |> WorkspaceNavigation.enter_free_chat()
        |> RuntimeProjection.subscribe_session()
        |> ConversationRouting.restore_session()
        |> WorkspaceNavigation.close_mobile_sheets()

      {:noreply, push_patch(socket, to: "/c/#{conv_id}")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle("new_conversation_in_workspace", %{"ws_id" => ws_id} = params, socket) do
    source = if params["source"] == "header", do: :header, else: :sidebar

    ConversationRouting.begin_conversation_in_workspace(socket, ws_id,
      source: source,
      close_sheets?: false
    )
  end

  def handle("mobile_new_conversation_in_workspace", %{"ws_id" => ws_id}, socket) do
    ConversationRouting.begin_conversation_in_workspace(socket, ws_id,
      source: :mobile,
      close_sheets?: true
    )
  end

  def handle("new_conversation_on_checkout", %{"ws_id" => ws_id, "path" => path}, socket) do
    ConversationRouting.begin_conversation_in_workspace(socket, ws_id,
      checkout_path: path,
      close_sheets?: get_in(socket.assigns, [:checkout_picker, :source]) == :mobile
    )
  end

  def handle("close_checkout_picker", _params, socket) do
    {:noreply, ConversationSwitching.close_checkout_picker(socket)}
  end

  def handle("open_settings", _, socket) do
    {:noreply,
     push_navigate(socket,
       to:
         ViewComponents.settings_href(
           socket.assigns.current_workspace_id,
           socket.assigns.current_conversation_id
         )
     )}
  end

  def handle("open_sheet", %{"type" => type}, socket) do
    {:noreply, WorkspaceNavigation.open_sheet(socket, type)}
  end

  def handle("close_sheets", _params, socket) do
    {:noreply, WorkspaceNavigation.close_sheet_panels(socket)}
  end

  def handle("select_model_from_sheet", %{"model" => model}, socket) do
    {:noreply, ModelSelection.select_from_sheet(socket, model)}
  end

  def handle("select_reasoning_from_sheet", %{"level" => level}, socket) do
    {:noreply,
     socket
     |> ModelSelection.select_reasoning_from_sheet(level)
     |> CliSelection.remember_current()}
  end

  def handle("toggle_file_drawer", _params, socket) do
    {:noreply, WorkspaceNavigation.toggle_file_drawer(socket)}
  end

  def handle("toggle_right_panel", _params, socket) do
    {:noreply, WorkspaceNavigation.toggle_right_panel(socket)}
  end

  def handle("set_right_panel_collapsed", %{"collapsed" => collapsed}, socket) do
    {:noreply, WorkspaceNavigation.set_right_panel_collapsed(socket, collapsed)}
  end

  def handle("toggle_tool_work", %{"group" => group_id}, socket)
      when is_binary(group_id) and group_id != "" do
    expanded = Map.get(socket.assigns, :expanded_tool_groups, MapSet.new())

    expanded =
      if MapSet.member?(expanded, group_id) do
        MapSet.delete(expanded, group_id)
      else
        MapSet.put(expanded, group_id)
      end

    {:noreply,
     socket
     |> assign(:expanded_tool_groups, expanded)
     |> RuntimeProjection.refresh_tool_work(group_id)}
  end

  def handle("toggle_tool_work", _params, socket), do: {:noreply, socket}

  def handle("toggle_permission_menu", _params, socket) do
    {:noreply, update(socket, :show_permission_menu, &(!&1))}
  end

  def handle("select_permission_mode", %{"mode" => mode_str}, socket)
      when mode_str in ["prompt", "auto_review", "yolo"] do
    mode = String.to_existing_atom(mode_str)

    case Handbean.Permissions.ConversationMode.update(
           socket.assigns.current_conversation_id,
           mode,
           source: :web
         ) do
      {:ok, _metadata} ->
        current =
          Handbean.Permissions.ConversationMode.get(socket.assigns.current_conversation_id)

        {:noreply,
         socket
         |> assign(:permission_mode, current)
         |> assign(:show_permission_menu, false)}

      {:error, reason} ->
        Logger.error("[WorkspaceLive] Failed to update permission mode: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:show_permission_menu, false)
         |> put_flash(:error, gettext("Failed to update permission mode"))}
    end
  end

  def handle("select_permission_mode", _params, socket) do
    {:noreply, assign(socket, :show_permission_menu, false)}
  end

  def handle("scroll_to_bottom", _params, socket) do
    {:noreply, push_event(socket, "scroll_chat_to_bottom", %{})}
  end
end
