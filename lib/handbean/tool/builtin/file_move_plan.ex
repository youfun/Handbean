defmodule Handbean.Tool.Builtin.FileMovePlan do
  @moduledoc "Conversation file organization through host-confirmed move plans."
  @behaviour Handbean.Agent.Tool

  alias Handbean.FileMovePlans

  @impl true
  def name, do: "file_move_plan"

  @impl true
  def description do
    """
    Propose a file organization plan for the current checkout. Scan with existing read/search tools first, then create with up to 20 {source, target, reason} entries using checkout-relative paths. Only regular files, at most 32 MiB each and 128 MiB total; no overwrite, deletion action, directory moves or cross-filesystem fallback.

    create saves an immutable plan and shows a selection card in Web chat. It does not move files. The user selects entries and confirms in the host card. Do not ask the user to type IDs and do not execute moves with bash instead of waiting for this confirmation. Native clients can inspect get results but do not yet have the selection card.

    execute requires only the plan id; it uses exactly the selection already stored by the host. The model cannot confirm or change that selection. Normal tool permissions still apply. get reads the latest plan and per-item receipts. Repeated execute of a completed plan returns the existing result. An interrupted executing plan is frozen as needs_review and must be inspected manually; never retry it blindly. Plans expire after 24 hours. Report completed, failed and uncertain items separately.
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: %{
        action: %{type: "string", enum: ["create", "get", "execute"]},
        id: %{type: "string", description: "Plan id for get or execute."},
        title: %{type: "string", maxLength: 200},
        entries: %{
          type: "array",
          minItems: 1,
          maxItems: 20,
          items: %{
            type: "object",
            additionalProperties: false,
            required: ["source", "target"],
            properties: %{
              source: %{type: "string"},
              target: %{type: "string"},
              reason: %{type: "string"}
            }
          }
        }
      }
    }
  end

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(input, context) when is_map(input) and is_map(context) do
    with :ok <- validate_input(input),
         {:ok, plan} <- perform(input, context) do
      details = %{
        file_move_plan_id: plan.id,
        side_effect: side_effect(plan),
        recovery: if(plan.status in ["executing", "needs_review"], do: :inspect, else: :none)
      }

      output = Handbean.JSON.encode!(summary(plan))

      if plan.status in ["failed", "executing", "needs_review"],
        do: {:error, output, details},
        else: {:ok, output, details}
    else
      {:error, reason} -> {:error, "File move plan: #{inspect(reason)}"}
    end
  end

  def execute(_, _), do: {:error, "invalid file_move_plan input"}

  defp validate_input(input) do
    allowed = if input["action"] == "create", do: ~w(action title entries), else: ~w(action id)

    cond do
      Enum.any?(Map.keys(input), &(&1 not in allowed)) -> {:error, :unknown_input}
      input["action"] not in ~w(create get execute) -> {:error, :unknown_action}
      input["action"] != "create" and not is_binary(input["id"]) -> {:error, :plan_id_required}
      true -> :ok
    end
  end

  defp perform(%{"action" => "create"} = input, context), do: FileMovePlans.create(context, input)
  defp perform(%{"action" => "get", "id" => id}, context), do: FileMovePlans.get(context, id)

  defp perform(%{"action" => "execute", "id" => id}, context),
    do: FileMovePlans.execute(context, id)

  defp summary(plan) do
    %{
      id: plan.id,
      title: plan.title,
      status: plan.status,
      version: plan.version,
      selected_ids: plan.selected_ids,
      expires_at: DateTime.to_iso8601(plan.expires_at),
      entries:
        Enum.map(plan.entries, &Map.take(&1, ~w(id source target reason size status error)))
    }
  end

  defp side_effect(%{status: status}) when status in ["draft", "confirmed"], do: :not_started
  defp side_effect(%{status: "completed"}), do: :committed
  defp side_effect(_), do: :unknown
end
