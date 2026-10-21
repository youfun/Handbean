defmodule HandbeanWeb.WorkspaceLive.InfoEvents do
  @moduledoc false

  use HandbeanWeb, :html

  import Phoenix.LiveView

  require Logger

  alias HandbeanWeb.WorkspaceLive.Composer
  alias HandbeanWeb.WorkspaceLive.ConversationRouting
  alias HandbeanWeb.WorkspaceLive.ConversationSwitching
  alias HandbeanWeb.WorkspaceLive.ConversationState
  alias HandbeanWeb.WorkspaceLive.ModelSelection
  alias HandbeanWeb.WorkspaceLive.RuntimeProjection
  alias HandbeanWeb.WorkspaceLive.Schedules
  alias HandbeanWeb.WorkspaceLive.WorkspaceNavigation

  def handle({:file_browser_closed}, socket) do
    {:noreply, WorkspaceNavigation.close_file_browser(socket)}
  end

  def handle({:folder_selected_from_browser, path}, socket) do
    {:noreply, WorkspaceNavigation.folder_selected(socket, path)}
  end

  def handle({:workspace_imported, item}, socket) when is_map(item) do
    {:noreply, WorkspaceNavigation.import_workspace(socket, item)}
  end

  def handle(
        {:conversation_permission_mode_changed, conversation_id, _mode, _run_id, _revision},
        socket
      ) do
    reload_permission_mode(socket, conversation_id)
  end

  def handle(
        {:conversation_permission_mode_changed, conversation_id, _mode, _run_id},
        socket
      ) do
    reload_permission_mode(socket, conversation_id)
  end

  def handle({:workspace_permission_policy_changed, _settings_path}, socket) do
    {:noreply, socket}
  end

  def handle({:speech_enabled, false}, socket) do
    {:noreply,
     socket
     |> assign(:speech_available?, false)
     |> Composer.invalidate_speech()
     |> assign(:speech_state, :disabled)}
  end

  def handle({:speech_enabled, true}, socket) do
    status = Handbean.Speech.status()

    {:noreply,
     socket
     |> assign(:speech_available?, Handbean.Speech.available?())
     |> assign(:speech_state, status)}
  end

  def handle({:speech_status, status}, socket) do
    active_request? = not is_nil(socket.assigns.speech_request)

    available? =
      Handbean.Speech.enabled?() and Handbean.Speech.supported?() and
        (status in [:ready, :transcribing] or active_request?)

    {:noreply,
     socket
     |> assign(:speech_available?, available?)
     |> assign(:speech_state, status)}
  end

  def handle({:agent_event, event}, socket) do
    {:noreply, project_event(socket, event)}
  end

  def handle(%Handbean.PubSub.AgentEvent{} = event, socket) do
    {:noreply, project_event(socket, event)}
  end

  def handle({:runtime_tasks, snapshot}, socket) do
    {:noreply, assign(socket, :runtime_tasks, snapshot)}
  end

  def handle({:in_app_ended, task, reason}, socket) do
    if task.conversation_id == socket.assigns.current_conversation_id do
      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :info, in_app_ended_flash(task, reason))}
    end
  end

  def handle({:conversations_pending_delete, ids}, socket) when is_list(ids) do
    {socket, next_id} =
      ConversationSwitching.conversations_pending_delete(
        socket,
        ids,
        ModelSelection.state_opts()
      )

    {:noreply,
     socket
     |> assign(:delete_conversation, nil)
     |> ConversationRouting.navigate_after_delete(next_id)}
  end

  def handle({:conversation_updated, conv_id}, socket) do
    socket =
      socket
      |> refresh_conversation_in_sidebar(conv_id)
      |> ConversationState.maybe_patch_current_page_title(conv_id)

    if socket.assigns.current_conversation_id == conv_id do
      send(self(), {:conversation_handoffs, conv_id})
    end

    {:noreply, socket}
  end

  def handle({:conversation_title_ready, conv_id, title}, socket)
      when is_binary(conv_id) and is_binary(title) do
    {:noreply,
     socket
     |> apply_sidebar_title(conv_id, title)
     |> ConversationState.maybe_patch_page_title(conv_id, title)}
  end

  def handle({:schedule_auto_title, conv_id, message}, socket)
      when is_binary(conv_id) and is_binary(message) do
    if socket.assigns.current_conversation_id == conv_id do
      {:noreply, ConversationState.schedule_auto_title(socket, message)}
    else
      {:noreply, socket}
    end
  end

  def handle({:conversation_handoffs, conv_id}, socket) do
    socket =
      if socket.assigns.current_conversation_id == conv_id do
        case Handbean.ConversationTranscriptStore.list(conv_id) do
          {:ok, entries} ->
            RuntimeProjection.reconcile_handoffs(socket, entries)

          _ ->
            socket
        end
      else
        socket
      end

    {:noreply, socket}
  end

  # Ghostty LiveTerminal.Component sends terminal_ready to parent LiveView.
  # Forward it so the session PTY matches the fitted viewport.
  def handle({:terminal_ready, id, cols, rows}, socket) do
    if socket.assigns[:show_terminal] do
      send_update(HandbeanWeb.Live.TerminalPanel,
        id: "terminal-panel",
        action: {:terminal_ready, id, cols, rows}
      )
    end

    {:noreply, socket}
  end

  # Forward terminal PubSub events to TerminalPanel component.
  # TerminalPanel is a LiveComponent sharing this LiveView process,
  # so its PubSub subscriptions arrive here.
  def handle({:terminal_refresh, ws_id, checkout_key, term_name}, socket) do
    if terminal_scope?(socket, ws_id, checkout_key) do
      send_update(HandbeanWeb.Live.TerminalPanel,
        id: "terminal-panel",
        action: {:terminal_refresh, term_name}
      )
    end

    {:noreply, socket}
  end

  def handle({:terminal_refresh, ws_id, term_name}, socket) do
    if ws_id == socket.assigns.current_workspace_id do
      send_update(HandbeanWeb.Live.TerminalPanel,
        id: "terminal-panel",
        action: {:terminal_refresh, term_name}
      )
    end

    {:noreply, socket}
  end

  def handle({:terminal_exited, ws_id, checkout_key, term_name, status}, socket) do
    if terminal_scope?(socket, ws_id, checkout_key) do
      send_update(HandbeanWeb.Live.TerminalPanel,
        id: "terminal-panel",
        action: {:terminal_exited, term_name, status}
      )
    end

    {:noreply, socket}
  end

  def handle({:terminal_exited, ws_id, term_name, status}, socket) do
    if ws_id == socket.assigns.current_workspace_id do
      send_update(HandbeanWeb.Live.TerminalPanel,
        id: "terminal-panel",
        action: {:terminal_exited, term_name, status}
      )
    end

    {:noreply, socket}
  end

  # Catch-all for unknown pubsub messages
  def handle({:ext_ui, %{event: "status", text: text}}, socket) do
    {:noreply, assign(socket, :ext_status_text, text)}
  end

  def handle({:ext_ui, %{event: "notify", type: type, text: text}}, socket) do
    {:noreply,
     socket
     |> put_flash(String.to_atom(type), text)
     |> assign(:ext_notification, %{type: type, text: text})}
  end

  def handle({:ext_ui, %{event: event, data: data}}, socket) do
    {:noreply, assign(socket, :ext_widget_data, %{event: event, data: data})}
  end

  def handle({:schedule_changed, _conv_id}, socket) do
    {:noreply, Schedules.reload(socket)}
  end

  def handle({:schedule_notice, conv_id, entry}, socket) do
    socket =
      if socket.assigns.current_conversation_id == conv_id do
        RuntimeProjection.timeline_insert(socket, entry)
      else
        socket
      end

    {:noreply, Schedules.reload(socket)}
  end

  def handle({:arm_browser_capture, token}, socket) do
    {:noreply, assign(socket, :browser_capture_token, token)}
  end

  def handle({:browser_surface_state, conversation_id, summary}, socket) do
    if browser_panel_current?(socket, conversation_id) do
      send_update(HandbeanWeb.WorkspaceLive.BrowserPanel,
        id: "browser-panel",
        surface: summary
      )
    end

    {:noreply, socket}
  end

  def handle({:browser_markers, conversation_id, markers}, socket) do
    if browser_panel_current?(socket, conversation_id) do
      {:noreply, push_event(socket, "browser_markers", %{annotations: markers})}
    else
      {:noreply, socket}
    end
  end

  def handle({:browser_frame, conversation_id, frame}, socket) do
    if browser_panel_current?(socket, conversation_id) do
      {:noreply, push_event(socket, "browser_frame", frame)}
    else
      {:noreply, socket}
    end
  end

  def handle({:browser_annotation_ready, conversation_id, token, payload, path}, socket) do
    if socket.assigns.current_conversation_id == conversation_id and
         socket.assigns.browser_capture_token == token do
      {:noreply, deliver_browser_annotation(socket, payload, path)}
    else
      {:noreply, socket}
    end
  end

  def handle(msg, socket) do
    Logger.debug("[WorkspaceLive] unhandled message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp terminal_scope?(socket, workspace_id, checkout_key) do
    current_key =
      case socket.assigns[:workspace_root] do
        path when is_binary(path) -> Handbean.CheckoutScope.key(path)
        _ -> nil
      end

    workspace_id == socket.assigns.current_workspace_id and checkout_key == current_key
  end

  defp browser_panel_current?(socket, conversation_id) do
    socket.assigns.current_conversation_id == conversation_id and
      socket.assigns.right_panel_view == :browser
  end

  defp deliver_browser_annotation(socket, payload, path) do
    {payload, attachments} = browser_screenshot(socket, payload, path)
    prompt = Handbean.BrowserAnnotation.format_prompt(payload)
    Composer.restore_draft(socket, %{content: prompt, attachments: attachments})
  end

  defp browser_screenshot(socket, payload, path) do
    too_many? = length(socket.assigns.pending_attachments) >= 4

    cond do
      too_many? or not is_binary(path) ->
        {%{payload | screenshot: false}, []}

      true ->
        case Composer.import_image_file(socket, path) do
          {:ok, attachment} ->
            {%{payload | screenshot: true}, [attachment]}

          {:error, _} ->
            {%{payload | screenshot: false}, []}
        end
    end
  end

  defp project_event(socket, event) do
    socket = RuntimeProjection.apply(socket, event)
    socket = maybe_refresh_workspace_identity(socket, event)

    socket =
      if schedule_tool_finished?(event) do
        Schedules.reload(socket)
      else
        socket
      end

    WorkspaceNavigation.finish_runtime(socket)
  end

  defp maybe_refresh_workspace_identity(socket, %{kind: kind})
       when kind in [:run_end, "run_end"] do
    case socket.assigns[:current_workspace_id] do
      workspace_id when is_binary(workspace_id) ->
        with {:ok, workspace} <- Handbean.WorkspaceStore.get(workspace_id),
             true <- workspace["kind"] == "directory",
             true <- File.exists?(Path.join(workspace["path"], ".git")),
             {:ok, refreshed} <- Handbean.WorkspaceStore.refresh_identity(workspace_id) do
          socket
          |> assign(:workspaces, Handbean.WorkspaceStore.list())
          |> assign(:workspace_path, refreshed["path"])
        else
          _ -> socket
        end

      _ ->
        socket
    end
  end

  defp maybe_refresh_workspace_identity(socket, _event), do: socket

  defp schedule_tool_finished?(%{kind: kind, payload: payload})
       when kind in [:tool_end, "tool_end"] do
    to_string(Handbean.Utils.SafeMap.get_any(payload, [:tool, "tool"]) || "") == "schedule"
  end

  defp schedule_tool_finished?(_event), do: false

  # ── Agent event dispatch ──

  # ── Auto-title generation (Qwen Code pattern) ──
  #
  # Start as soon as the user sends the first message. Waiting for :completed
  # leaves the sidebar on "New chat" for the whole agent run.

  # ── Conversation state helpers ──

  defp refresh_conversation_in_sidebar(socket, conv_id),
    do: ConversationSwitching.refresh_conversation_in_sidebar(socket, conv_id)

  defp apply_sidebar_title(socket, conv_id, title, source \\ "auto"),
    do: ConversationSwitching.apply_sidebar_title(socket, conv_id, title, source)

  defp reload_permission_mode(socket, conversation_id) do
    if socket.assigns.current_conversation_id == conversation_id do
      {:noreply,
       assign(
         socket,
         :permission_mode,
         Handbean.Permissions.ConversationMode.get(conversation_id)
       )}
    else
      {:noreply, socket}
    end
  end

  defp in_app_ended_flash(task, reason) do
    %{
      body: in_app_ended_message(task, reason),
      navigate: in_app_ended_path(task),
      navigate_with: :patch
    }
  end

  defp in_app_ended_path(%{conversation_id: conv_id, workspace_id: ws_id})
       when is_binary(conv_id) and is_binary(ws_id) and conv_id != "" and ws_id != "" do
    "/w/#{ws_id}/c/#{conv_id}"
  end

  defp in_app_ended_path(_task), do: nil

  defp in_app_ended_message(task, reason) do
    title = task[:title] || gettext("conversation")

    case reason do
      :cancelled -> gettext("Agent stopped in %{title}.", title: title)
      :failed -> gettext("This run ended in %{title}.", title: title)
      _ -> gettext("Agent replied in %{title}.", title: title)
    end
  end
end
