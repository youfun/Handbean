defmodule Handbean.Tool.Builtin.ErrorTracker do
  @moduledoc "Inspect and triage errors recorded by ErrorTracker."

  @behaviour Handbean.Agent.Tool

  import Ecto.Query

  alias ErrorTracker.{Error, Occurrence, Repo}

  @actions ~w(list get resolve mute)
  @max_list 20
  @max_occurrences 10

  @impl true
  def name, do: "error_tracker"

  @impl true
  def description do
    """
    Inspect unresolved application exceptions recorded by ErrorTracker. Use list first, then get for recent sanitized context and stack traces. Resolve only after the defect is fixed and verified, or after confirming it is transient; a new occurrence will reopen it. Mute only permanently noisy errors. Errors raised by the automatic debugger itself are omitted from list to prevent feedback loops.
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      additionalProperties: false,
      required: ["action"],
      properties: %{
        action: %{type: "string", enum: @actions},
        id: %{type: "integer", minimum: 1},
        limit: %{type: "integer", minimum: 1, maximum: @max_list},
        occurrences: %{type: "integer", minimum: 1, maximum: @max_occurrences}
      }
    }
  end

  @impl true
  def concurrent?, do: false

  @impl true
  def max_result_chars, do: 30_000

  @impl true
  def execute(input, context) when is_map(input) and is_map(context) do
    case field(input, "action") do
      "list" -> list_errors(input, context)
      "get" -> with_error(input, &get_error(&1, input))
      "resolve" -> with_error(input, &resolve/1)
      "mute" -> with_error(input, &mute/1)
      _ -> {:error, "unknown error_tracker action"}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  def execute(_, _), do: {:error, "invalid error_tracker input"}

  defp list_errors(input, context) do
    limit = bounded_integer(field(input, "limit"), 10, @max_list)

    errors =
      from(error in Error,
        where: error.status == :unresolved and error.muted == false,
        order_by: [desc: error.last_occurrence_at],
        limit: ^min(limit * 5, 100)
      )
      |> Repo.all()
      |> Enum.reject(&self_generated_error?(&1, context))
      |> Enum.take(limit)
      |> Enum.map(&summary/1)

    {:ok, Jason.encode!(errors)}
  end

  defp get_error(error, input) do
    limit = bounded_integer(field(input, "occurrences"), 3, @max_occurrences)

    occurrences =
      from(occurrence in Occurrence,
        where: occurrence.error_id == ^error.id,
        order_by: [desc: occurrence.inserted_at],
        limit: ^limit
      )
      |> Repo.all()
      |> Enum.map(&occurrence/1)

    {:ok, Jason.encode!(Map.put(summary(error), :occurrences, occurrences))}
  end

  defp resolve(%Error{status: :resolved}), do: {:ok, "already resolved"}

  defp resolve(error) do
    case ErrorTracker.resolve(error) do
      {:ok, updated} -> {:ok, Jason.encode!(summary(updated))}
      {:error, changeset} -> {:error, inspect(changeset.errors)}
    end
  end

  defp mute(%Error{muted: true}), do: {:ok, "already muted"}

  defp mute(error) do
    case ErrorTracker.mute(error) do
      {:ok, updated} -> {:ok, Jason.encode!(summary(updated))}
      {:error, changeset} -> {:error, inspect(changeset.errors)}
    end
  end

  defp with_error(input, fun) do
    with {:ok, id} <- error_id(input),
         %Error{} = error <- Repo.get(Error, id) do
      fun.(error)
    else
      nil -> {:error, "error not found"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp error_id(input) do
    case field(input, "id") do
      id when is_integer(id) and id > 0 -> {:ok, id}
      _ -> {:error, "id is required"}
    end
  end

  defp summary(error) do
    %{
      id: error.id,
      kind: error.kind,
      reason: error.reason,
      source_line: error.source_line,
      source_function: error.source_function,
      status: error.status,
      muted: error.muted,
      occurrence_count: occurrence_count(error.id),
      last_occurrence_at: error.last_occurrence_at
    }
  end

  defp occurrence(occurrence) do
    %{
      id: occurrence.id,
      reason: occurrence.reason,
      context: occurrence.context || %{},
      breadcrumbs: occurrence.breadcrumbs || [],
      stacktrace: Enum.map(occurrence.stacktrace.lines, &stack_line/1),
      inserted_at: occurrence.inserted_at
    }
  end

  defp stack_line(line) do
    Map.take(line, [:application, :module, :function, :arity, :file, :line])
  end

  defp occurrence_count(error_id) do
    from(occurrence in Occurrence, where: occurrence.error_id == ^error_id)
    |> Repo.aggregate(:count)
  end

  defp self_generated_error?(error, context) do
    occurrence_context =
      from(occurrence in Occurrence,
        where: occurrence.error_id == ^error.id,
        order_by: [desc: occurrence.inserted_at],
        limit: 1,
        select: occurrence.context
      )
      |> Repo.one()

    conversation_id = field(context, "conversation_id")
    occurrence_conversation_id = field(occurrence_context || %{}, "conversation_id")
    parent_conversation_id = field(occurrence_context || %{}, "parent_conversation_id")

    field(context, "source") in [:schedule, "schedule"] and is_binary(conversation_id) and
      conversation_id in [occurrence_conversation_id, parent_conversation_id]
  end

  defp bounded_integer(value, _default, max) when is_integer(value),
    do: value |> max(1) |> min(max)

  defp bounded_integer(_value, default, _max), do: default

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))
end
