defmodule HandbeanWeb.InAppNotification do
  @moduledoc false

  use Gettext, backend: Handbean.Gettext

  def ended_flash(task, reason, navigate_with) do
    %{
      body: ended_message(task, reason),
      navigate: conversation_path(task),
      navigate_with: navigate_with
    }
  end

  defp conversation_path(%{scope: "free", conversation_id: id})
       when is_binary(id) and id != "",
       do: "/c/#{id}"

  defp conversation_path(%{conversation_id: id, workspace_id: workspace_id})
       when is_binary(id) and id != "" and is_binary(workspace_id) and workspace_id != "",
       do: "/w/#{workspace_id}/c/#{id}"

  defp conversation_path(_task), do: nil

  defp ended_message(task, reason) do
    title = task[:title] || gettext("conversation")

    case reason do
      :cancelled -> gettext("Agent stopped in %{title}.", title: title)
      :failed -> gettext("This run ended in %{title}.", title: title)
      _ -> gettext("Agent replied in %{title}.", title: title)
    end
  end
end
