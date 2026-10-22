defmodule HandbeanWeb.WorkspaceLive.MessageSubmission.CLI do
  @moduledoc false

  use Gettext, backend: Handbean.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias HandbeanWeb.WorkspaceLive.CliSelection
  alias HandbeanWeb.WorkspaceLive.Composer
  alias HandbeanWeb.WorkspaceLive.MessageSubmission.Delivery
  alias HandbeanWeb.WorkspaceLive.RuntimeProjection

  require Logger

  def send_cli_conversation_message(socket, conv_id, message) do
    opts = CliSelection.run_opts(socket, conv_id)

    attachments? =
      socket.assigns.pending_attachments != [] or Composer.has_upload_entries?(socket)

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
        case Delivery.prepare_outbound_message(socket, message) do
          {:ok, socket, content, attachments} ->
            start_cli_turn(socket, conv_id, content, message, attachments, opts)

          {:error, socket} ->
            {:noreply, socket}
        end
    end
  end

  def start_cli_turn(socket, conv_id, content, message, attachments, opts) do
    msg_id = RuntimeProjection.unique_id("msg-user")
    content = Composer.put_message_id(content, msg_id)

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
         |> Delivery.append_user_message(message, attachments, msg_id)
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
          |> Delivery.append_user_message(message, attachments, msg_id)
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
end
