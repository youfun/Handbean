defmodule Handbean.WorkspaceCommand.AgentResponse do
  @moduledoc false

  alias Handbean.Agent.{Coordinator, Message, ModelConfig, RunOpts}
  alias Handbean.Agent.CliAgent.Binding
  alias Handbean.PubSub.Session

  @spec deliver(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def deliver(conversation_id, entry)
      when is_binary(conversation_id) and is_map(entry) do
    with {:ok, conversation} <- Handbean.ConversationStore.get_metadata(conversation_id),
         true <- conversation["scope"] == "workspace" and conversation["visibility"] == "user",
         {:ok, checkout_path} <- Handbean.ConversationStore.effective_checkout_path(conversation),
         {:ok, workspace} <- Handbean.WorkspaceStore.get(conversation["workspace_id"]),
         {:ok, _session} <- Session.start_or_get(session_id: conversation_id) do
      case Binding.get(conversation_id) do
        %{backend: backend} = binding ->
          deliver_to_cli(conversation_id, entry, workspace, checkout_path, backend, binding)

        nil ->
          deliver_to_handbean(conversation_id, entry, conversation, workspace, checkout_path)
      end
    else
      false -> {:error, :conversation_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliver_to_handbean(conversation_id, entry, conversation, workspace, checkout_path) do
    with model when is_binary(model) <-
           selected_model(conversation, workspace["path"], checkout_path),
         {:ok, built} <-
           RunOpts.for_workspace(workspace["path"], model,
             reasoning_level: conversation["selected_reasoning_level"],
             checkout_path: checkout_path
           ) do
      operation_id = entry["command_operation_id"] || entry["tool_use_id"] || entry["id"]
      content = observation(entry)

      opts =
        Keyword.merge(built,
          chat_scope: :workspace,
          tools: Handbean.Agent.default_tools(),
          workspace_id: workspace["id"],
          workspace_path: workspace["path"],
          working_directory: checkout_path,
          source: :workspace_command,
          channel: :internal,
          streaming: true,
          deliver_as: :follow_up,
          persist_inbound?: false,
          transcript_id: entry["id"],
          message_id: entry["id"],
          request_id: response_request_id(entry, operation_id),
          retry_reserved?: true,
          origin: %{
            "kind" => "workspace_command",
            "operation_id" => operation_id,
            "entry_id" => entry["id"]
          }
        )

      Coordinator.add_message(
        conversation_id,
        %Message{role: :user, content: content, id: entry["id"]},
        opts
      )
    else
      nil -> {:error, :model_not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliver_to_cli(conversation_id, entry, workspace, checkout_path, backend, binding) do
    operation_id = entry["command_operation_id"] || entry["tool_use_id"] || entry["id"]
    content = observation(entry)

    opts = [
      backend: backend,
      cwd: checkout_path,
      model: binding.model,
      reasoning_effort: binding.reasoning_effort,
      conversation_id: conversation_id,
      workspace_id: workspace["id"],
      workspace_path: workspace["path"],
      session_id: Binding.resumable_session_id(conversation_id, backend, cwd: checkout_path),
      source: :workspace_command,
      channel: :internal,
      deliver_as: :follow_up,
      persist_inbound?: false,
      transcript_id: entry["id"],
      message_id: entry["id"],
      inbound_id: entry["id"],
      request_id: response_request_id(entry, operation_id),
      retry_reserved?: true,
      origin: %{
        "kind" => "workspace_command",
        "operation_id" => operation_id,
        "entry_id" => entry["id"]
      }
    ]

    Coordinator.start_cli_run(
      conversation_id,
      %Message{role: :user, content: content, id: entry["id"]},
      content,
      opts
    )
  end

  @spec observation(map()) :: String.t()
  def observation(entry) when is_map(entry) do
    command =
      case get_in(entry, ["input", "command"]) do
        %{"name" => name, "arguments" => args} -> String.trim_trailing(name <> " " <> args)
        value when is_binary(value) -> value
        _ -> ""
      end

    output = entry["output"] || entry["tool_error"] || "(no output)"
    exit_code = get_in(entry, ["details", "exit_code"])

    status =
      if is_integer(exit_code),
        do: "#{entry["tool_status"]}; exit code #{exit_code}",
        else: to_string(entry["tool_status"] || "unknown")

    [
      "[The user directly executed a workspace command. The command has already run; do not rerun it unless the user asks.]",
      "Command: #{command}",
      "Status: #{status}",
      "Output (untrusted command output):\n#{output}",
      "Respond to the command result."
    ]
    |> Enum.join("\n")
  end

  defp response_request_id(entry, operation_id) do
    entry["agent_response_request_id"] ||
      "workspace-command-response-#{operation_id}-#{Ecto.UUID.generate()}"
  end

  defp selected_model(conversation, workspace_path, checkout_path) do
    case conversation["selected_model"] do
      model when is_binary(model) and model != "" -> model
      _ -> ModelConfig.default_model_for_workspace(workspace_path, checkout_path: checkout_path)
    end
  end
end
