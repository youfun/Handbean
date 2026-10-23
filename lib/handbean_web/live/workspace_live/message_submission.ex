defmodule HandbeanWeb.WorkspaceLive.MessageSubmission do
  @moduledoc false

  use Gettext, backend: Handbean.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, put_flash: 3]

  alias HandbeanWeb.WorkspaceLive.CliSelection
  alias HandbeanWeb.WorkspaceLive.Composer
  alias HandbeanWeb.WorkspaceLive.ConversationState
  alias HandbeanWeb.WorkspaceLive.MessageSubmission.{CLI, Delivery, DirectCommand, Pending}
  alias HandbeanWeb.WorkspaceLive.ModelSelection
  alias HandbeanWeb.WorkspaceLive.RuntimeProjection

  require Logger

  defdelegate send_pending_now(socket, id), to: Pending
  defdelegate cancel_pending(socket, id), to: Pending
  defdelegate resend_pending(socket, id), to: Pending
  defdelegate delete_undelivered(socket, id), to: Pending
  defdelegate resend_pending_item(socket, id, item), to: Pending

  defdelegate finish_resend_pending(
                socket,
                old_id,
                msg_id,
                content_text,
                attachments,
                ack,
                deliver_as
              ),
              to: Pending

  defdelegate send_cli_conversation_message(socket, conv_id, message), to: CLI
  defdelegate start_cli_turn(socket, conv_id, content, message, attachments, opts), to: CLI
  defdelegate resume_cli_approval(socket, pending, action), to: CLI

  defdelegate queue_running_agent_message(
                socket,
                conv_id,
                content,
                message,
                attachments,
                deliver_as
              ),
              to: Delivery

  defdelegate add_message_to_current_conversation(socket, conv_id, content, opts), to: Delivery
  defdelegate run_opts(socket, extra), to: Delivery
  defdelegate mark_stale_running_message_rejected(socket), to: Delivery
  defdelegate start_new_agent_run(socket, conv_id, content, message, attachments), to: Delivery
  defdelegate ensure_current_conversation(socket), to: Delivery
  defdelegate append_user_message(socket, message, attachments, id), to: Delivery
  defdelegate prepare_outbound_message(socket, message), to: Delivery

  defdelegate restore_pending_draft(socket, item), to: Composer, as: :restore_draft
  defdelegate assign_pending_messages(socket, pending), to: Composer, as: :assign_pending
  defdelegate drop_transcript_entry(conversation_id, id), to: Composer
  defdelegate put_inbound_message_id(content, id), to: Composer, as: :put_message_id
  defdelegate has_upload_entries?(socket), to: Composer
  defdelegate outbound_error(reason), to: Composer
  defdelegate resend_error(reason), to: Composer

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

      socket = if running?, do: socket, else: Delivery.ensure_current_conversation(socket)
      conv_id = socket.assigns.current_conversation_id

      {:noreply, socket} =
        if running? do
          Delivery.queue_running_agent_message(socket, conv_id, message, message, [], :steer)
        else
          Delivery.start_new_agent_run(socket, conv_id, message, message, [])
        end

      {:noreply,
       socket
       |> assign(:input_value, draft_input)
       |> assign(:pending_attachments, draft_attachments)}
    end
  end

  def send_message(socket, params) do
    message = String.trim(params["message"] || "")

    case prepare_or_send_direct_command(socket, params, message) do
      {:handled, result} ->
        result

      {:error, socket} ->
        {:noreply, socket}

      {:ok, socket, message} ->
        if dm = subagent_dm(socket, message) do
          send_subagent_dm(socket, dm)
        else
          send_conversation_message(socket, message)
        end
    end
  end

  def steer_message(socket, params) do
    message = String.trim(params["message"] || socket.assigns.input_value || "")

    case prepare_or_send_direct_command(socket, params, message) do
      {:handled, result} ->
        result

      {:error, socket} ->
        {:noreply, socket}

      {:ok, socket, message} ->
        if message != "" or socket.assigns.pending_attachments != [] or
             Composer.has_upload_entries?(socket) do
          send_or_queue_current(socket, message, :steer)
        else
          {:noreply, socket}
        end
    end
  end

  def queue_message(socket, params) do
    message = String.trim(params["message"] || socket.assigns.input_value || "")

    case prepare_or_send_direct_command(socket, params, message) do
      {:handled, result} ->
        result

      {:error, socket} ->
        {:noreply, socket}

      {:ok, socket, message} ->
        if message != "" or socket.assigns.pending_attachments != [] or
             Composer.has_upload_entries?(socket) do
          send_or_queue_current(socket, message, :follow_up)
        else
          {:noreply, socket}
        end
    end
  end

  defp prepare_or_send_direct_command(socket, params, message) do
    case DirectCommand.maybe_send(
           socket,
           message,
           params["workspace_command_operation_id"]
         ) do
      {:handled, result} ->
        {:handled, result}

      :continue ->
        case prepare_model_submission(socket, params, message) do
          {:ok, socket, message} -> {:ok, assign(socket, :composer_error, nil), message}
          {:error, socket} -> {:error, socket}
        end
    end
  end

  defp prepare_model_submission(socket, params, message) do
    if CliSelection.cli_selected?(socket.assigns),
      do: {:ok, socket, message},
      else: ModelSelection.prepare_submission(socket, params, message)
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

  def send_conversation_message(socket, message) do
    if message != "" or socket.assigns.pending_attachments != [] or
         Composer.has_upload_entries?(socket) do
      running_for_current? =
        ConversationState.running_for_current_conversation?(socket) or
          not is_nil(socket.assigns.pending_approval)

      socket =
        if running_for_current?, do: socket, else: Delivery.ensure_current_conversation(socket)

      conv_id = socket.assigns.current_conversation_id

      cond do
        CliSelection.cli_selected?(socket.assigns) ->
          CLI.send_cli_conversation_message(socket, conv_id, message)

        Delivery.cli_run_active?(conv_id) ->
          Delivery.reject_cli_active(socket)

        true ->
          case Delivery.prepare_outbound_message(socket, message) do
            {:ok, socket, content, attachments} ->
              if running_for_current? do
                Delivery.queue_running_agent_message(
                  socket,
                  conv_id,
                  content,
                  message,
                  attachments,
                  :steer
                )
              else
                Delivery.start_new_agent_run(socket, conv_id, content, message, attachments)
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
         false <- Composer.has_upload_entries?(socket),
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

    socket =
      if running_for_current?, do: socket, else: Delivery.ensure_current_conversation(socket)

    conv_id = socket.assigns.current_conversation_id

    if Delivery.cli_run_active?(conv_id) do
      Delivery.reject_cli_active(socket)
    else
      case Delivery.prepare_outbound_message(socket, message) do
        {:ok, socket, content, attachments} ->
          if running_for_current? do
            Delivery.queue_running_agent_message(
              socket,
              conv_id,
              content,
              message,
              attachments,
              deliver_as
            )
          else
            Delivery.start_new_agent_run(socket, conv_id, content, message, attachments)
          end

        {:error, socket} ->
          {:noreply, socket}
      end
    end
  end
end
