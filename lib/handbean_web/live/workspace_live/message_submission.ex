defmodule HandbeanWeb.WorkspaceLive.MessageSubmission do
  @moduledoc false

  use Gettext, backend: Handbean.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, put_flash: 3, stream: 4]

  alias HandbeanWeb.WorkspaceLive.Composer
  alias HandbeanWeb.WorkspaceLive.ConversationState
  alias HandbeanWeb.WorkspaceLive.ConversationSwitching
  alias HandbeanWeb.WorkspaceLive.{CliSelection, ModelSelection}
  alias HandbeanWeb.WorkspaceLive.RuntimeProjection
  alias HandbeanWeb.WorkspaceLive.WorkspaceNavigation

  require Logger

  def send_schedule_request(socket, message) do
    message = String.trim(to_string(message || ""))
    draft_input = socket.assigns.input_value
    draft_attachments = socket.assigns.pending_attachments

    if message == "" do
      {:noreply, socket}
    else
      running? =
        ConversationState.running_for_current_conversation?(socket) or
          not is_nil(socket.assigns.pending_approval)

      socket = if running?, do: socket, else: ensure_current_conversation(socket)
      conv_id = socket.assigns.current_conversation_id

      {:noreply, socket} =
        if running? do
          queue_running_agent_message(socket, conv_id, message, message, [], :steer)
        else
          start_new_agent_run(socket, conv_id, message, message, [])
        end

      {:noreply,
       socket
       |> assign(:input_value, draft_input)
       |> assign(:pending_attachments, draft_attachments)}
    end
  end

  def send_message(socket, params) do
    message = String.trim(params["message"] || "")
    socket = ModelSelection.apply_submitted(socket, params)
    {socket, message} = ModelSelection.apply_command(socket, message)
    socket = assign(socket, :composer_error, nil)

    case maybe_send_workspace_command(
           socket,
           message,
           params["workspace_command_operation_id"]
         ) do
      {:handled, result} ->
        result

      :continue ->
        if dm = subagent_dm(socket, message) do
          send_subagent_dm(socket, dm)
        else
          send_conversation_message(socket, message)
        end
    end
  end

  def steer_message(socket, params) do
    message = String.trim(params["message"] || socket.assigns.input_value || "")

    socket =
      socket
      |> ModelSelection.apply_submitted(params)
      |> assign(:composer_error, nil)

    case maybe_send_workspace_command(
           socket,
           message,
           params["workspace_command_operation_id"]
         ) do
      {:handled, result} ->
        result

      :continue ->
        if message != "" or socket.assigns.pending_attachments != [] or
             has_upload_entries?(socket) do
          send_or_queue_current(socket, message, :steer)
        else
          {:noreply, socket}
        end
    end
  end

  def queue_message(socket, params) do
    message = String.trim(params["message"] || socket.assigns.input_value || "")

    socket =
      socket
      |> ModelSelection.apply_submitted(params)
      |> assign(:composer_error, nil)

    case maybe_send_workspace_command(
           socket,
           message,
           params["workspace_command_operation_id"]
         ) do
      {:handled, result} ->
        result

      :continue ->
        if message != "" or socket.assigns.pending_attachments != [] or
             has_upload_entries?(socket) do
          send_or_queue_current(socket, message, :follow_up)
        else
          {:noreply, socket}
        end
    end
  end

  def send_pending_now(socket, id) do
    item = Map.get(socket.assigns.pending_messages, id)
    conv_id = socket.assigns.current_conversation_id

    cond do
      is_nil(item) or item[:status] != :queued or item[:deliver_as] != :follow_up ->
        {:noreply, socket}

      cli_run_active?(conv_id) ->
        reject_cli_active(socket)

      true ->
        case Handbean.Agent.Coordinator.promote_pending_message(conv_id, id) do
          :ok ->
            pending =
              Handbean.Agent.PendingMessages.put_queued(
                socket.assigns.pending_messages,
                id,
                :steer
              )

            {:noreply,
             socket
             |> assign_pending_messages(pending)
             |> assign(:composer_error, nil)}

          {:error, :not_found} ->
            {:noreply,
             socket
             |> assign_pending_messages(
               Handbean.Agent.PendingMessages.drop(socket.assigns.pending_messages, id)
             )
             |> ConversationState.sync_conv_state(
               Keyword.merge(ModelSelection.state_opts(), reload?: true)
             )
             |> assign(:composer_error, gettext("Already inserted; cannot send now."))}

          {:error, _reason} ->
            {:noreply,
             assign(socket, :composer_error, gettext("Could not send that message now."))}
        end
    end
  end

  def cancel_pending(socket, id) do
    conv_id = socket.assigns.current_conversation_id
    item = Map.get(socket.assigns.pending_messages, id)

    case Handbean.Agent.Coordinator.delete_pending_message(conv_id, id) do
      :ok ->
        {:noreply,
         socket
         |> drop_pending_timeline(id)
         |> assign_pending_messages(
           Handbean.Agent.PendingMessages.drop(socket.assigns.pending_messages, id)
         )
         |> restore_pending_draft(item)
         |> ConversationState.sync_conv_state(
           Keyword.merge(ModelSelection.state_opts(), reload?: true)
         )
         |> assign(:composer_error, nil)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(
           :pending_messages,
           Handbean.Agent.PendingMessages.drop(socket.assigns.pending_messages, id)
         )
         |> ConversationState.sync_conv_state(
           Keyword.merge(ModelSelection.state_opts(), reload?: true)
         )
         |> assign(:composer_error, gettext("Already inserted; cannot undo."))}

      {:error, _reason} ->
        {:noreply, assign(socket, :composer_error, gettext("Could not undo that message."))}
    end
  end

  def resend_pending(socket, id) do
    item = Map.get(socket.assigns.pending_messages, id)

    cond do
      is_nil(item) or item[:status] != :undelivered -> {:noreply, socket}
      true -> resend_pending_item(socket, id, item)
    end
  end

  def delete_undelivered(socket, id) do
    item = Map.get(socket.assigns.pending_messages, id)

    if is_map(item) and item[:status] == :undelivered do
      case drop_transcript_entry(socket.assigns.current_conversation_id, id) do
        :ok ->
          {:noreply,
           socket
           |> drop_pending_timeline(id)
           |> assign_pending_messages(
             Handbean.Agent.PendingMessages.drop(socket.assigns.pending_messages, id)
           )
           |> ConversationState.sync_conv_state(
             Keyword.merge(ModelSelection.state_opts(), reload?: true)
           )
           |> assign(:composer_error, nil)}

        {:error, _reason} ->
          {:noreply, assign(socket, :composer_error, gettext("Could not delete that message."))}
      end
    else
      {:noreply, socket}
    end
  end

  def stop(socket) do
    conv_id = socket.assigns.current_conversation_id

    result =
      if is_binary(conv_id) do
        Handbean.Agent.Coordinator.cancel(conv_id)
      else
        {:error, :not_running}
      end

    case result do
      :ok ->
        {:noreply, RuntimeProjection.mark_cancelled(socket)}

      {:error, reason} ->
        Logger.warning("[WorkspaceLive] stop_run could not cancel run: #{inspect(reason)}")
        {:noreply, RuntimeProjection.mark_cancelled(socket)}
    end
  end

  defp persist_timeline(socket, entry, opts) do
    socket = RuntimeProjection.timeline_insert(socket, entry)

    if Keyword.get(opts, :persist?, true),
      do: ConversationState.sync_conv_to(socket),
      else: socket
  end

  defp tools_for(socket) do
    if ConversationState.free_chat?(socket),
      do: Handbean.Agent.free_chat_tools(),
      else: Handbean.Agent.default_tools()
  end

  defp maybe_send_workspace_command(socket, message, client_operation_id) do
    case Handbean.WorkspaceCommand.parse(message) do
      :not_command ->
        :continue

      {:error, reason} ->
        {:handled, {:noreply, assign(socket, :composer_error, workspace_command_error(reason))}}

      {:ok, command} ->
        {:handled, send_workspace_command(socket, command, client_operation_id)}
    end
  end

  defp send_workspace_command(socket, command, client_operation_id) do
    cond do
      socket.assigns.chat_scope == :free ->
        {:noreply,
         assign(
           socket,
           :composer_error,
           gettext("Direct commands are available only in workspace conversations.")
         )}

      socket.assigns.pending_attachments != [] or has_upload_entries?(socket) ->
        {:noreply,
         assign(
           socket,
           :composer_error,
           gettext("Remove attachments before running a direct command.")
         )}

      true ->
        socket = ensure_current_conversation(socket)
        conversation_id = socket.assigns.current_conversation_id

        {socket, operation_id} =
          Composer.workspace_command_operation(socket, command, client_operation_id)

        case Handbean.WorkspaceCommand.submit(conversation_id, command,
               source: :web,
               operation_id: operation_id
             ) do
          {:ok, %{entries: entries}} ->
            socket =
              Enum.reduce(entries, socket, fn entry, acc ->
                RuntimeProjection.timeline_insert(acc, entry)
              end)

            {:noreply,
             socket
             |> assign(:input_value, "")
             |> Composer.clear_workspace_command_intent()
             |> assign(:composer_error, nil)
             |> Composer.forget(conversation_id)
             |> push_event("user-message-sent", %{})}

          {:error, reason} ->
            {:noreply, assign(socket, :composer_error, workspace_command_error(reason))}
        end
    end
  end

  defp workspace_command_error(:empty_command),
    do: gettext("Enter a command after !.")

  defp workspace_command_error(:invalid_command),
    do: gettext("That direct command is invalid or too long.")

  defp workspace_command_error(:busy),
    do: gettext("A direct command is already running for this conversation.")

  defp workspace_command_error(reason)
       when reason in [:not_available, :not_workspace_conversation, :workspace_unavailable] do
    gettext("Direct commands are not available on this host or workspace.")
  end

  defp workspace_command_error(_reason),
    do: gettext("The direct command could not be started.")

  def send_conversation_message(socket, message) do
    if message != "" or socket.assigns.pending_attachments != [] or has_upload_entries?(socket) do
      running_for_current? =
        ConversationState.running_for_current_conversation?(socket) or
          not is_nil(socket.assigns.pending_approval)

      socket = if running_for_current?, do: socket, else: ensure_current_conversation(socket)
      conv_id = socket.assigns.current_conversation_id

      cond do
        CliSelection.cli_selected?(socket.assigns) ->
          send_cli_conversation_message(socket, conv_id, message)

        cli_run_active?(conv_id) ->
          reject_cli_active(socket)

        true ->
          case prepare_outbound_message(socket, message) do
            {:ok, socket, content, attachments} ->
              if running_for_current? do
                queue_running_agent_message(
                  socket,
                  conv_id,
                  content,
                  message,
                  attachments,
                  :steer
                )
              else
                start_new_agent_run(socket, conv_id, content, message, attachments)
              end

            {:error, socket} ->
              {:noreply, socket}
          end
      end
    else
      {:noreply, socket}
    end
  end

  def subagent_dm(socket, message) do
    with conv_id when is_binary(conv_id) <- socket.assigns.current_conversation_id,
         [] <- socket.assigns.pending_attachments,
         false <- has_upload_entries?(socket),
         [_, ref, text] <- Regex.run(~r/\A@([\w.-]+)\s+(\S.*)\z/s, message),
         {:ok, children} <- Handbean.Agent.Delegation.status(conv_id, :list),
         true <- Enum.any?(children, &(ref in [&1.child_conversation_id, &1.subagent_type])) do
      %{conversation_id: conv_id, ref: ref, text: text}
    else
      _ -> nil
    end
  end

  def send_subagent_dm(socket, %{conversation_id: conv_id, ref: ref, text: text}) do
    case Handbean.Agent.Delegation.message(conv_id, ref, text, source: :web) do
      {:ok, %{delivery: delivery}} ->
        note =
          if delivery == :steer,
            do: gettext("Sent to subagent %{ref}.", ref: ref),
            else: gettext("Subagent %{ref} is answering a follow-up.", ref: ref)

        {:noreply,
         socket
         |> assign(:input_value, "")
         |> put_flash(:info, note)
         |> push_event("user-message-sent", %{})}

      {:error, reason} ->
        reason = if is_binary(reason), do: reason, else: inspect(reason)
        {:noreply, assign(socket, :composer_error, reason)}
    end
  end

  def send_or_queue_current(socket, message, deliver_as) do
    running_for_current? =
      ConversationState.running_for_current_conversation?(socket) or
        not is_nil(socket.assigns.pending_approval)

    socket = if running_for_current?, do: socket, else: ensure_current_conversation(socket)

    conv_id = socket.assigns.current_conversation_id

    if cli_run_active?(conv_id) do
      reject_cli_active(socket)
    else
      case prepare_outbound_message(socket, message) do
        {:ok, socket, content, attachments} ->
          if running_for_current? do
            queue_running_agent_message(
              socket,
              conv_id,
              content,
              message,
              attachments,
              deliver_as
            )
          else
            start_new_agent_run(socket, conv_id, content, message, attachments)
          end

        {:error, socket} ->
          {:noreply, socket}
      end
    end
  end

  def restore_pending_draft(socket, item) when is_map(item) do
    Composer.restore_draft(socket, item)
  end

  def restore_pending_draft(socket, _), do: socket

  def resend_pending_item(socket, id, item) do
    content_text = if is_binary(item[:content]), do: item[:content], else: ""
    attachments = List.wrap(item[:attachments])
    conv_id = socket.assigns.current_conversation_id

    if String.trim(content_text) == "" and attachments == [] do
      {:noreply, socket}
    else
      socket =
        assign_pending_messages(
          socket,
          Handbean.Agent.PendingMessages.put_status(
            socket.assigns.pending_messages,
            id,
            :resending
          )
        )

      checkout_path = ConversationState.current_checkout_path(socket)

      case Handbean.Attachments.MessageBuilder.build(
             content_text,
             attachments,
             Composer.build_opts(socket, checkout_path)
           ) do
        {:ok, content, persistable} ->
          msg_id = RuntimeProjection.unique_id("msg-user")
          content = put_inbound_message_id(content, msg_id)
          deliver_as = item[:deliver_as] || :steer

          case add_message_to_current_conversation(socket, conv_id, content,
                 deliver_as: deliver_as,
                 message_id: msg_id,
                 attachments: persistable
               ) do
            {:ok, ack} ->
              finish_resend_pending(
                socket,
                id,
                msg_id,
                content_text,
                persistable,
                ack,
                deliver_as
              )

            {:error, reason} ->
              {:noreply,
               socket
               |> assign_pending_messages(
                 Handbean.Agent.PendingMessages.put_status(
                   socket.assigns.pending_messages,
                   id,
                   :undelivered
                 )
               )
               |> assign(:composer_error, resend_error(reason))}
          end

        {:error, reason} ->
          {:noreply,
           socket
           |> assign_pending_messages(
             Handbean.Agent.PendingMessages.put_status(
               socket.assigns.pending_messages,
               id,
               :undelivered
             )
           )
           |> assign(:composer_error, outbound_error(reason))}
      end
    end
  end

  def finish_resend_pending(socket, old_id, msg_id, content_text, attachments, ack, deliver_as) do
    conv_id = socket.assigns.current_conversation_id
    draft = socket.assigns.input_value
    composer_atts = socket.assigns.pending_attachments

    delete_ok? =
      case drop_transcript_entry(conv_id, old_id) do
        :ok -> true
        {:ok, _} -> true
        _ -> false
      end

    pending =
      socket.assigns.pending_messages
      |> Handbean.Agent.PendingMessages.drop(old_id)

    pending =
      if ack[:action] == :enqueued do
        Handbean.Agent.PendingMessages.put_queued(pending, msg_id, deliver_as, %{
          content: content_text,
          attachments: attachments
        })
      else
        pending
      end

    socket =
      socket
      |> assign_pending_messages(pending)
      |> ConversationState.sync_conv_state(reload?: true)
      |> assign(:input_value, draft)
      |> assign(:pending_attachments, composer_atts)
      |> assign(
        :composer_error,
        if(delete_ok?,
          do: nil,
          else: gettext("Resent, but the previous copy could not be removed from history.")
        )
      )

    socket =
      if ack[:action] == :started do
        socket
        |> assign(:running, true)
        |> assign(:running_conversation_id, conv_id)
      else
        socket
      end

    {:noreply, socket}
  end

  def assign_pending_messages(socket, pending) do
    Composer.assign_pending(socket, pending)
  end

  defp drop_pending_timeline(socket, id) do
    assign(
      socket,
      :timeline,
      Handbean.Agent.PendingMessages.drop_entry(socket.assigns.timeline || [], id)
    )
  end

  def drop_transcript_entry(conversation_id, id),
    do: Composer.drop_transcript_entry(conversation_id, id)

  def put_inbound_message_id(content, id), do: Composer.put_message_id(content, id)

  def queue_running_agent_message(socket, conv_id, content, message, attachments, deliver_as) do
    if cli_run_active?(conv_id) do
      reject_cli_active(socket)
    else
      do_queue_running_agent_message(socket, conv_id, content, message, attachments, deliver_as)
    end
  end

  defp do_queue_running_agent_message(socket, conv_id, content, message, attachments, deliver_as) do
    msg_id = RuntimeProjection.unique_id("msg-user")
    content = put_inbound_message_id(content, msg_id)

    case add_message_to_current_conversation(socket, conv_id, content,
           deliver_as: deliver_as,
           message_id: msg_id,
           attachments: attachments
         ) do
      {:ok, %{action: :enqueued}} ->
        pending =
          Handbean.Agent.PendingMessages.put_queued(
            socket.assigns.pending_messages,
            msg_id,
            deliver_as,
            %{content: message, attachments: attachments}
          )

        socket =
          socket
          |> assign(:input_value, "")
          |> assign(:pending_attachments, [])
          |> Composer.forget(conv_id)
          |> assign(:pending_messages, pending)
          |> append_user_message(message, attachments, msg_id)
          |> push_event("user-message-sent", %{})

        {:noreply, socket}

      {:ok, %{action: :started}} ->
        {:noreply,
         socket
         |> assign(:input_value, "")
         |> append_user_message(message, attachments, msg_id)
         |> assign(:pending_attachments, [])
         |> Composer.forget(conv_id)
         |> assign(:running, true)
         |> assign(:running_conversation_id, conv_id)
         |> push_event("user-message-sent", %{})}

      {:error, :queue_full} ->
        Logger.warning("[WorkspaceLive] Failed to enqueue candidate: :queue_full")
        {:noreply, mark_stale_running_message_rejected(socket)}

      {:error, :sealed} ->
        Logger.warning("[WorkspaceLive] Failed to enqueue candidate: :sealed")
        {:noreply, mark_stale_running_message_rejected(socket)}

      {:error, reason} ->
        Logger.warning("[WorkspaceLive] Failed to enqueue candidate: #{inspect(reason)}")
        {:noreply, mark_stale_running_message_rejected(socket)}
    end
  end

  def add_message_to_current_conversation(socket, conv_id, content, opts) do
    checkout_path = ConversationState.current_checkout_path(socket)

    if ConversationState.free_chat?(socket) or is_binary(checkout_path) do
      {selected_model, selected_reasoning_level} =
        ModelSelection.effective_model_and_reasoning(socket)

      workspace_path = ConversationState.current_workspace_path(socket)

      with {:ok, built} <-
             Handbean.Agent.RunOpts.for_selection(
               workspace_path,
               selected_model,
               selected_reasoning_level,
               socket.assigns.effective_settings
             ) do
        msg_id = Keyword.get(opts, :message_id)

        Handbean.Agent.Coordinator.add_message(
          conv_id,
          content,
          run_opts(
            socket,
            Keyword.merge(built,
              deliver_as: Keyword.get(opts, :deliver_as, :steer),
              transcript_id: msg_id,
              message_id: msg_id,
              inbound_id: msg_id,
              attachments: Keyword.get(opts, :attachments, [])
            )
          )
        )
      end
    else
      {:error, :checkout_unavailable}
    end
  end

  def run_opts(socket, extra) do
    base =
      if ConversationState.free_chat?(socket) do
        [
          chat_scope: :free,
          tools: tools_for(socket),
          workspace_id: nil,
          workspace_path: nil,
          mcp: false,
          source: :live_view,
          streaming: true
        ]
      else
        [
          chat_scope: :workspace,
          tools: tools_for(socket),
          workspace_id: socket.assigns.current_workspace_id,
          workspace_path: ConversationState.current_workspace_path(socket),
          working_directory: ConversationState.current_checkout_path(socket),
          source: :live_view,
          streaming: true
        ]
      end

    Keyword.merge(base, extra)
    |> Keyword.put_new(:user_time_zone, socket.assigns[:user_time_zone])
  end

  def mark_stale_running_message_rejected(socket) do
    socket
    |> assign(:running, false)
    |> assign(:running_conversation_id, nil)
    |> assign(:stream_suppressed, false)
    |> assign(:tools_active, %{})
    |> ConversationState.sync_conv_state(reload?: true)
    |> RuntimeProjection.restore_active_session()
    |> WorkspaceNavigation.finish_runtime()
    |> assign(
      :composer_error,
      "The previous run is no longer accepting input. Send again to start a new run in this conversation."
    )
  end

  def send_cli_conversation_message(socket, conv_id, message) do
    opts = CliSelection.run_opts(socket, conv_id)
    attachments? = socket.assigns.pending_attachments != [] or has_upload_entries?(socket)

    cond do
      is_nil(opts) ->
        {:noreply, assign(socket, :composer_error, gettext("Select a CLI model before sending."))}

      socket.assigns[:cli_models_error] ->
        {:noreply,
         assign(socket, :composer_error, cli_models_error(socket.assigns.cli_models_error))}

      attachments? and
          not Handbean.Agent.CliAgent.Registry.attachments?(socket.assigns.selected_cli) ->
        {:noreply,
         assign(
           socket,
           :composer_error,
           gettext("This CLI does not support attachments. Remove them or choose Handbean.")
         )}

      true ->
        case prepare_outbound_message(socket, message) do
          {:ok, socket, content, attachments} ->
            start_cli_turn(socket, conv_id, content, message, attachments, opts)

          {:error, socket} ->
            {:noreply, socket}
        end
    end
  end

  def start_cli_turn(socket, conv_id, content, message, attachments, opts) do
    msg_id = RuntimeProjection.unique_id("msg-user")
    content = put_inbound_message_id(content, msg_id)

    opts =
      Keyword.merge(opts,
        transcript_id: msg_id,
        message_id: msg_id,
        inbound_id: msg_id,
        attachments: attachments,
        source: :live_view
      )

    case Handbean.Agent.Coordinator.start_cli_run(conv_id, content, message, opts) do
      {:ok, %{action: :enqueued}} ->
        pending =
          Handbean.Agent.PendingMessages.put_queued(
            socket.assigns.pending_messages,
            msg_id,
            :follow_up,
            %{content: message, attachments: attachments}
          )

        {:noreply,
         socket
         |> assign(:input_value, "")
         |> assign(:pending_attachments, [])
         |> Composer.forget(conv_id)
         |> assign(:pending_messages, pending)
         |> append_user_message(message, attachments, msg_id)
         |> push_event("user-message-sent", %{})}

      {:ok, %{action: :started}} ->
        socket =
          socket
          |> assign(:input_value, "")
          |> assign(:running, true)
          |> assign(:running_conversation_id, conv_id)
          |> assign(:stream_suppressed, false)
          |> assign(:pending_attachments, [])
          |> Composer.forget(conv_id)
          |> append_user_message(message, attachments, msg_id)
          |> RuntimeProjection.update_status(%{status: :running, status_detail: nil, turns: 0})
          |> RuntimeProjection.subscribe_session()
          |> push_event("user-message-sent", %{})

        send(self(), {:schedule_auto_title, conv_id, message})
        {:noreply, socket}

      {:error, reason} ->
        Logger.warning("[WorkspaceLive] CLI turn was not admitted: #{inspect(reason)}")
        {:noreply, assign(socket, :composer_error, cli_turn_error(reason))}
    end
  end

  def resume_cli_approval(socket, pending, {:approve, option}) when is_binary(option) do
    resume_with_decision(socket, pending, {:permission, option})
  end

  def resume_cli_approval(socket, pending, action) when action in [:approve, :deny] do
    resume_with_decision(socket, pending, cli_decision(pending, action))
  end

  defp resume_with_decision(socket, pending, decision) do
    conversation_id = Handbean.Utils.SafeMap.get_any(pending, :conversation_id, "conversation_id")

    if offered_decision?(pending, decision) do
      resume_opts = [
        expected_run_id: Handbean.Utils.SafeMap.get_any(pending, :run_id, "run_id"),
        approval_batch_id:
          Handbean.Utils.SafeMap.get_any(pending, :approval_batch_id, "approval_batch_id")
      ]

      case Handbean.Agent.Coordinator.resume(conversation_id, decision, resume_opts) do
        :ok ->
          {:noreply,
           socket
           |> assign(:pending_approval, nil)
           |> assign(:running, true)
           |> RuntimeProjection.update_status(%{status: :running, status_detail: nil})}

        {:error, reason} ->
          {:noreply, assign(socket, :composer_error, cli_turn_error(reason))}
      end
    else
      _ = Handbean.Agent.Coordinator.cancel(conversation_id)

      {:noreply,
       socket
       |> assign(:pending_approval, nil)
       |> assign(:running, false)
       |> assign(:running_conversation_id, nil)
       |> assign(:composer_error, gettext("CLI turn stopped."))}
    end
  end

  defp offered_decision?(_pending, nil), do: false

  defp offered_decision?(pending, {:permission, value}) do
    options = Handbean.Utils.SafeMap.get_any(pending, :options, "options") || []
    Enum.any?(options, &(&1["value"] == value and value != "cancel"))
  end

  defp offered_decision?(_pending, {:ask_user, answers}) when is_list(answers), do: true
  defp offered_decision?(_pending, _), do: false

  defp cli_decision(pending, :approve) do
    case Handbean.Utils.SafeMap.get_any(pending, :request_kind, "request_kind") do
      kind when kind in [:permission, "permission"] ->
        pending
        |> Handbean.Utils.SafeMap.get_any(:options, "options")
        |> List.wrap()
        |> Enum.find(&(&1["value"] not in [nil, "cancel"]))
        |> case do
          %{"value" => value} -> {:permission, value}
          _ -> nil
        end

      kind when kind in [:ask_user, "ask_user"] ->
        cli_ask_user_decision(pending)

      _ ->
        nil
    end
  end

  defp cli_decision(_pending, :deny), do: nil

  defp cli_ask_user_decision(pending) do
    requests = Handbean.Utils.SafeMap.get_any(pending, :action_requests, "action_requests") || []

    questions =
      case requests do
        [request | _] ->
          request
          |> Handbean.Utils.SafeMap.get_any([:arguments, "arguments"])
          |> then(&Handbean.Utils.SafeMap.get_any(&1 || %{}, [:questions, "questions"])) || []

        [] ->
          []
      end

    answers =
      Enum.map(questions, fn question ->
        %{
          "index" => Handbean.Utils.SafeMap.get_any(question, "index", :index),
          "question" => Handbean.Utils.SafeMap.get_any(question, "question", :question),
          "answer" =>
            List.first(Handbean.Utils.SafeMap.get_any(question, "options", :options) || []) || ""
        }
      end)

    if answers == [], do: nil, else: {:ask_user, answers}
  end

  defp cli_models_error(:models_unavailable),
    do: gettext("This CLI cannot list models.")

  defp cli_models_error(:empty), do: gettext("This CLI has no selectable models.")
  defp cli_models_error(_), do: gettext("This CLI cannot list models.")

  defp cli_turn_error(:not_available), do: gettext("CLI is not available on this host.")

  defp cli_turn_error(:attachments_not_supported),
    do: gettext("This CLI does not support attachments. Remove them or choose Handbean.")

  defp cli_turn_error(:run_in_progress),
    do: gettext("A run is already active in this conversation.")

  defp cli_turn_error(reason) when is_binary(reason), do: reason
  defp cli_turn_error(reason), do: gettext("CLI turn failed: %{reason}", reason: inspect(reason))

  def start_new_agent_run(socket, conv_id, content, message, attachments) do
    cond do
      not ConversationState.free_chat?(socket) and
          is_nil(ConversationState.current_checkout_path(socket)) ->
        {:noreply,
         assign(
           socket,
           :composer_error,
           gettext("This conversation checkout is unavailable. Restore it before running tools.")
         )}

      cli_run_active?(conv_id) ->
        {:noreply,
         assign(
           socket,
           :composer_error,
           gettext("Stop the active CLI run before sending with Handbean.")
         )}

      true ->
        do_start_new_agent_run(socket, conv_id, content, message, attachments)
    end
  end

  defp do_start_new_agent_run(socket, conv_id, content, message, attachments) do
    {selected_model, selected_reasoning_level} =
      ModelSelection.effective_model_and_reasoning(socket)

    workspace_path = ConversationState.current_workspace_path(socket)

    case Handbean.Agent.RunOpts.for_selection(
           workspace_path,
           selected_model,
           selected_reasoning_level,
           socket.assigns.effective_settings
         ) do
      {:ok, built} ->
        msg_id = RuntimeProjection.unique_id("msg-user")
        content = put_inbound_message_id(content, msg_id)

        run_opts =
          run_opts(
            socket,
            Keyword.merge(built,
              workspace_path: workspace_path,
              transcript_id: msg_id,
              message_id: msg_id,
              inbound_id: msg_id,
              attachments: attachments
            )
          )

        case Handbean.Agent.Coordinator.add_message(conv_id, content, run_opts) do
          {:ok, _ack} ->
            socket = accept_new_agent_run(socket, conv_id, message, attachments, msg_id)
            send(self(), {:schedule_auto_title, conv_id, message})
            {:noreply, socket}

          {:error, reason} ->
            Logger.warning("[WorkspaceLive] Failed to start agent run: #{inspect(reason)}")

            {:noreply,
             assign(socket, :composer_error, "Message not delivered: #{inspect(reason)}")}
        end

      {:error, reason} ->
        {:noreply, assign(socket, :composer_error, reason)}
    end
  end

  defp reject_cli_active(socket) do
    {:noreply,
     assign(
       socket,
       :composer_error,
       gettext("Stop the active CLI run before sending with Handbean.")
     )}
  end

  defp cli_run_active?(conv_id) do
    case Handbean.Agent.Coordinator.status(conv_id) do
      {:ok, %{running?: true, loop_owner: :cli_agent}} -> true
      _ -> false
    end
  end

  defp accept_new_agent_run(socket, conv_id, message, attachments, msg_id) do
    socket
    |> assign(:input_value, "")
    |> assign(:running, true)
    |> assign(:running_conversation_id, conv_id)
    |> assign(:stream_suppressed, false)
    |> assign(:tools_active, %{})
    |> assign(:timeline, socket.assigns.timeline)
    |> stream(:timeline, socket.assigns.timeline, reset: true)
    |> assign(:thinking_content, "")
    |> assign(:think_buffer, "")
    |> assign(:current_assistant_entry_id, nil)
    |> append_user_message(message, attachments, msg_id)
    |> assign(:pending_attachments, [])
    |> Composer.forget(conv_id)
    |> RuntimeProjection.update_status(%{
      status: :running,
      input_tokens: 0,
      total_input_tokens: 0,
      output_tokens: 0,
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      turns: 0
    })
    |> RuntimeProjection.subscribe_session()
    |> push_event("user-message-sent", %{})
  end

  def ensure_current_conversation(socket) do
    socket
    |> ConversationSwitching.ensure_current_conversation(ModelSelection.state_opts())
    |> RuntimeProjection.subscribe_session()
  end

  def append_user_message(socket, message, attachments, id) do
    entry = %{
      "id" => id || RuntimeProjection.unique_id("msg-user"),
      "content_type" => "user_msg",
      "role" => "user",
      "content" => message,
      "attachments" => attachments
    }

    persist_timeline(socket, entry, persist?: false)
  end

  def prepare_outbound_message(socket, message) do
    Composer.prepare(socket, message, ConversationState.current_checkout_path(socket))
  end

  def has_upload_entries?(socket), do: Composer.has_upload_entries?(socket)
  def outbound_error(reason), do: Composer.outbound_error(reason)
  def resend_error(reason), do: Composer.resend_error(reason)
end
