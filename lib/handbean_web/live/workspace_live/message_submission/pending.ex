defmodule HandbeanWeb.WorkspaceLive.MessageSubmission.Pending do
  @moduledoc false

  use Gettext, backend: Handbean.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias HandbeanWeb.WorkspaceLive.Composer
  alias HandbeanWeb.WorkspaceLive.ConversationState
  alias HandbeanWeb.WorkspaceLive.MessageSubmission.Delivery
  alias HandbeanWeb.WorkspaceLive.ModelSelection
  alias HandbeanWeb.WorkspaceLive.RuntimeProjection

  def send_pending_now(socket, id) do
    item = Map.get(socket.assigns.pending_messages, id)
    conv_id = socket.assigns.current_conversation_id

    cond do
      is_nil(item) or item[:status] != :queued or item[:deliver_as] != :follow_up ->
        {:noreply, socket}

      Delivery.cli_run_active?(conv_id) ->
        Delivery.reject_cli_active(socket)

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
             |> Composer.assign_pending(pending)
             |> assign(:composer_error, nil)}

          {:error, :not_found} ->
            {:noreply,
             socket
             |> Composer.assign_pending(
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
         |> Composer.assign_pending(
           Handbean.Agent.PendingMessages.drop(socket.assigns.pending_messages, id)
         )
         |> Composer.restore_draft(item)
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
      case Composer.drop_transcript_entry(socket.assigns.current_conversation_id, id) do
        :ok ->
          {:noreply,
           socket
           |> drop_pending_timeline(id)
           |> Composer.assign_pending(
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

  def resend_pending_item(socket, id, item) do
    content_text = if is_binary(item[:content]), do: item[:content], else: ""
    attachments = List.wrap(item[:attachments])
    conv_id = socket.assigns.current_conversation_id

    if String.trim(content_text) == "" and attachments == [] do
      {:noreply, socket}
    else
      socket =
        Composer.assign_pending(
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
          content = Composer.put_message_id(content, msg_id)
          deliver_as = item[:deliver_as] || :steer

          case Delivery.add_message_to_current_conversation(socket, conv_id, content,
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
               |> Composer.assign_pending(
                 Handbean.Agent.PendingMessages.put_status(
                   socket.assigns.pending_messages,
                   id,
                   :undelivered
                 )
               )
               |> assign(:composer_error, Composer.resend_error(reason))}
          end

        {:error, reason} ->
          {:noreply,
           socket
           |> Composer.assign_pending(
             Handbean.Agent.PendingMessages.put_status(
               socket.assigns.pending_messages,
               id,
               :undelivered
             )
           )
           |> assign(:composer_error, Composer.outbound_error(reason))}
      end
    end
  end

  def finish_resend_pending(socket, old_id, msg_id, content_text, attachments, ack, deliver_as) do
    conv_id = socket.assigns.current_conversation_id
    draft = socket.assigns.input_value
    composer_atts = socket.assigns.pending_attachments

    delete_ok? =
      case Composer.drop_transcript_entry(conv_id, old_id) do
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
      |> Composer.assign_pending(pending)
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

  defp drop_pending_timeline(socket, id) do
    assign(
      socket,
      :timeline,
      Handbean.Agent.PendingMessages.drop_entry(socket.assigns.timeline || [], id)
    )
  end
end
