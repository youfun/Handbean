defmodule Handbean.Extension.Command do
  @moduledoc """
  A trusted extension command explicitly invoked by a user.

  `name/0` returns `/ext:<extension>:<command>`. `execute/2` receives the raw
  argument string and the immutable conversation checkout context. Callbacks
  run in WorkspaceCommand's supervised task, never in a LiveView or registry.
  """

  @callback name() :: String.t()
  @callback execute(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}

  alias Handbean.Extension.Registry

  def parse("/ext:" <> _ = input) do
    case String.split(String.trim(input), ~r/\s+/, parts: 2) do
      [name] -> {:extension, name, ""}
      [name, args] -> {:extension, name, args}
    end
  end

  def parse(_), do: :not_command

  def list(workspace), do: Registry.capabilities(:commands, workspace)

  def resolve(workspace, name) do
    case Enum.find(list(workspace), &(&1.name == name)) do
      nil -> {:error, :not_available}
      command -> {:ok, command}
    end
  end

  def execute({:extension, name, args}, context) do
    with {:ok, command} <- resolve(context.working_directory, name) do
      case command.module.execute(args, context) do
        {status, text} when status in [:ok, :error] and is_binary(text) ->
          normalized = String.replace_invalid(text, "�")
          truncated = Handbean.Utils.Truncate.truncate_head_tail(normalized, max_bytes: 100_000)
          {status, truncated.content, %{truncated: truncated.truncated}}

        _ ->
          {:error, "Extension command returned an invalid result"}
      end
    end
  end
end
