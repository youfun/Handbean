defmodule Handbean.Tool.Memory.MemReflect do
  @moduledoc """
  Schedules reflection of a persisted conversation compaction checkpoint.

  This is an explicit/manual entry point. Automatic reflection is controlled by
  the separate reflector setting.
  """

  @behaviour Handbean.Agent.Tool

  @impl true
  def name, do: "mem_reflect"

  @impl true
  def description do
    "Reflect on the latest compacted conversation context and create a reviewable " <>
      "short-term memory candidate. Use only when the user explicitly asks to organize memory."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        checkpoint_id: %{
          type: "string",
          description: "Optional persisted compaction checkpoint ID; defaults to the latest"
        }
      },
      required: []
    }
  end

  @impl true
  def max_result_chars, do: 500

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(input, context) when is_map(input) and is_map(context) do
    with conversation_id when is_binary(conversation_id) and conversation_id != "" <-
           context_value(context, :conversation_id),
         checkpoint <- checkpoint_ref(Map.get(input, "checkpoint_id")),
         {:ok, _pid} <-
           Handbean.Memory.Reflector.trigger(
             conversation_id,
             checkpoint,
             reflector_opts(context)
           ) do
      {:ok, "Memory reflection scheduled for #{checkpoint_label(checkpoint)}."}
    else
      nil -> {:error, "A persisted conversation is required for memory reflection"}
      "" -> {:error, "A persisted conversation is required for memory reflection"}
      {:error, reason} -> {:error, "Could not schedule memory reflection: #{inspect(reason)}"}
    end
  end

  def execute(_input, _context), do: {:error, "Memory reflection requires a tool context"}

  defp reflector_opts(context) do
    [
      workspace_id: context_value(context, :workspace_id),
      workspace_path: context_value(context, :workspace_path),
      working_directory: context_value(context, :working_directory)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp checkpoint_ref(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :latest
      checkpoint_id -> checkpoint_id
    end
  end

  defp checkpoint_ref(_value), do: :latest

  defp checkpoint_label(:latest), do: "the latest checkpoint"
  defp checkpoint_label(checkpoint_id), do: "checkpoint #{checkpoint_id}"

  defp context_value(context, key),
    do: Map.get(context, key) || Map.get(context, Atom.to_string(key))
end
