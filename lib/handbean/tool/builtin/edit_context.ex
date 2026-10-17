defmodule Handbean.Tool.Builtin.EditContext do
  @moduledoc """
  Replaces one exact span in the model-facing tail.

  The original task, system prompt, tool schemas, and the transcript stay.
  """

  @behaviour Handbean.Agent.Tool

  alias Handbean.Agent.ModelContext
  alias Handbean.Utils.SafeMap

  @impl true
  def name, do: "edit_context"

  @impl true
  def description do
    "Replace one exact old_text span in the editable tail of this run's context. " <>
      "Use it to drop a finished log and keep the plan, paths, and facts. " <>
      "old_text must match once. An empty new_text deletes the span. " <>
      "The original task, system prompt, tool schemas, and the transcript stay unchanged."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        old_text: %{
          type: "string",
          description:
            "Exact text copied from a read_context body, under the [[ctx:N]] line and not including that line. It must match once."
        },
        new_text: %{
          type: "string",
          description:
            "Replacement, at most 8000 bytes. Keep the plan, paths, and facts. Empty deletes the span."
        }
      },
      required: ["old_text", "new_text"]
    }
  end

  @impl true
  def concurrent?, do: false

  @impl true
  def max_result_chars, do: 2_000

  @impl true
  def execute(input, context) when is_map(input) do
    old = SafeMap.get_any(input, "old_text", :old_text)
    new = SafeMap.get_any(input, "new_text", :new_text)
    messages = context[:model_messages] || []

    case ModelContext.replace(messages, old, new) do
      {:ok, revised} ->
        {:ok, "Context updated. The original task is unchanged.", %{model_context: revised}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(_input, _context), do: {:error, "old_text is required"}
end
