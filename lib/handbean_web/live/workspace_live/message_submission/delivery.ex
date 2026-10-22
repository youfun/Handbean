defmodule HandbeanWeb.WorkspaceLive.MessageSubmission.Delivery do
  @moduledoc false

  use Gettext, backend: Handbean.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, stream: 4]

  alias HandbeanWeb.WorkspaceLive.Composer
  alias HandbeanWeb.WorkspaceLive.ConversationState
  alias HandbeanWeb.WorkspaceLive.ConversationSwitching
  alias HandbeanWeb.WorkspaceLive.ModelSelection
  alias HandbeanWeb.WorkspaceLive.RuntimeProjection
  alias HandbeanWeb.WorkspaceLive.WorkspaceNavigation

  require Logger

  def queue_running_agent_message(socket, conv_id, content, message, attachments, deliver_as) do
    if cli_run_active?(conv_id) do
      reject_cli_active(socket)
    else
      do_queue_running_agent_message(socket, conv_id, content, message, attachments, deliver_as)
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

  def reject_cli_active(socket) do
    {:noreply,
     assign(
       socket,
       :composer_error,
       gettext("Stop the active CLI run before sending with Handbean.")
     )}
  end

  def cli_run_active?(conv_id) do
    case Handbean.Agent.Coordinator.status(conv_id) do
      {:ok, %{running?: true, loop_owner: :cli_agent}} -> true
      _ -> false
    end
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

    RuntimeProjection.timeline_insert(socket, entry)
  end

  def prepare_outbound_message(socket, message) do
    Composer.prepare(socket, message, ConversationState.current_checkout_path(socket))
  end

  defp tools_for(socket) do
    if ConversationState.free_chat?(socket),
      do: Handbean.Agent.free_chat_tools(),
      else: Handbean.Agent.default_tools()
  end

  defp do_queue_running_agent_message(socket, conv_id, content, message, attachments, deliver_as) do
    msg_id = RuntimeProjection.unique_id("msg-user")
    content = Composer.put_message_id(content, msg_id)

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
        content = Composer.put_message_id(content, msg_id)

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
end
