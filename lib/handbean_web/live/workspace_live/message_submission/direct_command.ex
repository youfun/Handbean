defmodule HandbeanWeb.WorkspaceLive.MessageSubmission.DirectCommand do
  @moduledoc false

  use Gettext, backend: Handbean.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias HandbeanWeb.WorkspaceLive.Composer
  alias HandbeanWeb.WorkspaceLive.MessageSubmission.Delivery
  alias HandbeanWeb.WorkspaceLive.RuntimeProjection

  def maybe_send(socket, message, client_operation_id) do
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

      socket.assigns.pending_attachments != [] or Composer.has_upload_entries?(socket) ->
        {:noreply,
         assign(
           socket,
           :composer_error,
           gettext("Remove attachments before running a direct command.")
         )}

      true ->
        socket = Delivery.ensure_current_conversation(socket)
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
end
