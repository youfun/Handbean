defmodule Handbean.Diagnostics.ErrorExport do
  @moduledoc """
  Bounded, read-only diagnostic export for the authenticated single-user host.
  See docs/error-diagnostics.md for the versioned data and privacy contract.
  """

  import Ecto.Query

  alias ErrorTracker.{Error, Occurrence, Repo}
  alias Handbean.ErrorTrackerFilter

  @source_root Path.expand("../../..", __DIR__)
  @source_files @source_root
                |> Path.join("lib/**/*.ex")
                |> Path.wildcard()
                |> Enum.map(&Path.relative_to(&1, @source_root))
                |> MapSet.new()
  @trusted_apps ~w(handbean elixir stdlib kernel ecto ecto_sql exqlite db_connection phoenix phoenix_live_view plug bandit req finch mint error_tracker jason)a
  @group_limit 100
  @occurrence_limit 3
  @stack_limit 30
  @ranges %{"24h" => 86_400, "7d" => 604_800, "30d" => 2_592_000, "all" => nil}
  @classes ~w(exception provider_overloaded provider_rate_limited provider_auth provider_timeout provider_server provider_error run_timeout run_inactivity_timeout run_tree_exit inbound_persist_failed subagent_startup_failed subagent_stopped tool_error agent_error)
  @categories ~w(unknown timeout exception error exit killed normal shutdown noproc noconnection badarg badmatch function_clause case_clause undef einval enoent eacces eperm enospc eio busy full ioerr corrupt binary_file chunk_not_found idempotency_conflict invalid_input is_a_directory no_parent offset_out_of_range unsandboxed_job_unsupported dependency_not_installed error_not_found file_not_found id_is_required invalid_arguments invalid_error_tracker_cursor no_such_file not_accessible path_not_allowed permission_denied stale_or_invalid_cursor subagent_not_found text_not_found response_too_large connection_or_tls_failed capability_unavailable provider_overloaded provider_rate_limited provider_auth provider_timeout provider_server provider_error)

  @doc "Returns a JSON-ready diagnostic document; never exports free-form error messages."
  def build(params \\ %{}, now \\ DateTime.utc_now()) do
    with {:ok, filters} <- filters(params, now) do
      Repo.transaction(fn -> export(filters, now) end)
    end
  rescue
    _error in [Exqlite.Error, DBConnection.ConnectionError, Ecto.QueryError] ->
      {:error, :unavailable}
  end

  defp filters(params, now) do
    range = Map.get(params, "range", "7d")
    status = Map.get(params, "status", "unresolved")

    if is_map_key(@ranges, range) and status in ["unresolved", "all"] do
      seconds = @ranges[range]

      {:ok,
       %{range: range, status: status, since: seconds && DateTime.add(now, -seconds), until: now}}
    else
      {:error, :invalid_filters}
    end
  end

  defp export(filters, now) do
    occurrences = from(o in Occurrence, where: o.inserted_at <= ^filters.until)

    occurrences =
      if filters.since,
        do: where(occurrences, [o], o.inserted_at >= ^filters.since),
        else: occurrences

    stats =
      from(o in occurrences,
        group_by: o.error_id,
        select: %{
          error_id: o.error_id,
          occurrence_count: count(o.id),
          first_at: min(o.inserted_at),
          last_at: max(o.inserted_at)
        }
      )

    groups =
      from(e in Error,
        join: s in subquery(stats),
        on: s.error_id == e.id,
        select: %{
          id: e.id,
          kind: e.kind,
          status: e.status,
          muted: e.muted,
          occurrence_count: s.occurrence_count,
          first_at: s.first_at,
          last_at: s.last_at
        }
      )

    groups =
      if filters.status == "unresolved",
        do: where(groups, [e], e.status == :unresolved),
        else: groups

    totals =
      Repo.one(
        from(g in subquery(groups),
          select: %{groups: count(g.id), occurrences: sum(g.occurrence_count)}
        )
      )

    selected =
      Repo.all(
        from(g in subquery(groups), order_by: [desc: g.last_at, desc: g.id], limit: @group_limit)
      )

    ids = Enum.map(selected, & &1.id)

    ranked =
      from(o in occurrences,
        where: o.error_id in ^ids,
        windows: [
          per_error: [partition_by: o.error_id, order_by: [desc: o.inserted_at, desc: o.id]]
        ],
        select: %{id: o.id, rank: over(row_number(), :per_error)}
      )

    recent =
      Repo.all(
        from(o in Occurrence,
          join: r in subquery(ranked),
          on: o.id == r.id,
          where: r.rank <= @occurrence_limit,
          order_by: [desc: o.inserted_at, desc: o.id],
          select: %{
            error_id: o.error_id,
            inserted_at: o.inserted_at,
            context: o.context,
            stacktrace: o.stacktrace
          }
        )
      )

    symbols = symbols()

    functions =
      recent
      |> Enum.flat_map(fn row ->
        if row.stacktrace, do: Enum.take(row.stacktrace.lines, @stack_limit), else: []
      end)
      |> Enum.map(& &1.module)
      |> Enum.uniq()
      |> Map.new(fn name ->
        module = symbols[name]
        {name, if(module, do: function_symbols(module), else: [])}
      end)

    salt = :crypto.strong_rand_bytes(32)
    tools = Handbean.Tool.Registry.host_tool_configuration() |> Enum.map(& &1.module.name())
    by_group = Enum.group_by(recent, & &1.error_id)

    errors =
      selected
      |> Enum.with_index(1)
      |> Enum.map(fn {group, index} ->
        samples =
          Enum.map(
            Map.get(by_group, group.id, []),
            &occurrence(&1, symbols, functions, tools, salt)
          )

        latest = List.first(samples) || %{}
        kind = known_kind(group.kind, symbols)

        %{
          id: "error-#{index}",
          kind: kind,
          status: group.status,
          muted: group.muted,
          summary: "#{kind || "Unknown error"}; original message omitted for privacy.",
          failure_class: latest[:failure_class],
          reason_category: latest[:reason_category],
          tool: latest[:tool],
          first_occurrence_at: group.first_at,
          last_occurrence_at: group.last_at,
          occurrence_count: group.occurrence_count,
          exported_occurrence_count: length(samples),
          truncated:
            group.occurrence_count > length(samples) or Enum.any?(samples, & &1.stack_truncated),
          occurrences: samples
        }
      end)

    exported_count = Enum.sum(Enum.map(errors, & &1.exported_occurrence_count))

    %{
      schema_version: 1,
      exported_at: now,
      application: %{
        name: "Handbean",
        version: to_string(Application.spec(:handbean, :vsn)),
        os: :os.type() |> Tuple.to_list(),
        elixir: System.version(),
        otp: System.otp_release()
      },
      filters: filters,
      limits: %{
        groups: @group_limit,
        occurrences_per_group: @occurrence_limit,
        stack_frames_per_occurrence: @stack_limit
      },
      counts: %{
        matching_groups: totals.groups,
        matching_occurrences: totals.occurrences || 0,
        exported_groups: length(errors),
        exported_occurrences: exported_count
      },
      truncated: totals.groups > length(errors) or Enum.any?(errors, & &1.truncated),
      privacy: %{
        policy: "allowlist-v1",
        original_messages: "omitted",
        context: "classification allowlist only",
        breadcrumbs: "omitted",
        identifiers: "export-local sequence",
        stack:
          "shipped application modules and BEAM function tables; verified project source manifest only; no arguments",
        provider_model: "per-export keyed pseudonyms; original identifiers and key omitted",
        original_message_count: exported_count,
        unknown_values: "null",
        counts:
          "retained occurrences within inclusive UTC bounds; status is current; muted groups included"
      },
      errors: errors
    }
  end

  defp occurrence(row, symbols, functions, tools, salt) do
    context =
      (row.context || %{})
      |> Map.take(["failure_class", "reason_category", "tool"])
      |> ErrorTrackerFilter.sanitize()

    lines = if row.stacktrace, do: row.stacktrace.lines, else: []

    %{
      occurred_at: row.inserted_at,
      failure_class: allowed(context["failure_class"], @classes),
      reason_category: category(context["reason_category"]),
      tool: allowed(context["tool"], tools),
      provider_ref: reference(row.context, "provider", salt),
      model_ref: reference(row.context, "model", salt),
      omitted_classification_fields:
        Enum.filter(["failure_class", "reason_category", "tool"], fn key ->
          value = context[key]

          not is_nil(value) and
            is_nil(
              case key do
                "failure_class" -> allowed(value, @classes)
                "reason_category" -> category(value)
                "tool" -> allowed(value, tools)
              end
            )
        end),
      stack: lines |> Enum.take(@stack_limit) |> Enum.map(&frame(&1, symbols, functions)),
      stack_truncated: length(lines) > @stack_limit
    }
  end

  defp category("http_status_" <> code = value) do
    if code in Enum.map(100..599, &Integer.to_string/1), do: value
  end

  defp category(value), do: allowed(value, @categories)
  defp allowed(value, values), do: if(value in values, do: value)

  # Resolve symbols from installed application metadata, never from error text.
  defp symbols do
    for app <- @trusted_apps,
        module <- Application.spec(app, :modules) || [],
        into: %{} do
      {module |> Atom.to_string() |> String.replace_prefix("Elixir.", ""), module}
    end
  end

  defp known_kind(kind, symbols) do
    name = String.replace_prefix(kind || "", "Elixir.", "")
    if Map.has_key?(symbols, name) or name in ["error", "exit", "throw"], do: name
  end

  defp frame(line, symbols, functions) do
    case Map.get(symbols, line.module) do
      nil ->
        %{module: nil, function: nil, arity: nil, file: nil, line: nil}

      module ->
        exports = Map.get(functions, line.module, [])

        function =
          Enum.find_value(exports, fn {name, arity} ->
            if Atom.to_string(name) == line.function and arity == line.arity,
              do: Atom.to_string(name)
          end)

        %{
          module: line.module,
          function: function,
          arity: if(function, do: line.arity),
          file: source_file(module, line.file),
          line: if(is_integer(line.line) and line.line > 0, do: line.line)
        }
    end
  end

  defp reference(context, field, salt) when is_map(context) do
    case context[field] do
      value when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= 1_024 ->
        field <>
          "-" <>
          (:crypto.mac(:hmac, :sha256, salt, field <> <<0>> <> value)
           |> Base.encode16(case: :lower)
           |> binary_part(0, 24))

      _ ->
        nil
    end
  end

  defp reference(_, _, _), do: nil

  defp function_symbols(module) do
    if Code.ensure_loaded?(module) do
      case :code.which(module) do
        path when is_list(path) ->
          case :beam_lib.chunks(path, [:locals, :exports]) do
            {:ok, {^module, chunks}} -> chunks[:exports] ++ chunks[:locals]
            _ -> module.module_info(:exports)
          end

        _ ->
          module.module_info(:exports)
      end
    else
      []
    end
  end

  defp source_file(module, file) when is_binary(file) do
    source = if Code.ensure_loaded?(module), do: module.module_info(:compile)[:source], else: nil
    source = source && to_string(source)

    path = source && Path.relative_to(source, @source_root)

    if MapSet.member?(@source_files, path) and (file == path or file == source), do: path
  end

  defp source_file(_, _), do: nil
end
