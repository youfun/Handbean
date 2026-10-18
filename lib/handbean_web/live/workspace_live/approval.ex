defmodule HandbeanWeb.WorkspaceLive.Approval do
  @moduledoc false

  require Logger

  def action_requests(%{action_requests: requests}) when is_list(requests), do: requests
  def action_requests(%{"action_requests" => requests}) when is_list(requests), do: requests

  def action_requests(pending) when is_map(pending),
    do: Handbean.Utils.SafeMap.get_any(pending, :action_requests, "action_requests") || []

  def action_requests(_), do: []

  def format_arguments(args) when is_map(args) do
    case Handbean.JSON.encode(args, pretty: true) do
      {:ok, json} -> String.slice(json, 0, 2000)
      {:error, _reason} -> inspect(args)
    end
  end

  def format_arguments(args), do: inspect(args)

  def remember_scope(%{"remember" => "always"}), do: :always
  def remember_scope(%{"remember" => "session"}), do: :session
  def remember_scope(_params), do: :once

  def resume(conversation_id, pending, action, remember, workspace_root)
      when action in [:approve, :deny] do
    persist_rules(pending, action, remember, workspace_root)
    Handbean.Agent.Coordinator.resume(conversation_id, decisions(pending, action, remember))
  end

  defp persist_rules(pending, action, :always, workspace_root) do
    list = if action == :approve, do: :allow, else: :deny

    Enum.each(action_requests(pending), fn request ->
      pattern =
        Handbean.Utils.SafeMap.get_any(request, :suggested_pattern, "suggested_pattern") ||
          Handbean.Utils.SafeMap.get_any(request, :tool_name, "tool_name")

      if is_binary(pattern) and String.trim(pattern) != "" do
        case Handbean.WorkspaceSettings.append_tool_rule(workspace_root, list, pattern) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[WorkspaceLive] failed to persist #{list} rule #{pattern}: #{inspect(reason)}"
            )
        end
      end
    end)
  end

  defp persist_rules(_pending, _action, _remember, _workspace_root), do: :ok

  defp decisions(pending, action, remember) do
    Enum.map(action_requests(pending), fn request ->
      %{
        "tool_call_id" =>
          Handbean.Utils.SafeMap.get_any(request, [:tool_call_id, "tool_call_id"]),
        "tool_name" => Handbean.Utils.SafeMap.get_any(request, :tool_name, "tool_name"),
        "action" => Atom.to_string(action),
        "remember" => remember == :session
      }
    end)
  end
end
