defmodule Handbean.ConversationStore.Usage do
  @moduledoc false

  import Ecto.Query

  alias Handbean.Repo
  alias Handbean.Storage.{Conversation, ConversationRunUsage}

  @unkeyed_run_id "__unkeyed__"

  def get_token_usage(conversation_id)
      when is_binary(conversation_id) and conversation_id != "" do
    if conversation_exists?(conversation_id),
      do: {:ok, aggregate(conversation_id)},
      else: {:error, :not_found}
  end

  def get_token_usage(_conversation_id), do: {:ok, empty_token_usage()}

  def add_token_usage(conversation_id, usage)
      when is_binary(conversation_id) and conversation_id != "" and is_map(usage) do
    normalized = normalize(usage)

    if conversation_exists?(conversation_id) do
      sql = """
      INSERT INTO conversation_run_usage
        (conversation_id, run_id, source, input_tokens, output_tokens, cache_read_tokens,
         cache_write_tokens, total_input_tokens, usage_incomplete, inserted_at, updated_at)
      VALUES (?, ?, 'unkeyed', ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(conversation_id, source, run_id) DO UPDATE SET
        input_tokens = input_tokens + excluded.input_tokens,
        output_tokens = output_tokens + excluded.output_tokens,
        cache_read_tokens = cache_read_tokens + excluded.cache_read_tokens,
        cache_write_tokens = cache_write_tokens + excluded.cache_write_tokens,
        total_input_tokens = total_input_tokens + excluded.total_input_tokens,
        usage_incomplete = usage_incomplete OR excluded.usage_incomplete,
        updated_at = excluded.updated_at
      """

      timestamp = now_naive()

      params = [
        conversation_id,
        @unkeyed_run_id,
        normalized.input_tokens,
        normalized.output_tokens,
        normalized.cache_read_tokens,
        normalized.cache_write_tokens,
        normalized.total_input_tokens,
        if(normalized.usage_incomplete, do: 1, else: 0),
        timestamp,
        timestamp
      ]

      case Repo.query(sql, params) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  def record_run_usage(conversation_id, run_id, usage)
      when is_binary(conversation_id) and conversation_id != "" and is_binary(run_id) and
             run_id != "" and is_map(usage) do
    put_once(conversation_id, "parent", run_id, usage)
  end

  def rebuild_token_usage_from_events(conversation_id, events)
      when is_binary(conversation_id) and conversation_id != "" and is_list(events) do
    if conversation_exists?(conversation_id) do
      Repo.transaction(fn ->
        Repo.delete_all(
          from usage in ConversationRunUsage,
            where:
              usage.conversation_id == ^conversation_id and usage.source in ["parent", "unkeyed"]
        )

        events
        |> Enum.with_index()
        |> Enum.filter(fn {event, _index} -> terminal_event?(event) end)
        |> Enum.each(fn {event, index} ->
          run_id = event_run_key(event, index)
          insert!(conversation_id, "parent", run_id, event_usage(event))
        end)
      end)
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  def record_delegated_usage(conversation_id, child_run_id, usage) do
    put_once(conversation_id, "delegated", to_string(child_run_id), usage)
  end

  def delegated_usage(conversation_id) do
    conversation_id
    |> rows("delegated")
    |> Map.new(fn row -> {row.run_id, string_map(row)} end)
  end

  def metadata(conversation_id) do
    from(usage in ConversationRunUsage, where: usage.conversation_id == ^conversation_id)
    |> Repo.all()
    |> metadata_from_rows()
  end

  def metadata_for_ids([]), do: %{}

  def metadata_for_ids(conversation_ids) when is_list(conversation_ids) do
    grouped =
      from(usage in ConversationRunUsage, where: usage.conversation_id in ^conversation_ids)
      |> Repo.all()
      |> Enum.group_by(& &1.conversation_id)

    Map.new(conversation_ids, fn conversation_id ->
      {conversation_id, metadata_from_rows(Map.get(grouped, conversation_id, []))}
    end)
  end

  def empty_metadata do
    %{
      "token_usage" => atom_to_string_map(empty_token_usage()),
      "run_usage" => %{},
      "usage_legacy" => atom_to_string_map(empty_token_usage()),
      "delegated_usage" => %{}
    }
  end

  defp conversation_exists?(conversation_id) when is_binary(conversation_id) do
    Repo.exists?(
      from conversation in Conversation,
        where: conversation.id == ^conversation_id and conversation.status == "active"
    )
  end

  defp put_once(conversation_id, source, run_id, usage) do
    if conversation_exists?(conversation_id) do
      Repo.insert_all(ConversationRunUsage, [attrs(conversation_id, source, run_id, usage)],
        on_conflict: :nothing,
        conflict_target: [:conversation_id, :source, :run_id]
      )

      :ok
    else
      {:error, :not_found}
    end
  end

  defp insert!(conversation_id, source, run_id, usage) do
    Repo.insert_all(ConversationRunUsage, [attrs(conversation_id, source, run_id, usage)],
      on_conflict: :nothing,
      conflict_target: [:conversation_id, :source, :run_id]
    )
  end

  defp attrs(conversation_id, source, run_id, usage) do
    timestamp = now()

    usage
    |> normalize()
    |> Map.from_struct()
    |> Map.take([
      :input_tokens,
      :output_tokens,
      :cache_read_tokens,
      :cache_write_tokens,
      :total_input_tokens,
      :usage_incomplete
    ])
    |> Map.merge(%{
      conversation_id: conversation_id,
      source: source,
      run_id: run_id,
      inserted_at: timestamp,
      updated_at: timestamp
    })
  end

  defp rows(conversation_id, source) do
    Repo.all(
      from usage in ConversationRunUsage,
        where: usage.conversation_id == ^conversation_id and usage.source == ^source
    )
  end

  defp metadata_from_rows(rows) do
    grouped = Enum.group_by(rows, & &1.source)
    parent = Map.get(grouped, "parent", [])
    unkeyed = Map.get(grouped, "unkeyed", [])
    delegated = Map.get(grouped, "delegated", [])
    total = Enum.reduce(parent ++ unkeyed, empty_token_usage(), &sum/2)

    %{
      "token_usage" => atom_to_string_map(total),
      "run_usage" => Map.new(parent, &{&1.run_id, string_map(&1)}),
      "usage_legacy" =>
        unkeyed |> Enum.reduce(empty_token_usage(), &sum/2) |> atom_to_string_map(),
      "delegated_usage" => Map.new(delegated, &{&1.run_id, string_map(&1)})
    }
  end

  defp aggregate(conversation_id) do
    conversation_id
    |> then(fn id -> rows(id, "parent") ++ rows(id, "unkeyed") end)
    |> Enum.reduce(empty_token_usage(), &sum/2)
  end

  defp sum(row, acc) do
    %{
      input_tokens: acc.input_tokens + row.input_tokens,
      output_tokens: acc.output_tokens + row.output_tokens,
      cache_read_tokens: acc.cache_read_tokens + row.cache_read_tokens,
      cache_write_tokens: acc.cache_write_tokens + row.cache_write_tokens,
      total_input_tokens: acc.total_input_tokens + row.total_input_tokens,
      usage_incomplete: acc.usage_incomplete or row.usage_incomplete
    }
  end

  defp normalize(usage) do
    input = number(usage, [:input_tokens, "input_tokens"])
    output = number(usage, [:output_tokens, "output_tokens"])

    read =
      number(usage, [
        :cache_read_input_tokens,
        "cache_read_input_tokens",
        :cache_read_tokens,
        "cache_read_tokens"
      ])

    write =
      number(usage, [
        :cache_creation_input_tokens,
        "cache_creation_input_tokens",
        :cache_write_tokens,
        "cache_write_tokens"
      ])

    total =
      case fetch(usage, [:total_input_tokens, "total_input_tokens"]) do
        value when is_number(value) -> round(value)
        _ -> input + read + write
      end

    %ConversationRunUsage{
      input_tokens: input,
      output_tokens: output,
      cache_read_tokens: read,
      cache_write_tokens: write,
      total_input_tokens: total,
      usage_incomplete:
        fetch(usage, [:unknown?, "unknown?", :unknown, "unknown"]) in [true, "true"]
    }
  end

  defp number(usage, keys) do
    case fetch(usage, keys) do
      value when is_number(value) -> round(value)
      _ -> 0
    end
  end

  defp fetch(usage, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(usage, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp empty_token_usage do
    %{
      input_tokens: 0,
      output_tokens: 0,
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      total_input_tokens: 0,
      usage_incomplete: false
    }
  end

  defp string_map(row) do
    %{
      "input_tokens" => row.input_tokens,
      "output_tokens" => row.output_tokens,
      "cache_read_tokens" => row.cache_read_tokens,
      "cache_write_tokens" => row.cache_write_tokens,
      "total_input_tokens" => row.total_input_tokens,
      "unknown" => row.usage_incomplete
    }
  end

  defp atom_to_string_map(usage) do
    %{
      "input_tokens" => usage.input_tokens,
      "output_tokens" => usage.output_tokens,
      "cache_read_tokens" => usage.cache_read_tokens,
      "cache_write_tokens" => usage.cache_write_tokens,
      "total_input_tokens" => usage.total_input_tokens,
      "unknown" => usage.usage_incomplete
    }
  end

  defp terminal_event?(event) when is_map(event) do
    kind = fetch(event, [:kind, "kind"])
    payload = fetch(event, [:payload, "payload"]) || %{}
    status = fetch(payload, [:status, "status"])
    kind in [:run_end, "run_end"] and status not in [:interrupted, "interrupted", nil]
  end

  defp terminal_event?(_event), do: false

  defp event_usage(event),
    do: fetch(fetch(event, [:payload, "payload"]) || %{}, [:usage, "usage"]) || %{}

  defp event_run_key(event, index) do
    payload = fetch(event, [:payload, "payload"]) || %{}

    fetch(payload, [:run_id, "run_id"]) || fetch(event, [:run_id, "run_id"]) ||
      "event-#{index}"
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp now_naive,
    do: DateTime.utc_now() |> DateTime.to_naive() |> NaiveDateTime.truncate(:microsecond)
end
