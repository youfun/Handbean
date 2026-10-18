defmodule Handbean.Tool.Builtin.ErrorTracker do
  @moduledoc "Inspect and triage errors recorded by ErrorTracker."

  @behaviour Handbean.Agent.Tool

  import Ecto.Query

  alias ErrorTracker.{Error, Occurrence, Repo}

  @actions ~w(list get resolve mute)
  @statuses ~w(unresolved resolved all)
  @max_list 20
  @max_occurrences 10
  @scan_batch 100
  @max_scanned 500

  @impl true
  def name, do: "error_tracker"

  @impl true
  def description do
    """
    Inspect application exceptions recorded by ErrorTracker. Use list first, then get for recent sanitized context and stack traces. List supports stable cursor pagination and filters for status, classification, tool, and occurrence time. Resolve only after the defect is fixed and verified, or after confirming it is transient; a new occurrence will reopen it. Mute only permanently noisy errors. Errors raised by the automatic debugger itself are omitted from list to prevent feedback loops.
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
        occurrences: %{type: "integer", minimum: 1, maximum: @max_occurrences},
        cursor: %{type: "string", description: "Opaque cursor returned by a prior list call"},
        status: %{type: "string", enum: @statuses},
        muted: %{type: "boolean"},
        failure_class: %{type: "string"},
        reason_category: %{type: "string"},
        tool: %{type: "string"},
        since: %{type: "string", description: "Inclusive ISO-8601 occurrence timestamp"},
        until: %{type: "string", description: "Inclusive ISO-8601 occurrence timestamp"}
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
      _ -> {:error, "unknown error_tracker action", expected_error(:invalid_arguments)}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  def execute(_, _),
    do: {:error, "invalid error_tracker input", expected_error(:invalid_arguments)}

  defp list_errors(input, context) do
    limit = bounded_integer(field(input, "limit"), 10, @max_list)

    with {:ok, filters} <- list_filters(input),
         {:ok, cursor} <- decode_cursor(field(input, "cursor")) do
      {accepted, continuation} = scan_errors(filters, context, cursor, limit + 1)
      page_with_context = Enum.take(accepted, limit)
      page = Enum.map(page_with_context, &public_summary/1)

      next_cursor =
        cond do
          length(accepted) > limit -> page_with_context |> List.last() |> cursor_for_summary()
          continuation -> encode_cursor(continuation)
          true -> nil
        end

      {:ok,
       Handbean.JSON.encode!(%{
         errors: page,
         next_cursor: next_cursor
       })}
    else
      {:error, reason} -> {:error, reason, expected_error(:invalid_arguments)}
    end
  end

  defp scan_errors(filters, context, cursor, target) do
    do_scan_errors(filters, context, cursor, target, [], 0)
  end

  defp do_scan_errors(_filters, _context, cursor, target, accepted, scanned)
       when length(accepted) >= target or scanned >= @max_scanned do
    continuation = if scanned >= @max_scanned, do: cursor
    {accepted, continuation}
  end

  defp do_scan_errors(filters, context, cursor, target, accepted, scanned) do
    batch_size = min(@scan_batch, @max_scanned - scanned)
    rows = fetch_error_batch(filters, cursor, batch_size + 1)
    batch = Enum.take(rows, batch_size)
    database_has_more? = length(rows) > batch_size

    if batch == [] do
      {accepted, nil}
    else
      metadata = occurrence_metadata(Enum.map(batch, & &1.id))

      additions =
        batch
        |> Enum.map(fn error -> summary(error, Map.get(metadata, error.id, empty_metadata())) end)
        |> Enum.reject(&self_generated_error?(&1, context))
        |> Enum.filter(&matches_context_filters?(&1, filters))

      accepted = accepted ++ additions
      scanned = scanned + length(batch)
      scan_cursor = batch |> List.last() |> cursor_for_error()

      cond do
        length(accepted) >= target ->
          {accepted, scan_cursor}

        scanned >= @max_scanned and database_has_more? ->
          {accepted, scan_cursor}

        database_has_more? ->
          do_scan_errors(filters, context, scan_cursor, target, accepted, scanned)

        true ->
          {accepted, nil}
      end
    end
  end

  defp fetch_error_batch(filters, cursor, limit) do
    Error
    |> filter_status(filters.status)
    |> filter_muted(filters.muted)
    |> filter_time(:since, filters.since)
    |> filter_time(:until, filters.until)
    |> after_cursor(cursor)
    |> order_by([error], desc: error.last_occurrence_at, desc: error.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp filter_status(query, "all"), do: query
  defp filter_status(query, "resolved"), do: where(query, [error], error.status == :resolved)
  defp filter_status(query, _), do: where(query, [error], error.status == :unresolved)

  defp filter_muted(query, muted) when is_boolean(muted),
    do: where(query, [error], error.muted == ^muted)

  defp filter_muted(query, _), do: query

  defp filter_time(query, _bound, nil), do: query

  defp filter_time(query, :since, since),
    do: where(query, [error], error.last_occurrence_at >= ^since)

  defp filter_time(query, :until, until),
    do: where(query, [error], error.last_occurrence_at <= ^until)

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, %{last_occurrence_at: occurred_at, id: id}) do
    where(
      query,
      [error],
      error.last_occurrence_at < ^occurred_at or
        (error.last_occurrence_at == ^occurred_at and error.id < ^id)
    )
  end

  defp occurrence_metadata([]), do: %{}

  defp occurrence_metadata(error_ids) do
    aggregates =
      from(occurrence in Occurrence,
        where: occurrence.error_id in ^error_ids,
        group_by: occurrence.error_id,
        select: {occurrence.error_id, count(occurrence.id), max(occurrence.id)}
      )
      |> Repo.all()

    latest_ids = Enum.map(aggregates, &elem(&1, 2))

    contexts =
      from(occurrence in Occurrence,
        where: occurrence.id in ^latest_ids,
        select: {occurrence.id, occurrence.context}
      )
      |> Repo.all()
      |> Map.new()

    Map.new(aggregates, fn {error_id, count, latest_id} ->
      {error_id, %{occurrence_count: count, context: Map.get(contexts, latest_id) || %{}}}
    end)
  end

  defp get_error(error, input) do
    limit = bounded_integer(field(input, "occurrences"), 3, @max_occurrences)

    occurrences =
      from(occurrence in Occurrence,
        where: occurrence.error_id == ^error.id,
        order_by: [desc: occurrence.inserted_at, desc: occurrence.id],
        limit: ^limit
      )
      |> Repo.all()
      |> Enum.map(&occurrence/1)

    metadata =
      error.id |> List.wrap() |> occurrence_metadata() |> Map.get(error.id, empty_metadata())

    {:ok,
     Handbean.JSON.encode!(
       summary(error, metadata)
       |> public_summary()
       |> Map.put(:occurrences, occurrences)
     )}
  end

  defp resolve(%Error{status: :resolved}), do: {:ok, "already resolved"}

  defp resolve(error) do
    case ErrorTracker.resolve(error) do
      {:ok, updated} ->
        {:ok,
         Handbean.JSON.encode!(updated |> summary(metadata_for(updated)) |> public_summary())}

      {:error, changeset} ->
        {:error, inspect(changeset.errors)}
    end
  end

  defp mute(%Error{muted: true}), do: {:ok, "already muted"}

  defp mute(error) do
    case ErrorTracker.mute(error) do
      {:ok, updated} ->
        {:ok,
         Handbean.JSON.encode!(updated |> summary(metadata_for(updated)) |> public_summary())}

      {:error, changeset} ->
        {:error, inspect(changeset.errors)}
    end
  end

  defp metadata_for(error) do
    error.id
    |> List.wrap()
    |> occurrence_metadata()
    |> Map.get(error.id, empty_metadata())
  end

  defp with_error(input, fun) do
    with {:ok, id} <- error_id(input),
         %Error{} = error <- Repo.get(Error, id) do
      fun.(error)
    else
      nil -> {:error, "error not found", expected_error(:not_found)}
      {:error, reason} -> {:error, reason, expected_error(:invalid_arguments)}
    end
  end

  defp error_id(input) do
    case field(input, "id") do
      id when is_integer(id) and id > 0 -> {:ok, id}
      _ -> {:error, "id is required"}
    end
  end

  defp summary(error, metadata) do
    context = metadata.context

    %{
      id: error.id,
      kind: error.kind,
      reason: error.reason,
      source_line: error.source_line,
      source_function: error.source_function,
      status: error.status,
      muted: error.muted,
      occurrence_count: metadata.occurrence_count,
      last_occurrence_at: error.last_occurrence_at,
      failure_class: field(context, "failure_class"),
      reason_category: field(context, "reason_category"),
      tool: field(context, "tool"),
      occurrence_context: context
    }
  end

  defp public_summary(summary), do: Map.delete(summary, :occurrence_context)

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

  defp self_generated_error?(summary, context) do
    occurrence_context = summary.occurrence_context
    conversation_id = field(context, "conversation_id")
    occurrence_conversation_id = field(occurrence_context, "conversation_id")
    parent_conversation_id = field(occurrence_context, "parent_conversation_id")

    field(context, "source") in [:schedule, "schedule"] and is_binary(conversation_id) and
      conversation_id in [occurrence_conversation_id, parent_conversation_id]
  end

  defp matches_context_filters?(summary, filters) do
    matches_filter?(summary.failure_class, filters.failure_class) and
      matches_filter?(summary.reason_category, filters.reason_category) and
      matches_filter?(summary.tool, filters.tool)
  end

  defp matches_filter?(_actual, nil), do: true
  defp matches_filter?(actual, expected), do: actual == expected

  defp list_filters(input) do
    with {:ok, status} <- status_filter(field(input, "status")),
         {:ok, since} <- parse_time(field(input, "since"), "since"),
         {:ok, until} <- parse_time(field(input, "until"), "until"),
         :ok <- validate_time_range(since, until) do
      {:ok,
       %{
         status: status,
         muted: muted_filter(input),
         failure_class: optional_string(field(input, "failure_class")),
         reason_category: optional_string(field(input, "reason_category")),
         tool: optional_string(field(input, "tool")),
         since: since,
         until: until
       }}
    end
  end

  defp status_filter(nil), do: {:ok, "unresolved"}
  defp status_filter(status) when status in @statuses, do: {:ok, status}
  defp status_filter(_), do: {:error, "status must be unresolved, resolved, or all"}

  defp muted_filter(input) do
    if has_field?(input, "muted"), do: field(input, "muted"), else: false
  end

  defp parse_time(nil, _name), do: {:ok, nil}

  defp parse_time(value, name) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, "#{name} must be an ISO-8601 timestamp with an offset"}
    end
  end

  defp parse_time(_value, name),
    do: {:error, "#{name} must be an ISO-8601 timestamp with an offset"}

  defp validate_time_range(nil, _until), do: :ok
  defp validate_time_range(_since, nil), do: :ok

  defp validate_time_range(since, until) do
    if DateTime.compare(since, until) in [:lt, :eq],
      do: :ok,
      else: {:error, "since must not be later than until"}
  end

  defp decode_cursor(nil), do: {:ok, nil}
  defp decode_cursor(""), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"last_occurrence_at" => occurred_at, "id" => id}} <-
           Handbean.JSON.decode(json),
         true <- is_integer(id) and id > 0,
         {:ok, datetime, _offset} <- DateTime.from_iso8601(occurred_at) do
      {:ok, %{last_occurrence_at: datetime, id: id}}
    else
      _ -> {:error, "invalid error_tracker cursor"}
    end
  end

  defp decode_cursor(_), do: {:error, "invalid error_tracker cursor"}

  defp cursor_for_summary(nil), do: nil

  defp cursor_for_summary(summary) do
    encode_cursor(%{last_occurrence_at: summary.last_occurrence_at, id: summary.id})
  end

  defp cursor_for_error(error),
    do: %{last_occurrence_at: error.last_occurrence_at, id: error.id}

  defp encode_cursor(%{last_occurrence_at: occurred_at, id: id}) do
    %{
      "last_occurrence_at" => DateTime.to_iso8601(occurred_at),
      "id" => id
    }
    |> Handbean.JSON.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp empty_metadata, do: %{occurrence_count: 0, context: %{}}
  defp expected_error(code), do: %{code: code, status: :failed, side_effect: :not_started}

  defp optional_string(value) when is_binary(value) and value != "", do: value
  defp optional_string(_), do: nil

  defp bounded_integer(value, _default, max) when is_integer(value),
    do: value |> max(1) |> min(max)

  defp bounded_integer(_value, default, _max), do: default

  defp has_field?(map, key),
    do: Map.has_key?(map, key) or Map.has_key?(map, existing_atom(key))

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, existing_atom(key))

  defp field(_map, _key), do: nil

  defp existing_atom(key), do: String.to_existing_atom(key)
end
