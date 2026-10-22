defmodule Handbean.ConversationTranscriptStore.ConversationStore do
  @moduledoc """
  SQLite implementation of `Handbean.ConversationTranscriptStore`.

  Stable envelope fields are indexed columns; entry-specific data stays in the
  payload and is projected back into one string-key map here.
  """

  @behaviour Handbean.ConversationTranscriptStore

  import Ecto.Query

  alias Ecto.Changeset
  alias Handbean.Repo
  alias Handbean.Storage.{Conversation, ConversationEntry, ConversationRun, WriteTransaction}

  @envelope_keys ~w(id conversation_id sequence revision role content_type message_type direction phase status run_id turn_number tool_call_id tool_status content created_at updated_at)
  @entry_fields [
    :conversation_id,
    :entry_id,
    :sequence,
    :revision,
    :role,
    :content_type,
    :message_type,
    :direction,
    :phase,
    :status,
    :run_id,
    :turn_number,
    :tool_call_id,
    :tool_status,
    :content,
    :payload,
    :created_at,
    :updated_at
  ]

  @impl true
  def list(conversation_id, opts) do
    with :ok <- authorize_read(conversation_id, opts) do
      entries =
        ConversationEntry
        |> where([entry], entry.conversation_id == ^conversation_id)
        |> order_by([entry], asc: entry.sequence)
        |> Repo.all()
        |> Enum.map(&public_entry/1)

      {:ok, entries}
    end
  end

  @impl true
  def page(conversation_id, opts) do
    with :ok <- authorize_read(conversation_id, opts) do
      cond do
        Keyword.has_key?(opts, :around) -> around_page(conversation_id, opts)
        Keyword.has_key?(opts, :after) -> after_page(conversation_id, opts)
        true -> before_page(conversation_id, opts)
      end
    end
  end

  defp before_page(conversation_id, opts) do
    with {:ok, limit} <- page_limit(opts),
         {:ok, before_sequence} <- before_sequence(conversation_id, Keyword.get(opts, :before)) do
      query =
        from entry in ConversationEntry,
          where: entry.conversation_id == ^conversation_id,
          order_by: [desc: entry.sequence],
          limit: ^(limit + 1)

      query =
        if is_integer(before_sequence),
          do: where(query, [entry], entry.sequence < ^before_sequence),
          else: query

      rows = Repo.all(query)
      has_more? = length(rows) > limit
      entries = rows |> Enum.take(limit) |> Enum.reverse() |> Enum.map(&public_entry/1)
      before = if has_more?, do: entries |> hd() |> Map.fetch!("id"), else: nil
      {:ok, %{entries: entries, before: before, has_more?: has_more?}}
    end
  end

  defp after_page(conversation_id, opts) do
    with {:ok, limit} <- page_limit(opts),
         {:ok, after_sequence} <- cursor_sequence(conversation_id, Keyword.get(opts, :after)) do
      rows =
        from(entry in ConversationEntry,
          where: entry.conversation_id == ^conversation_id and entry.sequence > ^after_sequence,
          order_by: [asc: entry.sequence],
          limit: ^(limit + 1)
        )
        |> Repo.all()

      has_more? = length(rows) > limit
      entries = rows |> Enum.take(limit) |> Enum.map(&public_entry/1)

      after_cursor =
        case List.last(entries) do
          %{} = entry -> Map.fetch!(entry, "id")
          nil -> Keyword.get(opts, :after)
        end

      {:ok, %{entries: entries, after: after_cursor, has_more?: has_more?}}
    end
  end

  defp around_page(conversation_id, opts) do
    with anchor_id when is_binary(anchor_id) <- Keyword.get(opts, :around),
         {:ok, before_limit} <- bounded_page_limit(opts, :before_limit, 50),
         {:ok, after_limit} <- bounded_page_limit(opts, :after_limit, 50) do
      Repo.transaction(fn ->
        anchor =
          Repo.one(
            from entry in ConversationEntry,
              where: entry.conversation_id == ^conversation_id and entry.entry_id == ^anchor_id
          )

        if is_nil(anchor), do: Repo.rollback(:entry_unavailable)
        anchor_sequence = anchor.sequence

        older =
          from(entry in ConversationEntry,
            where:
              entry.conversation_id == ^conversation_id and entry.sequence < ^anchor_sequence,
            order_by: [desc: entry.sequence],
            limit: ^(before_limit + 1)
          )
          |> Repo.all()

        newer =
          from(entry in ConversationEntry,
            where:
              entry.conversation_id == ^conversation_id and entry.sequence > ^anchor_sequence,
            order_by: [asc: entry.sequence],
            limit: ^(after_limit + 1)
          )
          |> Repo.all()

        has_more_before? = length(older) > before_limit
        has_more_after? = length(newer) > after_limit
        older = older |> Enum.take(before_limit) |> Enum.reverse()
        newer = Enum.take(newer, after_limit)
        rows = older ++ [anchor] ++ newer
        entries = Enum.map(rows, &public_entry/1)

        %{
          entries: entries,
          anchor: anchor.entry_id,
          before: if(has_more_before?, do: hd(entries)["id"]),
          after: entries |> List.last() |> Map.fetch!("id"),
          has_more_before?: has_more_before?,
          has_more_after?: has_more_after?
        }
      end)
    else
      nil -> {:error, :entry_unavailable}
      error -> error
    end
  end

  @impl true
  def append(conversation_id, entry, _opts) do
    entry = stringify_keys(entry)

    fn -> insert_entry(conversation_id, entry) end
    |> WriteTransaction.run()
    |> append_result(conversation_id)
  end

  @doc false
  def append_with_receipt(conversation_id, entry, request_id, receipt, _opts) do
    entry = stringify_keys(entry)

    WriteTransaction.run(fn ->
      persisted = insert_entry(conversation_id, entry)

      case Handbean.Agent.OperationReceipt.complete(
             {:message, conversation_id},
             request_id,
             receipt
           ) do
        :ok -> persisted
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> append_result(conversation_id)
  end

  defp append_result(result, conversation_id) do
    case result do
      {:ok, persisted} ->
        if persisted["role"] == "user" and not Repo.in_transaction?(),
          do: Handbean.ConversationStore.broadcast_title_updated(conversation_id)

        {:ok, persisted}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :duplicate_id} ->
        {:error, :duplicate_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def append_many(conversation_id, entries, _opts) when is_list(entries) do
    entries = Enum.map(entries, &stringify_keys/1)

    WriteTransaction.run(fn ->
      Enum.map(entries, &insert_entry(conversation_id, &1))
    end)
    |> case do
      {:ok, persisted} ->
        if Enum.any?(persisted, &(&1["role"] == "user")) and not Repo.in_transaction?(),
          do: Handbean.ConversationStore.broadcast_title_updated(conversation_id)

        {:ok, persisted}

      {:error, reason} ->
        {:error, normalize_constraint(reason)}
    end
  rescue
    error in Ecto.ConstraintError -> {:error, normalize_constraint(error)}
  end

  def append_many(_conversation_id, _entries, _opts), do: {:error, :invalid_entry}

  @impl true
  def complete_tool_call(conversation_id, tool_entry, media_entry, media_ids, _opts)
      when is_binary(conversation_id) and is_map(tool_entry) and is_list(media_ids) do
    WriteTransaction.run(fn ->
      with {:ok, saved_tool} <- upsert_entry_in_tx(conversation_id, stringify_keys(tool_entry)),
           {:ok, saved_media} <-
             complete_media_in_tx(conversation_id, saved_tool, media_entry, media_ids) do
        %{tool_entry: saved_tool, media_entry: saved_media}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, normalize_constraint(reason)}
    end
  rescue
    error in Ecto.ConstraintError -> {:error, normalize_constraint(error)}
  end

  defp complete_media_in_tx(_conversation_id, _tool_entry, nil, []), do: {:ok, nil}

  defp complete_media_in_tx(conversation_id, tool_entry, media_entry, media_ids)
       when is_map(media_entry) and media_ids != [] do
    attachments = Handbean.Media.project(media_entry["attachments"] || media_entry[:attachments])
    projected_ids = Handbean.Media.ids(attachments)
    tool_use_id = tool_entry["tool_use_id"]
    media_entry = media_entry |> stringify_keys() |> Map.put("attachments", attachments)
    media_entry_id = media_entry["id"]

    cond do
      tool_entry["tool_status"] != "done" ->
        {:error, :media_tool_not_succeeded}

      projected_ids != media_ids ->
        {:error, :media_descriptor_mismatch}

      not is_binary(tool_use_id) or not is_binary(media_entry_id) ->
        {:error, :invalid_media_entry}

      true ->
        with {:ok, _ready} <-
               Handbean.Media.mark_ready_in_tx(
                 conversation_id,
                 tool_use_id,
                 media_entry_id,
                 media_ids
               ),
             {:ok, saved_media} <- upsert_entry_in_tx(conversation_id, media_entry) do
          {:ok, saved_media}
        end
    end
  end

  defp complete_media_in_tx(_conversation_id, _tool_entry, _media_entry, _media_ids),
    do: {:error, :invalid_media_completion}

  defp upsert_entry_in_tx(conversation_id, %{"id" => id} = entry) do
    case update_cas(conversation_id, id, entry, 32) do
      {:ok, updated} -> {:ok, updated}
      {:error, :not_found} -> {:ok, insert_entry(conversation_id, entry)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_entry_in_tx(_conversation_id, _entry), do: {:error, :invalid_entry}

  defp insert_entry(conversation_id, entry) do
    sequence = allocate_sequence(conversation_id)
    normalized = normalize_entry(conversation_id, entry, sequence)

    normalized
    |> entry_attrs()
    |> insert_entry!()
    |> public_entry()
    |> tap(fn persisted ->
      if persisted["role"] == "user" do
        Repo.update_all(
          from(conversation in Conversation, where: conversation.id == ^conversation_id),
          set: [updated_at: now()]
        )
      end
    end)
  end

  @impl true
  def update(conversation_id, entry_id, patch, _opts) do
    patch = stringify_keys(patch)

    case patch do
      %{"content" => %{"$append" => delta}} when is_binary(delta) and map_size(patch) <= 2 ->
        atomic_append_content_entry(conversation_id, entry_id, delta, Map.get(patch, "status"))

      _ ->
        update_cas(conversation_id, entry_id, patch, 32)
    end
  end

  @impl true
  def append_content(conversation_id, entry_id, delta, status, _opts)
      when is_binary(delta) do
    atomic_append_content(conversation_id, entry_id, delta, status)
  end

  @impl true
  def consume(conversation_id, ids, patch, _opts)
      when is_binary(conversation_id) and is_list(ids) and is_map(patch) do
    if ids == [] do
      :ok
    else
      patch = stringify_keys(patch)

      if Handbean.ConversationStore.exists?(conversation_id) do
        WriteTransaction.run(fn ->
          Enum.each(ids, fn id ->
            case consume_cas(conversation_id, id, patch, 32) do
              :ok -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

          :ok
        end)
        |> case do
          {:ok, :ok} -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, :not_found}
      end
    end
  end

  @impl true
  def delete(conversation_id, entry_id, _opts) do
    if Handbean.ConversationStore.exists?(conversation_id) do
      Repo.delete_all(
        from entry in ConversationEntry,
          where: entry.conversation_id == ^conversation_id and entry.entry_id == ^entry_id
      )

      :ok
    else
      {:error, :not_found}
    end
  end

  @impl true
  def replace_all(conversation_id, entries, _opts) do
    if Handbean.ConversationStore.exists?(conversation_id) do
      WriteTransaction.run(fn ->
        Repo.delete_all(
          from entry in ConversationEntry, where: entry.conversation_id == ^conversation_id
        )

        timestamp = now()

        rows =
          entries
          |> Enum.with_index(1)
          |> Enum.map(fn {entry, sequence} ->
            conversation_id
            |> normalize_entry(stringify_keys(entry), sequence, timestamp)
            |> entry_attrs()
          end)

        if duplicate_entry_ids?(rows), do: Repo.rollback(:duplicate_id)

        rows
        |> Enum.chunk_every(100)
        |> Enum.each(fn chunk -> Repo.insert_all(ConversationEntry, chunk) end)

        Repo.update_all(
          from(conversation in Conversation, where: conversation.id == ^conversation_id),
          set: [next_entry_sequence: length(rows) + 1]
        )

        :ok
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, normalize_constraint(reason)}
      end
    else
      {:error, :not_found}
    end
  rescue
    error in Ecto.ConstraintError -> {:error, normalize_constraint(error)}
  end

  @doc false
  def unfinished_runs do
    assistant_runs =
      from(entry in ConversationEntry,
        where:
          entry.role == "assistant" and entry.status == "streaming" and
            fragment("coalesce(json_extract(?, '$.direct_command'), 0) != 1", entry.payload),
        select: {entry.conversation_id, entry.run_id},
        distinct: true
      )
      |> Repo.all()

    tool_runs =
      from(entry in ConversationEntry,
        where:
          entry.content_type == "tool" and entry.tool_status == "running" and
            fragment("coalesce(json_extract(?, '$.direct_command'), 0) != 1", entry.payload),
        select: {entry.conversation_id, entry.run_id},
        distinct: true
      )
      |> Repo.all()

    lifecycle_runs =
      from(run in ConversationRun,
        where: run.status in ["running", "interrupted"],
        select: {run.conversation_id, run.run_id}
      )
      |> Repo.all()

    Enum.uniq(assistant_runs ++ tool_runs ++ lifecycle_runs)
  end

  @doc false
  def unfinished_runs(conversation_id) do
    entry_runs =
      from(entry in ConversationEntry,
        where:
          entry.conversation_id == ^conversation_id and
            (((entry.role == "assistant" and entry.status == "streaming") or
                (entry.content_type == "tool" and entry.tool_status == "running")) and
               fragment("coalesce(json_extract(?, '$.direct_command'), 0) != 1", entry.payload)),
        group_by: entry.run_id,
        select: entry.run_id
      )
      |> Repo.all()

    lifecycle_runs =
      from(run in ConversationRun,
        where:
          run.conversation_id == ^conversation_id and
            run.status in ["running", "interrupted"],
        select: run.run_id
      )
      |> Repo.all()

    Enum.uniq(entry_runs ++ lifecycle_runs)
  end

  @impl true
  def interrupt_workspace_commands(error, _opts) when is_binary(error) do
    WriteTransaction.run(fn ->
      rows =
        ConversationEntry
        |> where(
          [entry],
          entry.content_type == "tool" and entry.tool_status == "running" and
            fragment("json_extract(?, '$.direct_command') = 1", entry.payload)
        )
        |> Repo.all()

      completed_at = iso8601(now())

      Enum.each(rows, fn row ->
        case update_cas(
               row.conversation_id,
               row.entry_id,
               %{
                 "tool_status" => "error",
                 "tool_error" => error,
                 "consumption" => "pending",
                 "agent_response_status" => "pending",
                 "completed_at" => completed_at
               },
               32
             ) do
          {:ok, _entry} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

      rows |> Enum.map(& &1.conversation_id) |> Enum.uniq()
    end)
    |> case do
      {:ok, conversation_ids} -> {:ok, conversation_ids}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def pending_workspace_command_responses(_opts) do
    rows =
      from(entry in ConversationEntry,
        join: conversation in Conversation,
        on: conversation.id == entry.conversation_id,
        where:
          conversation.status == "active" and conversation.visibility == "user" and
            entry.content_type == "tool" and entry.tool_status in ["done", "error"] and
            fragment("json_extract(?, '$.direct_command') = 1", entry.payload) and
            fragment("json_extract(?, '$.consumption') != 'consumed'", entry.payload) and
            fragment(
              "json_extract(?, '$.agent_response_status') IN ('pending', 'accepted')",
              entry.payload
            ),
        order_by: [asc: entry.sequence],
        select: {entry.conversation_id, entry}
      )
      |> Repo.all()
      |> Enum.map(fn {conversation_id, entry} -> {conversation_id, public_entry(entry)} end)

    {:ok, rows}
  rescue
    error -> {:error, error}
  end

  @impl true
  def claim_workspace_command_response(conversation_id, entry_id, attempt_id, _opts) do
    patch = %{
      "agent_response_request_id" => attempt_id,
      "agent_response_status" => "pending",
      "agent_response_error" => nil
    }

    claim_workspace_command_response_cas(conversation_id, entry_id, patch, 32)
  end

  @doc false
  def cancel_running_tools(conversation_id, run_id, _opts) do
    if Handbean.ConversationStore.exists?(conversation_id) do
      settle_tools(conversation_id, run_id, "cancelled", nil)
      :ok
    else
      {:error, :not_found}
    end
  end

  @doc false
  def settle_run(conversation_id, run_id, status, error, opts) do
    if Handbean.ConversationStore.exists?(conversation_id) do
      WriteTransaction.run(fn ->
        with :ok <- settle_tools(conversation_id, run_id, status, error),
             :ok <- settle_assistants(conversation_id, run_id, status, error),
             :ok <- record_terminal_usage(conversation_id, run_id, opts[:terminal_usage]) do
          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_found}
    end
  end

  defp record_terminal_usage(_conversation_id, _run_id, nil), do: :ok

  defp record_terminal_usage(conversation_id, run_id, usage)
       when is_binary(run_id) and run_id != "" and is_map(usage) do
    Handbean.ConversationStore.record_run_usage(conversation_id, run_id, usage)
  end

  defp record_terminal_usage(_conversation_id, _run_id, _usage), do: :ok

  defp consume_cas(_conversation_id, _entry_id, _patch, 0), do: {:error, :conflict}

  defp consume_cas(conversation_id, entry_id, patch, attempts)
       when is_binary(entry_id) and entry_id != "" do
    case Repo.one(
           from entry in ConversationEntry,
             where: entry.conversation_id == ^conversation_id and entry.entry_id == ^entry_id
         ) do
      nil ->
        {:error, :not_found}

      row ->
        sequence = allocate_sequence(conversation_id)

        merged =
          row
          |> public_entry()
          |> deep_merge(patch)
          |> Map.put("sequence", sequence)
          |> Map.put("updated_at", iso8601(now()))

        attrs = entry_attrs(merged)

        query =
          from entry in ConversationEntry,
            where: entry.id == ^row.id and entry.revision == ^row.revision

        changes =
          attrs
          |> Map.drop([:conversation_id, :entry_id, :created_at])
          |> Map.put(:revision, row.revision + 1)

        case Repo.update_all(query, set: Map.to_list(changes)) do
          {1, _} -> :ok
          {0, _} -> consume_cas(conversation_id, entry_id, patch, attempts - 1)
        end
    end
  end

  defp consume_cas(_conversation_id, _entry_id, _patch, _attempts),
    do: {:error, :invalid_entry_id}

  defp claim_workspace_command_response_cas(_conversation_id, _entry_id, _patch, 0),
    do: {:error, :conflict}

  defp claim_workspace_command_response_cas(conversation_id, entry_id, patch, attempts) do
    case Repo.one(
           from entry in ConversationEntry,
             where: entry.conversation_id == ^conversation_id and entry.entry_id == ^entry_id
         ) do
      nil ->
        {:error, :not_found}

      row ->
        current = public_entry(row)

        cond do
          current["consumption"] == "consumed" ->
            {:error, :already_consumed}

          current["direct_command"] != true ->
            {:error, :invalid_entry}

          true ->
            merged =
              current
              |> deep_merge(patch)
              |> Map.put("updated_at", iso8601(now()))

            attrs = entry_attrs(merged)

            query =
              from entry in ConversationEntry,
                where: entry.id == ^row.id and entry.revision == ^row.revision

            changes =
              attrs
              |> Map.drop([:conversation_id, :entry_id, :sequence, :created_at])
              |> Map.put(:revision, row.revision + 1)

            case Repo.update_all(query, set: Map.to_list(changes)) do
              {1, _} ->
                updated = Repo.get!(ConversationEntry, row.id)
                {:ok, public_entry(updated)}

              {0, _} ->
                claim_workspace_command_response_cas(
                  conversation_id,
                  entry_id,
                  patch,
                  attempts - 1
                )
            end
        end
    end
  end

  defp update_cas(_conversation_id, _entry_id, _patch, 0), do: {:error, :conflict}

  defp update_cas(conversation_id, entry_id, patch, attempts) do
    case Repo.one(
           from entry in ConversationEntry,
             where: entry.conversation_id == ^conversation_id and entry.entry_id == ^entry_id
         ) do
      nil ->
        if Handbean.ConversationStore.exists?(conversation_id),
          do: {:error, :not_found},
          else: {:error, :not_found}

      row ->
        merged =
          row |> public_entry() |> deep_merge(patch) |> Map.put("updated_at", iso8601(now()))

        attrs = entry_attrs(merged)

        query =
          from entry in ConversationEntry,
            where: entry.id == ^row.id and entry.revision == ^row.revision

        changes =
          attrs
          |> Map.drop([:conversation_id, :entry_id, :sequence, :created_at])
          |> Map.put(:revision, row.revision + 1)

        case Repo.update_all(query, set: Map.to_list(changes)) do
          {1, _} ->
            updated = Repo.get!(ConversationEntry, row.id)
            {:ok, public_entry(updated)}

          {0, _} ->
            update_cas(conversation_id, entry_id, patch, attempts - 1)
        end
    end
  end

  defp allocate_sequence(conversation_id) do
    sql = """
    UPDATE conversations
    SET next_entry_sequence = next_entry_sequence + 1
    WHERE id = ? AND status = 'active'
    RETURNING next_entry_sequence - 1
    """

    case Repo.query(sql, [conversation_id]) do
      {:ok, %{rows: [[sequence]]}} -> sequence
      {:ok, %{rows: []}} -> Repo.rollback(:not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp atomic_append_content(conversation_id, entry_id, delta, nil) do
    atomic_append_content_query(
      """
      UPDATE conversation_entries
      SET content = COALESCE(content, '') || ?, revision = revision + 1, updated_at = ?
      WHERE conversation_id = ? AND entry_id = ?
      RETURNING entry_id, length(CAST(content AS BLOB))
      """,
      [delta, now_naive(), conversation_id, entry_id]
    )
  end

  defp atomic_append_content(conversation_id, entry_id, delta, status) do
    atomic_append_content_query(
      """
      UPDATE conversation_entries
      SET content = COALESCE(content, '') || ?, status = ?, revision = revision + 1,
          updated_at = ?
      WHERE conversation_id = ? AND entry_id = ?
      RETURNING entry_id, length(CAST(content AS BLOB))
      """,
      [delta, status, now_naive(), conversation_id, entry_id]
    )
  end

  defp atomic_append_content_entry(conversation_id, entry_id, delta, status) do
    with {:ok, _summary} <- atomic_append_content(conversation_id, entry_id, delta, status) do
      case Repo.one(
             from entry in ConversationEntry,
               where: entry.conversation_id == ^conversation_id and entry.entry_id == ^entry_id
           ) do
        nil -> {:error, :not_found}
        row -> {:ok, public_entry(row)}
      end
    end
  end

  defp atomic_append_content_query(sql, params) do
    case Repo.query(sql, params) do
      {:ok, %{rows: [[id, text_bytes]]}} -> {:ok, %{id: id, text_bytes: text_bytes}}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp settle_tools(conversation_id, run_id, status, error) do
    sql = """
    UPDATE conversation_entries
    SET tool_status = ?, payload = json_set(payload, '$.tool_error', json(?)),
        revision = revision + 1, updated_at = ?
    WHERE conversation_id = ? AND run_id IS ? AND content_type = 'tool' AND tool_status = 'running'
      AND coalesce(json_extract(payload, '$.direct_command'), 0) != 1
    """

    case Repo.query(sql, [
           status,
           Handbean.JSON.encode!(error),
           now_naive(),
           conversation_id,
           run_id
         ]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp settle_assistants(conversation_id, run_id, status, error) do
    sql = """
    UPDATE conversation_entries
    SET status = ?, phase = CASE WHEN phase IN ('commentary', 'final_answer') THEN phase ELSE 'final' END,
        payload = json_set(payload, '$.error', json(?)), revision = revision + 1, updated_at = ?
    WHERE conversation_id = ? AND run_id IS ? AND role = 'assistant' AND status = 'streaming'
    """

    case Repo.query(sql, [
           status,
           Handbean.JSON.encode!(error),
           now_naive(),
           conversation_id,
           run_id
         ]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_entry!(attrs) do
    %ConversationEntry{}
    |> Changeset.cast(attrs, @entry_fields)
    |> Repo.insert!()
  rescue
    error in Ecto.ConstraintError ->
      if error.constraint == "conversation_entries_conversation_id_entry_id_index" do
        Repo.rollback(:duplicate_id)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp normalize_entry(conversation_id, entry, sequence, timestamp \\ now()) do
    entry
    |> Map.put_new("id", "msg-#{Ecto.UUID.generate()}")
    |> Map.put("conversation_id", conversation_id)
    |> Map.put("sequence", sequence)
    |> Map.put_new("revision", 1)
    |> Map.put_new("created_at", iso8601(timestamp))
    |> Map.put("updated_at", normalize_timestamp(entry["updated_at"], timestamp))
  end

  defp entry_attrs(entry) do
    content = entry["content"]

    payload =
      entry
      |> Map.drop(@envelope_keys)
      |> maybe_put_content_payload(content)
      |> Handbean.JsonSafe.normalize()
      |> restore_json_nulls()

    %{
      conversation_id: entry["conversation_id"],
      entry_id: entry["id"],
      sequence: entry["sequence"],
      revision: entry["revision"] || 1,
      role: string_or_nil(entry["role"]),
      content_type: string_or_nil(entry["content_type"]),
      message_type: string_or_nil(entry["message_type"]),
      direction: string_or_nil(entry["direction"]),
      phase: string_or_nil(entry["phase"]),
      status: string_or_nil(entry["status"]),
      run_id: string_or_nil(entry["run_id"]),
      turn_number: integer_or_nil(entry["turn_number"]),
      tool_call_id: string_or_nil(entry["tool_call_id"]),
      tool_status: string_or_nil(entry["tool_status"]),
      content: if(is_binary(content), do: content),
      payload: payload,
      created_at: parse_time(entry["created_at"]) || now(),
      updated_at: parse_time(entry["updated_at"]) || now()
    }
  end

  @doc false
  def public_entry(row) do
    envelope = %{
      "id" => row.entry_id,
      "conversation_id" => row.conversation_id,
      "sequence" => row.sequence,
      "revision" => row.revision,
      "role" => row.role,
      "content_type" => row.content_type,
      "message_type" => row.message_type,
      "direction" => row.direction,
      "phase" => row.phase,
      "status" => row.status,
      "run_id" => row.run_id,
      "turn_number" => row.turn_number,
      "tool_call_id" => row.tool_call_id,
      "tool_status" => row.tool_status,
      "content" => content_value(row),
      "created_at" => iso8601(row.created_at),
      "updated_at" => iso8601(row.updated_at)
    }

    envelope = Map.reject(envelope, fn {_key, value} -> is_nil(value) end)
    Map.merge(row.payload || %{}, envelope)
  end

  defp content_value(%{content: content}) when is_binary(content), do: content
  defp content_value(%{payload: %{"__content" => content}}), do: content
  defp content_value(_row), do: nil

  defp maybe_put_content_payload(payload, content) when is_binary(content) or is_nil(content),
    do: Map.delete(payload, "__content")

  defp maybe_put_content_payload(payload, content), do: Map.put(payload, "__content", content)

  defp authorize_read(conversation_id, opts) do
    with {:ok, summary} <- Handbean.ConversationStore.get_summary(conversation_id) do
      if Handbean.ConversationStore.internal?(summary) and
           not runtime_reader?(conversation_id, opts) and
           not trusted_runtime_reader?() do
        Handbean.ConversationStore.authorize_read(conversation_id, opts)
      else
        :ok
      end
    end
  end

  defp trusted_runtime_reader? do
    self() in [
      Process.whereis(Handbean.Agent.Delegation),
      Process.whereis(Handbean.Agent.TranscriptRecovery)
    ]
  end

  defp runtime_reader?(id, opts) do
    caller = self()
    run_id = opts[:run_id]
    runner_pid = opts[:runner_pid]

    is_binary(run_id) and
      (registered_runner?(id, run_id, runner_pid, caller) or
         Handbean.Agent.Runner.owns_run_task?(id, run_id, runner_pid, caller))
  end

  defp registered_runner?(id, run_id, runner_pid, caller) do
    runner_pid == caller and
      match?([{^caller, %{run_id: ^run_id}}], Registry.lookup(Handbean.AgentRunRegistry, id))
  end

  defp before_sequence(_conversation_id, nil), do: {:ok, nil}

  defp before_sequence(conversation_id, cursor) when is_binary(cursor) do
    case Repo.one(
           from entry in ConversationEntry,
             where: entry.conversation_id == ^conversation_id and entry.entry_id == ^cursor,
             select: entry.sequence
         ) do
      nil -> {:error, :invalid_cursor}
      sequence -> {:ok, sequence}
    end
  end

  defp before_sequence(_conversation_id, _cursor), do: {:error, :invalid_cursor}

  defp cursor_sequence(conversation_id, cursor) when is_binary(cursor) do
    case before_sequence(conversation_id, cursor) do
      {:ok, sequence} when is_integer(sequence) -> {:ok, sequence}
      _error -> {:error, :invalid_cursor}
    end
  end

  defp cursor_sequence(_conversation_id, _cursor), do: {:error, :invalid_cursor}

  defp bounded_page_limit(opts, key, default) do
    case Keyword.get(opts, key, default) do
      limit when is_integer(limit) and limit >= 0 and limit <= 100 -> {:ok, limit}
      _value -> {:error, :invalid_limit}
    end
  end

  defp duplicate_entry_ids?(rows) do
    ids = Enum.map(rows, & &1.entry_id)
    length(ids) != MapSet.size(MapSet.new(ids))
  end

  defp page_limit(opts) do
    case Keyword.get(opts, :limit, 100) do
      limit when is_integer(limit) -> {:ok, min(max(limit, 1), 200)}
      _ -> {:error, :invalid_limit}
    end
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      cond do
        (is_binary(left_value) or is_nil(left_value)) and is_map(right_value) and
            is_binary(right_value["$append"]) ->
          (left_value || "") <> right_value["$append"]

        is_map(left_value) and is_map(right_value) ->
          deep_merge(left_value, right_value)

        true ->
          right_value
      end
    end)
  end

  defp stringify_keys(%{__struct__: _} = struct),
    do: struct |> Map.from_struct() |> stringify_keys()

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp restore_json_nulls(:null), do: nil

  defp restore_json_nulls(value) when is_list(value),
    do: Enum.map(value, &restore_json_nulls/1)

  defp restore_json_nulls(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, restore_json_nulls(nested)} end)
  end

  defp restore_json_nulls(value), do: value

  defp string_or_nil(nil), do: nil
  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(value), do: to_string(value)

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp normalize_timestamp(value, fallback),
    do: value |> parse_time() |> then(&iso8601(&1 || fallback))

  defp parse_time(nil), do: nil
  defp parse_time(%DateTime{} = value), do: microsecond_precision(value)

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> microsecond_precision(timestamp)
      _ -> nil
    end
  end

  defp microsecond_precision(%DateTime{microsecond: {microsecond, _precision}} = value),
    do: %{value | microsecond: {microsecond, 6}}

  defp iso8601(%DateTime{microsecond: {0, _precision}} = value),
    do: value |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp iso8601(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp now_naive,
    do: DateTime.utc_now() |> DateTime.to_naive() |> NaiveDateTime.truncate(:microsecond)

  defp normalize_constraint(%Ecto.ConstraintError{constraint: constraint}) do
    if constraint in [
         "conversation_entries_conversation_id_entry_id_index",
         "conversation_entries_conversation_id_sequence_index"
       ],
       do: :duplicate_id,
       else: {:constraint, constraint}
  end

  defp normalize_constraint(reason), do: reason
end
