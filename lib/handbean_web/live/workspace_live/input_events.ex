defmodule HandbeanWeb.WorkspaceLive.InputEvents do
  @moduledoc false

  use HandbeanWeb, :html

  import Phoenix.LiveView

  require Logger

  alias Handbean.Platform.FileManager
  alias Handbean.WorkspaceFiles
  alias HandbeanWeb.WorkspaceLive.Approval
  alias HandbeanWeb.WorkspaceLive.CliSelection
  alias HandbeanWeb.WorkspaceLive.Composer
  alias HandbeanWeb.WorkspaceLive.ConversationState
  alias HandbeanWeb.WorkspaceLive.EditorProjection
  alias HandbeanWeb.WorkspaceLive.MessageSubmission
  alias HandbeanWeb.WorkspaceLive.ModelSelection
  alias HandbeanWeb.WorkspaceLive.RuntimeProjection
  alias HandbeanWeb.WorkspaceLive.Skills
  alias HandbeanWeb.WorkspaceLive.WidgetCommands
  alias HandbeanWeb.WorkspaceLive.WorkspaceNavigation

  def handle("remove_attachment", %{"id" => id}, socket) do
    {:noreply, Composer.remove_attachment(socket, id)}
  end

  def handle("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :images, ref)}
  end

  def handle("clear_composer_error", _params, socket) do
    {:noreply, assign(socket, :composer_error, nil)}
  end

  def handle("toggle_skills_panel", _params, socket) do
    {:noreply, update(socket, :show_skills_panel, &(!&1))}
  end

  def handle("launch_skill", %{"name" => skill_name}, socket) do
    prompt = Skills.launch_prompt(socket.assigns.available_skills, skill_name)

    socket =
      socket
      |> assign(:show_skills_panel, false)
      |> assign(:input_value, prompt)

    {:noreply, socket}
  end

  def handle("composer_drop", params, socket) do
    # Form-level phx-change also fires when the model/reasoning <select>
    # changes. Ignore those params and the picker snaps back on remorph.
    socket = ModelSelection.apply_submitted(socket, params)

    {:noreply, socket}
  end

  def handle("send_message", params, socket),
    do: socket |> Composer.invalidate_speech() |> MessageSubmission.send_message(params)

  def handle("steer_message", params, socket),
    do: socket |> Composer.invalidate_speech() |> MessageSubmission.steer_message(params)

  def handle("queue_message", params, socket),
    do: socket |> Composer.invalidate_speech() |> MessageSubmission.queue_message(params)

  def handle("send_pending_now", %{"id" => id}, socket),
    do: MessageSubmission.send_pending_now(socket, id)

  def handle("cancel_pending", %{"id" => id}, socket),
    do: MessageSubmission.cancel_pending(socket, id)

  def handle("resend_pending", %{"id" => id}, socket),
    do: MessageSubmission.resend_pending(socket, id)

  def handle("delete_undelivered", %{"id" => id}, socket),
    do: MessageSubmission.delete_undelivered(socket, id)

  def handle("speech_error", %{"reason" => reason}, socket) do
    {:noreply,
     socket
     |> assign(:speech_state, :ready)
     |> assign(:composer_error, speech_error_message(reason))}
  end

  def handle("update_input", %{"value" => value}, socket) do
    suggestions =
      if String.starts_with?(value, "/ext:") and socket.assigns.chat_scope != :free do
        socket
        |> ConversationState.current_checkout_path()
        |> Handbean.WorkspaceCommand.list_commands()
        |> Enum.filter(&String.starts_with?(&1.name, value))
      else
        Skills.suggestions(value, socket.assigns.available_skills)
      end

    {:noreply,
     socket
     |> Composer.track_workspace_command_intent(value)
     |> assign(:input_value, value)
     |> assign(:skill_suggestions, suggestions)}
  end

  def handle("prefill_subagent_follow_up", %{"child" => child}, socket)
      when is_binary(child) and child != "" do
    {:noreply, Composer.prefill_text(socket, "@#{child} ")}
  end

  def handle("widget_command", params, socket) do
    conversation_id = socket.assigns[:current_conversation_id]
    entry = authoritative_widget_entry(conversation_id, params["entry_id"])

    case WidgetCommands.prefill_text(params, entry, conversation_id) do
      {:ok, text} ->
        {:noreply,
         socket
         |> Composer.prefill_text(text)
         |> push_widget_command_result(params, "ok")}

      {:error, reason} ->
        {:noreply, push_widget_command_result(socket, params, "error", reason)}
    end
  end

  def handle("select_skill_suggestion", %{"name" => skill_name}, socket) do
    new_value =
      if String.starts_with?(skill_name, "/ext:") do
        skill_name <> " "
      else
        Skills.select(socket.assigns.input_value, skill_name)
      end

    {:noreply,
     socket
     |> assign(:input_value, new_value)
     |> assign(:skill_suggestions, nil)}
  end

  def handle("dismiss_skill_suggestions", _params, socket) do
    {:noreply, assign(socket, :skill_suggestions, nil)}
  end

  def handle("stop_run", _params, socket), do: MessageSubmission.stop(socket)

  def handle("approve_cli_option", %{"option" => option}, socket) do
    pending = socket.assigns.pending_approval

    if cli_approval?(pending) and is_binary(option) do
      MessageSubmission.resume_cli_approval(socket, pending, {:approve, option})
    else
      {:noreply, socket}
    end
  end

  def handle("approve_all_tools", params, socket) do
    resume_tool_approval(socket, :approve, Approval.remember_scope(params))
  end

  def handle("deny_all_tools", params, socket) do
    resume_tool_approval(socket, :deny, Approval.remember_scope(params))
  end

  def handle("select_cli", params, socket) do
    {:noreply, CliSelection.select(socket, params["cli"] || params["value"])}
  end

  def handle("select_model", params, socket) do
    model = params["model"] || params["value"]

    socket =
      if CliSelection.cli_selected?(socket.assigns),
        do: CliSelection.select_model(socket, model),
        else: ModelSelection.select(socket, model)

    {:noreply, socket}
  end

  def handle("select_reasoning", %{"reasoning" => level}, socket) do
    {:noreply,
     socket |> ModelSelection.select_reasoning(level) |> CliSelection.remember_current()}
  end

  def handle("refresh_models", _params, socket) do
    {:noreply, ModelSelection.refresh(socket)}
  end

  def handle("select_file", %{"path" => path}, socket) do
    socket =
      ConversationState.select_file(
        socket,
        path,
        ConversationState.current_checkout_path(socket),
        ModelSelection.state_opts()
      )

    {:noreply, socket}
  end

  def handle("select_workspace_file", %{"path" => relative_path}, socket) do
    {:noreply,
     socket
     |> assign(:preview_line, nil)
     |> ConversationState.select_file(
       relative_path,
       ConversationState.current_checkout_path(socket),
       ModelSelection.state_opts()
     )}
  end

  def handle("toggle_workspace_directory", %{"path" => relative_path}, socket) do
    {:noreply, WorkspaceNavigation.toggle_directory(socket, relative_path)}
  end

  def handle("select_editor_file", %{"path" => relative_path}, socket)
      when is_binary(relative_path) do
    {:noreply,
     socket
     |> assign(:preview_line, nil)
     |> ConversationState.select_editor_file(
       relative_path,
       ConversationState.current_checkout_path(socket),
       ModelSelection.state_opts()
     )}
  end

  def handle("close_editor_file", %{"path" => relative_path}, socket)
      when is_binary(relative_path) do
    root = ConversationState.current_checkout_path(socket)

    {:noreply,
     ConversationState.close_file(socket, relative_path, root, ModelSelection.state_opts())}
  end

  def handle("reveal_in_file_manager", %{"path" => relative_path}, socket)
      when is_binary(relative_path) do
    with true <- FileManager.available?(),
         root when is_binary(root) <- socket.assigns.workspace_root,
         {:ok, path} <- WorkspaceFiles.resolve_entry(root, relative_path),
         :ok <- FileManager.reveal(path) do
      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle("select_right_panel_view", %{"view" => view}, socket)
      when view in ["changes", "files", "browser"] do
    {:noreply, WorkspaceNavigation.select_panel(socket, view)}
  end

  def handle("select_right_panel_view", %{"view" => "terminal"}, socket) do
    {:noreply, WorkspaceNavigation.show_terminal(socket)}
  end

  def handle("select_mobile_right_panel_view", %{"view" => "files"}, socket) do
    {:noreply, WorkspaceNavigation.show_files_mobile(socket)}
  end

  def handle("select_mobile_right_panel_view", %{"view" => "terminal"}, socket) do
    {:noreply, WorkspaceNavigation.show_terminal(socket, true)}
  end

  def handle("close_mobile_right_panel", _params, socket) do
    {:noreply, WorkspaceNavigation.close_mobile_panel(socket)}
  end

  def handle("open_file_change", %{"path" => path} = params, socket)
      when is_binary(path) do
    root = ConversationState.current_checkout_path(socket)
    requested = Path.expand(path, root)
    message_id = params["message_id"]

    entry =
      socket.assigns.timeline
      |> Enum.take_while(&(is_nil(message_id) or &1["id"] != message_id))
      |> Enum.reverse()
      |> Enum.find(fn entry ->
        file_path = HandbeanWeb.ChangeHelper.change_from_entry(entry)["file_path"]

        HandbeanWeb.FileChangeCard.change_entry?(entry) and is_binary(file_path) and
          Path.expand(file_path, root) == requested
      end)

    if entry do
      expanded = Map.get(socket.assigns, :expanded_file_changes, MapSet.new())
      socket = assign(socket, :expanded_file_changes, MapSet.put(expanded, entry["id"]))

      socket =
        if group_id = entry["work_group_id"] do
          groups = Map.get(socket.assigns, :expanded_tool_groups, MapSet.new())

          socket
          |> assign(:expanded_tool_groups, MapSet.put(groups, group_id))
          |> RuntimeProjection.refresh_tool_work(group_id)
        else
          socket
        end

      {:noreply,
       socket
       |> RuntimeProjection.refresh_file_change(entry["id"])
       |> push_event("scroll_to_file_change", %{id: "chat-file-change-#{entry["id"]}"})}
    else
      relative = Path.relative_to(requested, root)

      {:noreply,
       socket
       |> WorkspaceNavigation.reveal_files_panel()
       |> ConversationState.select_file(relative, root, ModelSelection.state_opts())
       |> assign(:preview_line, preview_line(params["line"]))}
    end
  end

  def handle("toggle_file_change", params, socket) do
    case params do
      %{"id" => id} when is_binary(id) ->
        expanded = Map.get(socket.assigns, :expanded_file_changes, MapSet.new())

        expanded =
          if MapSet.member?(expanded, id),
            do: MapSet.delete(expanded, id),
            else: MapSet.put(expanded, id)

        {:noreply,
         socket
         |> assign(:expanded_file_changes, expanded)
         |> assign(:right_panel_collapsed, false)
         |> RuntimeProjection.refresh_file_change(id)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle("confirm_revert_change", %{"change_id" => change_id}, socket) do
    {:noreply, RuntimeProjection.mark_revert_confirm(socket, change_id)}
  end

  def handle("cancel_revert_change", _params, socket) do
    {:noreply, RuntimeProjection.mark_revert_confirm(socket, nil)}
  end

  def handle("revert_change", %{"change_id" => change_id}, socket) do
    with %{} = change <- find_change(socket.assigns.timeline, change_id),
         {:not_running, false} <- {:not_running, running_for_current_conversation?(socket)} do
      result =
        Handbean.ChangeReverter.revert(change, ConversationState.current_checkout_path(socket))

      {:noreply,
       EditorProjection.apply_revert_result(
         socket,
         change,
         result,
         ConversationState.current_checkout_path(socket)
       )}
    else
      {:not_running, true} ->
        {:noreply,
         RuntimeProjection.mark_revert_confirm(
           assign(socket, :revert_message, %{
             "change_id" => change_id,
             "status" => "error",
             "message" => "Cannot revert while an agent run is active."
           }),
           nil
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle("open_preview", %{"id" => preview_id}, socket) do
    {:noreply, WorkspaceNavigation.open_preview_display(socket, preview_id, :overlay)}
  end

  def handle("open_preview_external", %{"id" => preview_id}, socket) do
    {:noreply, WorkspaceNavigation.open_preview_display(socket, preview_id, :external)}
  end

  def handle("takeover_browser", %{"session" => session_id}, socket) do
    try do
      case Handbean.Browser.WebViewSession.user_takeover(session_id) do
        :ok ->
          {:noreply, socket}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "browser takeover failed: #{inspect(reason)}")}
      end
    catch
      :exit, _ -> {:noreply, put_flash(socket, :error, "browser session is gone")}
    end
  end

  def handle("toggle_terminal", _params, socket) do
    {:noreply, WorkspaceNavigation.show_terminal(socket)}
  end

  defp running_for_current_conversation?(socket),
    do: ConversationState.running_for_current_conversation?(socket)

  defp find_change(timeline, change_id),
    do: HandbeanWeb.ChangeHelper.find_change(timeline, change_id)

  defp preview_line(line) when is_integer(line) and line > 0, do: line

  defp preview_line(line) when is_binary(line) do
    case Integer.parse(line) do
      {value, ""} when value > 0 -> value
      _ -> nil
    end
  end

  defp preview_line(_line), do: nil

  defp authoritative_widget_entry(conversation_id, entry_id)
       when is_binary(conversation_id) and is_binary(entry_id) do
    case Handbean.ConversationTranscriptStore.list(conversation_id) do
      {:ok, entries} -> Enum.find(entries, &(&1["id"] == entry_id))
      {:error, _reason} -> nil
    end
  end

  defp authoritative_widget_entry(_conversation_id, _entry_id), do: nil

  defp push_widget_command_result(socket, params, status, reason \\ nil) do
    result = %{
      request_id: widget_request_id(params),
      status: status
    }

    result = if reason, do: Map.put(result, :reason, Atom.to_string(reason)), else: result
    push_event(socket, "widget-command-result", result)
  end

  defp widget_request_id(%{"request_id" => request_id}) when is_binary(request_id),
    do: request_id

  defp widget_request_id(_params), do: ""

  defp speech_error_message("permission_denied"),
    do: gettext("Microphone access was denied. Allow it in system settings and try again.")

  defp speech_error_message("microphone_missing"),
    do: gettext("No microphone was found.")

  defp speech_error_message("microphone_busy"),
    do: gettext("The microphone is being used by another app.")

  defp speech_error_message("unsupported"),
    do: gettext("Voice recording is not supported by this browser.")

  defp speech_error_message("empty_recording"),
    do: gettext("No audio was recorded.")

  defp speech_error_message(_reason),
    do: gettext("Could not record audio. Please try again.")

  defp resume_tool_approval(socket, action, remember) when action in [:approve, :deny] do
    pending = socket.assigns.pending_approval

    if cli_approval?(pending) do
      MessageSubmission.resume_cli_approval(socket, pending, action)
    else
      resume_handbean_approval(socket, action, remember)
    end
  end

  defp cli_approval?(pending) when is_map(pending) do
    Handbean.Utils.SafeMap.get_any(pending, :kind, "kind") in [:cli_agent, "cli_agent"]
  end

  defp cli_approval?(_pending), do: false

  defp resume_handbean_approval(socket, action, remember) when action in [:approve, :deny] do
    conv_id = socket.assigns.current_conversation_id
    pending = socket.assigns.pending_approval

    if is_binary(conv_id) and not is_nil(pending) do
      workspace_root = ConversationState.current_workspace_path(socket)

      case Approval.resume(conv_id, pending, action, remember, workspace_root) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("[WorkspaceLive] #{action} tools resume failed: #{inspect(reason)}")
      end

      {:noreply, assign(socket, :pending_approval, nil)}
    else
      {:noreply, socket}
    end
  end
end
