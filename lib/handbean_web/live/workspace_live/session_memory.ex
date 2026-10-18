defmodule HandbeanWeb.WorkspaceLive.SessionMemory do
  @moduledoc false

  alias Handbean.ConversationStore
  alias Handbean.Settings.UI

  def collapsed_groups, do: UI.collapsed_groups()

  def restore(workspaces) when is_list(workspaces) do
    case UI.last_location() do
      %{scope: :free, conversation_id: id} = location ->
        if restorable_free?(id), do: location

      %{scope: :workspace, workspace_id: workspace_id, conversation_id: id} = location ->
        if restorable_workspace?(workspace_id, id, workspaces), do: location

      _ ->
        nil
    end
  end

  def remember(socket) do
    case location(socket) do
      nil -> :ok
      location -> UI.save_last_location(location)
    end

    socket
  end

  def persist_collapsed(socket) do
    _ = UI.save_collapsed_groups(socket.assigns[:collapsed_workspace_ids] || MapSet.new())
    socket
  end

  defp location(socket) do
    conversation_id = socket.assigns[:current_conversation_id]

    cond do
      not is_binary(conversation_id) ->
        nil

      socket.assigns[:chat_scope] == :free and restorable_free?(conversation_id) ->
        %{scope: :free, conversation_id: conversation_id}

      is_binary(socket.assigns[:current_workspace_id]) and
          restorable_workspace?(
            socket.assigns.current_workspace_id,
            conversation_id,
            socket.assigns[:workspaces] || []
          ) ->
        %{
          scope: :workspace,
          workspace_id: socket.assigns.current_workspace_id,
          conversation_id: conversation_id
        }

      true ->
        nil
    end
  end

  defp restorable_free?(id) do
    case ConversationStore.get(id, include_timeline?: false) do
      {:ok, conversation} ->
        ConversationStore.free?(conversation) and not ConversationStore.internal?(conversation)

      _ ->
        false
    end
  end

  defp restorable_workspace?(workspace_id, conversation_id, workspaces) do
    with true <- Enum.any?(workspaces, &(&1["id"] == workspace_id)),
         {:ok, conversation} <- ConversationStore.get(conversation_id, include_timeline?: false),
         true <- conversation["workspace_id"] == workspace_id do
      not ConversationStore.internal?(conversation)
    else
      _ -> false
    end
  end
end
