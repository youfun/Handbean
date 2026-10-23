defmodule Handbean.ConversationStore.Trajectory do
  @moduledoc false

  import Ecto.Query

  alias Handbean.Repo

  alias Handbean.Storage.{
    Conversation,
    ConversationEntry,
    ConversationPermissionChange,
    ConversationRun,
    ConversationTurn
  }

  @capture_version 1
  @max_runs 100
  @max_turns 200

  def list_conversation_summaries(workspace_id) when is_binary(workspace_id) do
    workspace_conversations =
      from conversation in Conversation,
        where:
          conversation.status == "active" and conversation.scope == "workspace" and
            conversation.workspace_id == ^workspace_id and
            conversation.visibility not in ["internal", "task"],
        select: conversation.id

    entry_stats =
      from entry in ConversationEntry,
        where: entry.conversation_id in subquery(workspace_conversations),
        group_by: entry.conversation_id,
        select: %{
          conversation_id: entry.conversation_id,
          message_count:
            fragment(
              "SUM(CASE WHEN ? IN ('user', 'assistant') THEN 1 ELSE 0 END)",
              entry.role
            ),
          tool_call_count:
            fragment(
              "SUM(CASE WHEN ? = 'tool' OR ? = 'tool' THEN 1 ELSE 0 END)",
              entry.role,
              entry.content_type
            )
        }

    entry_runs =
      from entry in ConversationEntry,
        where:
          entry.conversation_id in subquery(workspace_conversations) and
            not is_nil(entry.run_id),
        select: %{conversation_id: entry.conversation_id, run_id: entry.run_id}

    captured_runs =
      from run in ConversationRun,
        where: run.conversation_id in subquery(workspace_conversations),
        select: %{conversation_id: run.conversation_id, run_id: run.run_id}

    all_runs = union(entry_runs, ^captured_runs)

    run_stats =
      from run in subquery(all_runs),
        group_by: run.conversation_id,
        select: %{conversation_id: run.conversation_id, run_count: count(run.run_id)}

    from(conversation in Conversation,
      left_join: entry_stats in subquery(entry_stats),
      on: entry_stats.conversation_id == conversation.id,
      left_join: run_stats in subquery(run_stats),
      on: run_stats.conversation_id == conversation.id,
      where: conversation.id in subquery(workspace_conversations),
      order_by: [desc: conversation.updated_at, desc: conversation.id],
      select: {
        conversation,
        entry_stats.message_count,
        entry_stats.tool_call_count,
        run_stats.run_count
      }
    )
    |> Repo.all()
    |> Enum.map(fn {conversation, messages, tools, runs} ->
      %{
        "id" => conversation.id,
        "title" => conversation.title,
        "model" => conversation.selected_model,
        "created_at" => iso8601(conversation.created_at),
        "updated_at" => iso8601(conversation.updated_at),
        "archived_at" => iso8601(conversation.archived_at),
        "message_count" => messages || 0,
        "run_count" => runs || 0,
        "tool_call_count" => tools || 0,
        "last_run_result" => conversation.last_run_result
      }
    end)
  end

  def record_run_start(conversation_id, attrs)
      when is_binary(conversation_id) and is_map(attrs) do
    with {:ok, run_id} <- required_string(value(attrs, :run_id)) do
      code_baseline = normalize_code_baseline(value(attrs, :code_baseline))

      result =
        Repo.transaction(
          fn ->
            timestamp = now()
            delegated_approval = value(attrs, :delegated_approval)

            permission =
              Handbean.Permissions.ConversationMode.runtime(conversation_id, delegated_approval)

            row = %{
              conversation_id: conversation_id,
              run_id: run_id,
              status: "running",
              stop_reason: nil,
              loop_owner: optional_string(value(attrs, :loop_owner) || "handbean"),
              backend: optional_string(value(attrs, :backend)),
              model: optional_string(value(attrs, :model)),
              initial_permission_mode: to_string(permission.permission_mode),
              initial_permission_revision: permission.permission_revision,
              initial_approval_mode: to_string(permission.approval_mode),
              initial_approvals_reviewer: to_string(permission.reviewer),
              permission_source: optional_string(value(attrs, :permission_source)),
              delegated_approval: optional_string(delegated_approval),
              current_permission_mode: to_string(permission.permission_mode),
              current_permission_revision: permission.permission_revision,
              permission_changed_at: nil,
              error: nil,
              turn_count: 0,
              duration_ms: nil,
              code_baseline: code_baseline,
              capture_version: @capture_version,
              started_at: timestamp,
              completed_at: nil,
              created_at: timestamp,
              updated_at: timestamp
            }

            conflict =
              row
              |> Map.take([
                :loop_owner,
                :backend,
                :model,
                :capture_version,
                :updated_at
              ])
              |> Enum.to_list()

            with :ok <- insert(ConversationRun, row, conflict, [:conversation_id, :run_id]),
                 :ok <- fill_code_baseline(conversation_id, run_id, code_baseline) do
              :ok
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end,
          mode: :immediate
        )

      with {:ok, :ok} <- result,
           :ok <- Handbean.Permissions.ConversationMode.observe_run(conversation_id, run_id) do
        :ok
      end
    end
  end

  def record_run_start(_conversation_id, _attrs), do: {:error, :invalid_run}

  def record_run_end(conversation_id, attrs)
      when is_binary(conversation_id) and is_map(attrs) do
    with {:ok, run_id} <- required_string(value(attrs, :run_id)) do
      timestamp = now()
      status = optional_string(value(attrs, :status)) || "completed"
      completed_at = if status in ["running", "interrupted"], do: nil, else: timestamp
      code_baseline = normalize_code_baseline(value(attrs, :code_baseline))

      duration_ms =
        non_negative_integer(value(attrs, :duration_ms), nil) ||
          elapsed_ms(ConversationRun, conversation_id, run_id, timestamp)

      row = %{
        conversation_id: conversation_id,
        run_id: run_id,
        status: status,
        stop_reason: optional_string(value(attrs, :stop_reason)),
        loop_owner: optional_string(value(attrs, :loop_owner) || "handbean"),
        backend: optional_string(value(attrs, :backend)),
        model: optional_string(value(attrs, :model)),
        error: bounded_error(value(attrs, :error)),
        turn_count: non_negative_integer(value(attrs, :turns), 0),
        duration_ms: duration_ms,
        code_baseline: code_baseline,
        capture_version: @capture_version,
        started_at: nil,
        completed_at: completed_at,
        created_at: timestamp,
        updated_at: timestamp
      }

      conflict =
        row
        |> Map.take([
          :status,
          :stop_reason,
          :loop_owner,
          :backend,
          :model,
          :error,
          :turn_count,
          :duration_ms,
          :capture_version,
          :completed_at,
          :updated_at
        ])
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      Repo.transaction(
        fn ->
          with :ok <-
                 Handbean.Permissions.ConversationMode.settle_run_end(
                   conversation_id,
                   run_id,
                   value(attrs, :orphan_recovery?) == true
                 ),
               :ok <- insert(ConversationRun, row, conflict, [:conversation_id, :run_id]),
               :ok <- fill_code_baseline(conversation_id, run_id, code_baseline),
               :ok <- settle_open_turns(conversation_id, run_id, status, timestamp) do
            Repo.update_all(
              from(conversation in Conversation, where: conversation.id == ^conversation_id),
              set: [last_run_result: status]
            )

            :ok
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end,
        mode: :immediate
      )
      |> case do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def record_run_end(_conversation_id, _attrs), do: {:error, :invalid_run}

  def record_turn_start(conversation_id, attrs)
      when is_binary(conversation_id) and is_map(attrs) do
    with {:ok, run_id} <- required_string(value(attrs, :run_id)),
         {:ok, turn_number} <- positive_integer(value(attrs, :turn_number)) do
      timestamp = now()

      row = %{
        conversation_id: conversation_id,
        run_id: run_id,
        turn_number: turn_number,
        status: "running",
        stop_reason: nil,
        duration_ms: nil,
        provider: optional_string(value(attrs, :provider)),
        model: optional_string(value(attrs, :model)),
        reasoning_level: optional_string(value(attrs, :reasoning_level)),
        config_revision: non_negative_integer(value(attrs, :config_revision), 0),
        started_at: timestamp,
        completed_at: nil,
        created_at: timestamp,
        updated_at: timestamp
      }

      conflict = row |> Map.take([:updated_at]) |> Map.to_list()

      insert(ConversationTurn, row, conflict, [:conversation_id, :run_id, :turn_number])
    end
  end

  def record_turn_start(_conversation_id, _attrs), do: {:error, :invalid_turn}

  def record_turn_end(conversation_id, attrs)
      when is_binary(conversation_id) and is_map(attrs) do
    with {:ok, run_id} <- required_string(value(attrs, :run_id)),
         {:ok, turn_number} <- positive_integer(value(attrs, :turn_number)) do
      timestamp = now()
      status = optional_string(value(attrs, :status)) || "completed"

      duration_ms =
        non_negative_integer(value(attrs, :duration_ms), nil) ||
          elapsed_ms(ConversationTurn, conversation_id, {run_id, turn_number}, timestamp)

      row = %{
        conversation_id: conversation_id,
        run_id: run_id,
        turn_number: turn_number,
        status: status,
        stop_reason: optional_string(value(attrs, :stop_reason)),
        duration_ms: duration_ms,
        started_at: nil,
        completed_at: timestamp,
        created_at: timestamp,
        updated_at: timestamp
      }

      conflict =
        row
        |> Map.take([:status, :stop_reason, :duration_ms, :completed_at, :updated_at])
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      insert(ConversationTurn, row, conflict, [:conversation_id, :run_id, :turn_number])
    end
  end

  def record_turn_end(_conversation_id, _attrs), do: {:error, :invalid_turn}

  def snapshot(conversation_id, opts) when is_binary(conversation_id) and is_list(opts) do
    result =
      Repo.transaction(fn ->
        case Repo.get(Conversation, conversation_id) do
          nil ->
            Repo.rollback(:not_found)

          conversation ->
            version = snapshot_version(conversation_id, conversation)

            if expected = Keyword.get(opts, :snapshot_version) do
              if expected != version, do: Repo.rollback(:stale_or_invalid_cursor)
            end

            scope = scope_opts(opts)
            stats = stats(conversation_id, scope)
            {runs, runs_truncated?} = runs(conversation_id, scope)
            {turns, turns_truncated?} = turns(conversation_id, scope)
            {entries, entries_have_more?} = entries(conversation_id, opts)

            %{
              conversation: conversation_map(conversation, stats.messages),
              stats: Map.drop(stats, [:messages]),
              runs: runs,
              runs_truncated?: runs_truncated?,
              turns: turns,
              turns_truncated?: turns_truncated?,
              entries: entries,
              entries_have_more?: entries_have_more?,
              snapshot_version: version,
              fidelity: fidelity(conversation_id, scope)
            }
        end
      end)

    case result do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} -> {:error, reason}
    end
  end

  def snapshot(_conversation_id, _opts), do: {:error, :invalid_input}

  defp entries(conversation_id, opts) do
    limit = Keyword.fetch!(opts, :limit)
    after_sequence = Keyword.get(opts, :after_sequence, 0)

    query =
      from entry in ConversationEntry,
        where: entry.conversation_id == ^conversation_id and entry.sequence > ^after_sequence,
        order_by: [asc: entry.sequence],
        limit: ^(limit + 1)

    query = apply_scope(query, scope_opts(opts))
    query = apply_record_filters(query, opts)
    rows = Repo.all(query)

    entries =
      rows
      |> Enum.take(limit)
      |> Enum.map(&Handbean.ConversationTranscriptStore.ConversationStore.public_entry/1)

    {entries, length(rows) > limit}
  end

  defp stats(conversation_id, scope) do
    query =
      from entry in ConversationEntry,
        where: entry.conversation_id == ^conversation_id

    query = apply_scope(query, scope)

    entry_stats =
      Repo.one(
        from entry in query,
          select: %{
            records: count(entry.id),
            messages:
              fragment(
                "SUM(CASE WHEN ? IN ('user', 'assistant') THEN 1 ELSE 0 END)",
                entry.role
              ),
            tools:
              fragment(
                "SUM(CASE WHEN ? = 'tool' OR ? = 'tool' THEN 1 ELSE 0 END)",
                entry.role,
                entry.content_type
              ),
            errors:
              fragment(
                "SUM(CASE WHEN ? = 'error' OR ? = 'error' OR ? = 'error' THEN 1 ELSE 0 END)",
                entry.tool_status,
                entry.status,
                entry.message_type
              ),
            running:
              fragment(
                "SUM(CASE WHEN ? = 'running' OR ? = 'streaming' THEN 1 ELSE 0 END)",
                entry.tool_status,
                entry.status
              )
          }
      )

    run_ids = entry_run_ids(query)
    captured_run_ids = captured_run_ids(conversation_id, scope)
    turn_count = turn_count(conversation_id, scope)

    %{
      records: entry_stats.records || 0,
      messages: entry_stats.messages || 0,
      runs: MapSet.size(MapSet.union(run_ids, captured_run_ids)),
      turns: turn_count,
      tools: entry_stats.tools || 0,
      errors: entry_stats.errors || 0,
      running: entry_stats.running || 0
    }
  end

  defp entry_run_ids(query) do
    query
    |> where([entry], not is_nil(entry.run_id))
    |> select([entry], entry.run_id)
    |> distinct(true)
    |> Repo.all()
    |> MapSet.new()
  end

  defp captured_run_ids(conversation_id, scope) do
    query =
      from run in ConversationRun,
        where: run.conversation_id == ^conversation_id,
        select: run.run_id

    query = if scope.run_id, do: where(query, [run], run.run_id == ^scope.run_id), else: query
    query |> Repo.all() |> MapSet.new()
  end

  defp turn_count(conversation_id, scope) do
    entry_query =
      from entry in ConversationEntry,
        where: entry.conversation_id == ^conversation_id

    entry_query = apply_scope(entry_query, scope)

    MapSet.size(
      MapSet.union(
        entry_turn_keys(entry_query),
        captured_turn_keys(conversation_id, scope)
      )
    )
  end

  defp entry_turn_keys(query) do
    query
    |> where([entry], not is_nil(entry.run_id) and not is_nil(entry.turn_number))
    |> select([entry], {entry.run_id, entry.turn_number})
    |> distinct(true)
    |> Repo.all()
    |> MapSet.new()
  end

  defp captured_turn_keys(conversation_id, scope) do
    query =
      from turn in ConversationTurn,
        where: turn.conversation_id == ^conversation_id,
        select: {turn.run_id, turn.turn_number}

    query = apply_turn_scope(query, scope)
    query |> Repo.all() |> MapSet.new()
  end

  defp runs(conversation_id, scope) do
    query =
      from run in ConversationRun,
        where: run.conversation_id == ^conversation_id,
        order_by: [asc_nulls_last: run.started_at, asc: run.created_at, asc: run.id],
        limit: ^(@max_runs + 1)

    query = if scope.run_id, do: where(query, [run], run.run_id == ^scope.run_id), else: query
    rows = Repo.all(query)

    changes_by_run =
      Repo.all(
        from change in ConversationPermissionChange,
          where: change.conversation_id == ^conversation_id and not is_nil(change.run_id),
          order_by: [asc: change.revision, asc: change.id]
      )
      |> Enum.group_by(& &1.run_id)

    captured = Map.new(rows, &{&1.run_id, run_map(&1, changes_by_run)})

    legacy =
      conversation_id
      |> legacy_runs(scope)
      |> Enum.reject(&Map.has_key?(captured, &1.id))

    runs =
      (Map.values(captured) ++ legacy)
      |> Enum.sort_by(&{&1.started_at || "", &1.id})

    {Enum.take(runs, @max_runs), length(runs) > @max_runs or length(rows) > @max_runs}
  end

  defp legacy_runs(conversation_id, scope) do
    query =
      from entry in ConversationEntry,
        where: entry.conversation_id == ^conversation_id and not is_nil(entry.run_id),
        group_by: entry.run_id,
        select: {
          entry.run_id,
          min(entry.created_at),
          max(entry.updated_at),
          fragment(
            "SUM(CASE WHEN ? = 'running' OR ? = 'streaming' THEN 1 ELSE 0 END)",
            entry.tool_status,
            entry.status
          ),
          fragment(
            "SUM(CASE WHEN ? = 'error' OR ? = 'error' OR ? = 'error' THEN 1 ELSE 0 END)",
            entry.tool_status,
            entry.status,
            entry.message_type
          )
        }

    query = apply_scope(query, scope)

    Repo.all(query)
    |> Enum.map(fn {run_id, started_at, updated_at, running, errors} ->
      %{
        id: run_id,
        status: legacy_status(running || 0, errors || 0),
        stop_reason: nil,
        loop_owner: nil,
        backend: nil,
        model: nil,
        error: nil,
        turn_count: nil,
        duration_ms: nil,
        started_at: iso8601(started_at),
        completed_at: if((running || 0) > 0, do: nil, else: iso8601(updated_at)),
        capture_version: nil,
        initial_permission_mode: nil,
        initial_permission_revision: nil,
        initial_approval_mode: nil,
        initial_approvals_reviewer: nil,
        permission_source: nil,
        delegated_approval: nil,
        current_permission_mode: nil,
        current_permission_revision: nil,
        permission_changed_at: nil,
        permission_changes: [],
        code_baseline: nil,
        fidelity: "partial"
      }
    end)
  end

  defp turns(conversation_id, scope) do
    query =
      from turn in ConversationTurn,
        where: turn.conversation_id == ^conversation_id,
        order_by: [asc_nulls_last: turn.started_at, asc: turn.created_at, asc: turn.id],
        limit: ^(@max_turns + 1)

    query = apply_turn_scope(query, scope)
    rows = Repo.all(query)
    {rows |> Enum.take(@max_turns) |> Enum.map(&turn_map/1), length(rows) > @max_turns}
  end

  defp fidelity(conversation_id, scope) do
    entry_query =
      from entry in ConversationEntry,
        where: entry.conversation_id == ^conversation_id

    entry_query = apply_scope(entry_query, scope)
    entry_runs = entry_run_ids(entry_query)
    run_rows = captured_run_ids(conversation_id, scope)
    entry_turns = entry_turn_keys(entry_query)
    turn_rows = captured_turn_keys(conversation_id, scope)

    unscoped_execution_records =
      entry_query
      |> where(
        [entry],
        is_nil(entry.run_id) and
          (entry.role == "assistant" or entry.role == "tool" or entry.content_type == "tool")
      )
      |> Repo.aggregate(:count)

    missing_turns =
      entry_query
      |> where(
        [entry],
        not is_nil(entry.run_id) and is_nil(entry.turn_number) and
          (entry.role == "assistant" or entry.role == "tool" or entry.content_type == "tool")
      )
      |> Repo.aggregate(:count)

    missing_tool_timings =
      entry_query
      |> where(
        [entry],
        (entry.role == "tool" or entry.content_type == "tool") and
          fragment(
            "COALESCE(json_extract(?, '$.timing_fidelity'), '') NOT IN ('exact', 'not_started')",
            entry.payload
          )
      )
      |> Repo.aggregate(:count)

    missing =
      []
      |> maybe_missing(
        unscoped_execution_records > 0 or not MapSet.subset?(entry_runs, run_rows),
        "run_boundaries"
      )
      |> maybe_missing(
        unscoped_execution_records > 0 or missing_turns > 0 or
          not MapSet.subset?(entry_turns, turn_rows),
        "turn_boundaries"
      )
      |> maybe_missing(missing_tool_timings > 0, "exact_tool_timings")

    %{
      level: if(missing == [], do: "complete", else: "partial"),
      capture_version: @capture_version,
      missing: missing
    }
  end

  defp snapshot_version(conversation_id, conversation) do
    entries =
      Repo.one(
        from entry in ConversationEntry,
          where: entry.conversation_id == ^conversation_id,
          select: {
            count(entry.id),
            max(entry.sequence),
            fragment("COALESCE(SUM(?), 0)", entry.revision),
            max(entry.updated_at)
          }
      )

    runs =
      Repo.one(
        from run in ConversationRun,
          where: run.conversation_id == ^conversation_id,
          select: {count(run.id), max(run.updated_at)}
      )

    turns =
      Repo.one(
        from turn in ConversationTurn,
          where: turn.conversation_id == ^conversation_id,
          select: {count(turn.id), max(turn.updated_at)}
      )

    permission_changes =
      Repo.one(
        from change in ConversationPermissionChange,
          where: change.conversation_id == ^conversation_id,
          select: {count(change.id), max(change.changed_at)}
      )

    conversation_version =
      {
        conversation.title,
        conversation.selected_model,
        conversation.last_run_result,
        iso8601(conversation.archived_at),
        iso8601(conversation.updated_at)
      }

    {normalize_version(entries), normalize_version(runs), normalize_version(turns),
     normalize_version(permission_changes), conversation_version}
  end

  defp apply_scope(query, %{run_id: run_id, turn_number: turn_number}) do
    query = if run_id, do: where(query, [entry], entry.run_id == ^run_id), else: query

    if turn_number,
      do: where(query, [entry], entry.turn_number == ^turn_number),
      else: query
  end

  defp apply_turn_scope(query, %{run_id: run_id, turn_number: turn_number}) do
    query = if run_id, do: where(query, [turn], turn.run_id == ^run_id), else: query

    if turn_number,
      do: where(query, [turn], turn.turn_number == ^turn_number),
      else: query
  end

  defp apply_record_filters(query, opts) do
    query = apply_kinds(query, Keyword.get(opts, :kinds, []))

    if Keyword.get(opts, :errors_only, false) do
      where(
        query,
        [entry],
        entry.tool_status == "error" or entry.status == "error" or entry.message_type == "error"
      )
    else
      query
    end
  end

  defp apply_kinds(query, []), do: query

  defp apply_kinds(query, kinds) do
    condition =
      Enum.reduce(kinds, dynamic(false), fn
        "user", acc ->
          dynamic([entry], ^acc or entry.role == "user")

        "assistant", acc ->
          dynamic([entry], ^acc or entry.role == "assistant")

        "tool", acc ->
          dynamic([entry], ^acc or entry.role == "tool" or entry.content_type == "tool")

        "system", acc ->
          dynamic(
            [entry],
            ^acc or entry.role == "system" or entry.content_type == "system_msg"
          )
      end)

    where(query, ^condition)
  end

  defp scope_opts(opts) do
    %{
      run_id: Keyword.get(opts, :run_id),
      turn_number: Keyword.get(opts, :turn_number)
    }
  end

  defp conversation_map(conversation, message_count) do
    %{
      id: conversation.id,
      title: conversation.title,
      model: conversation.selected_model,
      created_at: iso8601(conversation.created_at),
      updated_at: iso8601(conversation.updated_at),
      archived_at: iso8601(conversation.archived_at),
      message_count: message_count,
      last_run_result: conversation.last_run_result
    }
  end

  defp run_map(run, changes_by_run) do
    %{
      id: run.run_id,
      status: run.status,
      stop_reason: run.stop_reason,
      loop_owner: run.loop_owner,
      backend: run.backend,
      model: run.model,
      initial_permission_mode: run.initial_permission_mode,
      initial_permission_revision: run.initial_permission_revision,
      initial_approval_mode: run.initial_approval_mode,
      initial_approvals_reviewer: run.initial_approvals_reviewer,
      permission_source: run.permission_source,
      delegated_approval: run.delegated_approval,
      current_permission_mode: run.current_permission_mode,
      current_permission_revision: run.current_permission_revision,
      permission_changed_at: iso8601(run.permission_changed_at),
      permission_changes:
        changes_by_run
        |> Map.get(run.run_id, [])
        |> Enum.map(&permission_change_map/1),
      error: Handbean.Log.Redactor.redact(run.error),
      turn_count: run.turn_count,
      duration_ms: run.duration_ms,
      code_baseline: run.code_baseline,
      started_at: iso8601(run.started_at),
      completed_at: iso8601(run.completed_at),
      capture_version: run.capture_version
    }
  end

  defp permission_change_map(change) do
    %{
      from: change.from_mode,
      to: change.to_mode,
      source: change.source,
      revision: change.revision,
      changed_at: iso8601(change.changed_at)
    }
  end

  defp turn_map(turn) do
    %{
      run_id: turn.run_id,
      number: turn.turn_number,
      status: turn.status,
      stop_reason: turn.stop_reason,
      duration_ms: turn.duration_ms,
      provider: turn.provider,
      model: turn.model,
      reasoning_level: turn.reasoning_level,
      config_revision: turn.config_revision,
      started_at: iso8601(turn.started_at),
      completed_at: iso8601(turn.completed_at)
    }
  end

  defp elapsed_ms(ConversationRun, conversation_id, run_id, timestamp) do
    case Repo.get_by(ConversationRun, conversation_id: conversation_id, run_id: run_id) do
      %ConversationRun{started_at: %DateTime{} = started_at} ->
        max(DateTime.diff(timestamp, started_at, :millisecond), 0)

      _ ->
        nil
    end
  end

  defp elapsed_ms(ConversationTurn, conversation_id, {run_id, turn_number}, timestamp) do
    case Repo.get_by(ConversationTurn,
           conversation_id: conversation_id,
           run_id: run_id,
           turn_number: turn_number
         ) do
      %ConversationTurn{started_at: %DateTime{} = started_at} ->
        max(DateTime.diff(timestamp, started_at, :millisecond), 0)

      _ ->
        nil
    end
  end

  defp settle_open_turns(_conversation_id, _run_id, status, _timestamp)
       when status in ["running", "interrupted"],
       do: :ok

  defp settle_open_turns(conversation_id, run_id, status, timestamp) do
    Repo.update_all(
      from(turn in ConversationTurn,
        where:
          turn.conversation_id == ^conversation_id and turn.run_id == ^run_id and
            turn.status == "running"
      ),
      set: [status: status, completed_at: timestamp, updated_at: timestamp]
    )

    :ok
  end

  defp fill_code_baseline(_conversation_id, _run_id, nil), do: :ok

  defp fill_code_baseline(conversation_id, run_id, code_baseline) do
    Repo.update_all(
      from(run in ConversationRun,
        where:
          run.conversation_id == ^conversation_id and run.run_id == ^run_id and
            is_nil(run.code_baseline)
      ),
      set: [code_baseline: code_baseline]
    )

    :ok
  end

  defp insert(schema, row, conflict, target) do
    case Repo.insert_all(schema, [row], on_conflict: [set: conflict], conflict_target: target) do
      {count, _} when count in [0, 1] -> :ok
      _ -> {:error, :persistence_failed}
    end
  rescue
    error -> {:error, error}
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp required_string(value) do
    case optional_string(value) do
      nil -> {:error, :invalid_run}
      string -> {:ok, string}
    end
  end

  defp optional_string(nil), do: nil
  defp optional_string(value) when is_binary(value), do: if(value == "", do: nil, else: value)
  defp optional_string(value) when is_atom(value), do: Atom.to_string(value)
  defp optional_string(_value), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: {:error, :invalid_turn}

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value, default), do: default

  defp normalize_code_baseline(baseline) when is_map(baseline) do
    head_sha = optional_string(value(baseline, :head_sha))
    branch = optional_string(value(baseline, :branch))
    raw_files = value(baseline, :dirty_files)

    dirty_files =
      if is_list(raw_files) do
        raw_files
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.take(50)
      else
        []
      end

    dirty_count = non_negative_integer(value(baseline, :dirty_count), length(dirty_files))

    truncated =
      case value(baseline, :dirty_files_truncated) do
        flag when is_boolean(flag) -> flag
        _ -> dirty_count > length(dirty_files)
      end

    collected_at =
      case value(baseline, :collected_at) do
        %DateTime{} = dt -> iso8601(dt)
        str when is_binary(str) and str != "" -> str
        _ -> iso8601(now())
      end

    %{
      "head_sha" => head_sha,
      "branch" => branch,
      "dirty_files" => dirty_files,
      "dirty_count" => dirty_count,
      "dirty_files_truncated" => truncated,
      "collected_at" => collected_at
    }
  end

  defp normalize_code_baseline(_), do: nil

  defp bounded_error(nil), do: nil
  defp bounded_error(error) when is_binary(error), do: String.slice(error, 0, 16_000)

  defp bounded_error(error) do
    error
    |> inspect(limit: 50, printable_limit: 16_000)
    |> String.slice(0, 16_000)
  end

  defp legacy_status(running, _errors) when running > 0, do: "running"
  defp legacy_status(_running, errors) when errors > 0, do: "error"
  defp legacy_status(_running, _errors), do: "unknown"

  defp maybe_missing(missing, true, name), do: missing ++ [name]
  defp maybe_missing(missing, false, _name), do: missing

  defp normalize_version(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(fn
      %DateTime{} = timestamp -> DateTime.to_iso8601(timestamp)
      value -> value
    end)
    |> List.to_tuple()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
end
