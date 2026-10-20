defmodule Handbean.Memory.Provenance do
  @moduledoc """
  Validates and persists trusted memory operation provenance.

  `opts[:provenance]` is internal operation data. It accepts `:actor`,
  `:operation_conversation_id`, `:operation_run_id`,
  `:operation_tool_call_id`, `:trigger_entry_id`, `:citations`,
  `:idempotency_key`, and optional `:metadata`.

  Citation maps accept atom or string keys for `conversation_id`, `entry_id`,
  `sequence`, and `revision`. An inclusive range additionally supplies
  `end_entry_id`, `end_sequence`, and `end_revision`. At most ten citations
  are accepted.

  Reflector callers may supply `trusted_checkpoint: true` and a `checkpoint`
  map identifying an exact persisted checkpoint entry. The checkpoint is only
  accepted for actor `:reflector`, in the caller workspace, after its stored
  source range validates.
  """

  import Ecto.Query

  alias Handbean.Agent.CompactionCheckpoint
  alias Handbean.Memory.{EngramEvent, EngramProvenance}
  alias Handbean.Repo
  alias Handbean.Storage.{Conversation, ConversationEntry}

  @actors [:agent_tool, :reflector, :user_ui, :system, :legacy]
  @max_citations 10

  @type projection_status ::
          :available | :changed | :deleted | :inaccessible | :unresolved_legacy

  @spec idempotent_engram(keyword(), atom(), String.t()) ::
          {:ok, struct()} | {:error, :idempotency_conflict} | :none
  def idempotent_engram(opts, operation, fingerprint) do
    with key when is_binary(key) and key != "" <- provenance_value(opts, :idempotency_key),
         %EngramEvent{} = event <-
           Repo.one(from event in EngramEvent, where: event.idempotency_key == ^key) do
      metadata = event.metadata || %{}

      if metadata["operation"] == Atom.to_string(operation) and
           metadata["request_fingerprint"] == fingerprint do
        case Repo.get(Handbean.Memory.Engram, event.engram_id) do
          nil -> {:error, :idempotency_conflict}
          engram -> {:ok, engram}
        end
      else
        {:error, :idempotency_conflict}
      end
    else
      nil -> :none
      _ -> :none
    end
  end

  @spec record(struct(), atom(), keyword()) :: {:ok, EngramEvent.t()} | {:error, term()}
  def record(engram, kind, opts) do
    provenance = Keyword.get(opts, :provenance, %{})
    actor = value(provenance, :actor) || :system

    with {:ok, actor} <- normalize_actor(actor),
         :ok <- validate_optional_string(provenance, :operation_conversation_id),
         :ok <- validate_optional_string(provenance, :operation_run_id),
         :ok <- validate_optional_string(provenance, :operation_tool_call_id),
         :ok <- validate_optional_string(provenance, :idempotency_key),
         {:ok, sources} <- validate_sources(provenance, actor, opts),
         {:ok, event} <- insert_event(engram, kind, actor, provenance, opts),
         :ok <- insert_sources(event, sources) do
      {:ok, event}
    end
  end

  @spec project([EngramEvent.t()], String.t() | nil) :: [map()]
  def project(events, workspace_id) do
    projection_context = projection_context(events, workspace_id)

    Enum.map(events, fn event ->
      sources =
        case event.provenances do
          [] when event.actor == :legacy ->
            [
              %{
                relation: :legacy,
                source_kind: :legacy,
                fidelity: :legacy_coarse,
                status: :unresolved_legacy
              }
            ]

          provenances ->
            Enum.map(provenances, &project_source(&1, workspace_id, projection_context))
        end

      %{
        id: event.id,
        kind: event.kind,
        actor: event.actor,
        engram_revision: event.engram_revision,
        metadata: projected_metadata(event, sources),
        inserted_at: event.inserted_at,
        sources: sources
      }
    end)
  end

  defp validate_sources(provenance, actor, opts) when is_map(provenance) do
    citations = List.wrap(value(provenance, :citations))

    cond do
      length(citations) > @max_citations ->
        {:error, :too_many_citations}

      Enum.any?(citations, &(not is_map(&1))) ->
        {:error, :invalid_provenance}

      true ->
        workspace_id = Keyword.get(opts, :workspace_id)

        with {:ok, trigger} <- validate_trigger(provenance, workspace_id),
             {:ok, citation_sources} <- validate_citations(citations, workspace_id),
             {:ok, checkpoint} <- validate_checkpoint(provenance, actor, workspace_id) do
          {:ok, List.wrap(trigger) ++ citation_sources ++ List.wrap(checkpoint)}
        end
    end
  end

  defp validate_sources(_provenance, _actor, _opts), do: {:error, :invalid_provenance}

  defp validate_trigger(provenance, workspace_id) do
    case value(provenance, :trigger_entry_id) do
      nil ->
        {:ok, nil}

      entry_id when is_binary(entry_id) and entry_id != "" ->
        conversation_id = value(provenance, :operation_conversation_id)

        with true <- valid_string?(conversation_id) do
          validate_trigger_source(conversation_id, entry_id, workspace_id)
        else
          _ -> {:error, :invalid_provenance}
        end

      _ ->
        {:error, :invalid_provenance}
    end
  end

  # Trigger entries are trusted runtime context, not user-supplied evidence. A
  # trigger outside the source-visibility boundary is omitted so Free Chat,
  # internal conversations, and global operations are not blocked. Once the
  # conversation is eligible, its exact anchor still validates strictly.
  defp validate_trigger_source(conversation_id, entry_id, workspace_id) do
    case Repo.get(Conversation, conversation_id) do
      %Conversation{
        status: "active",
        scope: "workspace",
        workspace_id: ^workspace_id,
        visibility: "user"
      }
      when is_binary(workspace_id) and workspace_id != "" ->
        with {:ok, [entry]} <- exact_public_range(conversation_id, entry_id, nil, workspace_id) do
          {:ok, source_attrs(:trigger, :entry, workspace_id, conversation_id, [entry])}
        end

      _conversation ->
        {:ok, nil}
    end
  end

  defp validate_citations(citations, workspace_id) do
    Enum.reduce_while(citations, {:ok, []}, fn citation, {:ok, sources} ->
      with {:ok, source} <- validate_citation(citation, workspace_id) do
        {:cont, {:ok, [source | sources]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, sources} -> {:ok, Enum.reverse(sources)}
      error -> error
    end
  end

  defp validate_citation(citation, workspace_id) do
    conversation_id = value(citation, :conversation_id)
    entry_id = value(citation, :entry_id)
    sequence = value(citation, :sequence)
    revision = value(citation, :revision)
    end_entry_id = value(citation, :end_entry_id)
    end_sequence = value(citation, :end_sequence)
    end_revision = value(citation, :end_revision)

    range? = Enum.any?([end_entry_id, end_sequence, end_revision], &(not is_nil(&1)))

    with true <- valid_string?(conversation_id),
         true <- valid_string?(entry_id),
         true <- positive_integer?(sequence),
         true <- positive_integer?(revision),
         :ok <- validate_range_end(range?, end_entry_id, end_sequence, end_revision),
         {:ok, entries} <-
           exact_public_range(
             conversation_id,
             entry_id,
             if(range?, do: end_entry_id),
             workspace_id
           ),
         true <- exact_entry?(hd(entries), entry_id, sequence, revision),
         true <-
           not range? or
             exact_entry?(List.last(entries), end_entry_id, end_sequence, end_revision) do
      kind = if range?, do: :entry_range, else: :entry
      {:ok, source_attrs(:citation, kind, workspace_id, conversation_id, entries)}
    else
      _ -> {:error, :invalid_provenance}
    end
  end

  defp validate_range_end(false, nil, nil, nil), do: :ok

  defp validate_range_end(true, entry_id, sequence, revision) do
    if valid_string?(entry_id) and positive_integer?(sequence) and positive_integer?(revision),
      do: :ok,
      else: {:error, :invalid_provenance}
  end

  defp validate_checkpoint(provenance, actor, workspace_id) do
    checkpoint = value(provenance, :checkpoint)
    trusted? = value(provenance, :trusted_checkpoint) == true

    cond do
      is_nil(checkpoint) ->
        {:ok, nil}

      actor != :reflector or not trusted? or not is_map(checkpoint) ->
        {:error, :invalid_provenance}

      true ->
        validate_checkpoint_entry(checkpoint, workspace_id)
    end
  end

  defp validate_checkpoint_entry(checkpoint, workspace_id) do
    conversation_id = value(checkpoint, :conversation_id)
    entry_id = value(checkpoint, :entry_id) || value(checkpoint, :id)
    sequence = value(checkpoint, :sequence)
    revision = value(checkpoint, :revision)

    with true <- valid_string?(conversation_id),
         true <- valid_string?(entry_id),
         true <- positive_integer?(sequence),
         true <- positive_integer?(revision),
         {:ok, conversation} <- visible_conversation(conversation_id, workspace_id),
         %ConversationEntry{} = row <-
           Repo.one(
             from entry in ConversationEntry,
               where: entry.conversation_id == ^conversation.id and entry.entry_id == ^entry_id
           ),
         true <- exact_entry?(row, entry_id, sequence, revision),
         checkpoint_map <- entry_map(row),
         true <- CompactionCheckpoint.checkpoint?(checkpoint_map),
         first_id when is_binary(first_id) <- checkpoint_map["first_entry_id"],
         end_id when is_binary(end_id) <- checkpoint_map["covered_through_id"],
         {:ok, range} <- exact_public_range(conversation_id, first_id, end_id, workspace_id),
         true <- checkpoint_range_valid?(checkpoint_map, row, range) do
      {:ok, source_attrs(:coverage, :checkpoint, workspace_id, conversation_id, range)}
    else
      _ -> {:error, :invalid_provenance}
    end
  end

  defp checkpoint_range_valid?(checkpoint, checkpoint_entry, range) do
    source = Enum.map(range, &entry_map/1)
    boundary = List.last(range)

    checkpoint_entry.sequence > boundary.sequence and
      checkpoint["source_count"] == length(source) and
      checkpoint["source_digest"] == CompactionCheckpoint.digest(source)
  end

  defp exact_public_range(conversation_id, start_entry_id, end_entry_id, workspace_id) do
    with {:ok, conversation} <- visible_conversation(conversation_id, workspace_id),
         %ConversationEntry{} = start_entry <-
           Repo.one(
             from entry in ConversationEntry,
               where:
                 entry.conversation_id == ^conversation.id and
                   entry.entry_id == ^start_entry_id
           ),
         {:ok, entries} <- load_range(conversation.id, start_entry, end_entry_id),
         true <- Enum.all?(entries, &public_settled?/1) do
      {:ok, entries}
    else
      _ -> {:error, :invalid_provenance}
    end
  end

  defp load_range(_conversation_id, start_entry, nil), do: {:ok, [start_entry]}

  defp load_range(conversation_id, start_entry, end_entry_id) do
    with %ConversationEntry{} = end_entry <-
           Repo.one(
             from entry in ConversationEntry,
               where:
                 entry.conversation_id == ^conversation_id and entry.entry_id == ^end_entry_id
           ),
         true <- start_entry.sequence <= end_entry.sequence do
      entries =
        Repo.all(
          from entry in ConversationEntry,
            where:
              entry.conversation_id == ^conversation_id and
                entry.sequence >= ^start_entry.sequence and
                entry.sequence <= ^end_entry.sequence,
            order_by: [asc: entry.sequence, asc: entry.id]
        )

      {:ok, entries}
    else
      _ -> {:error, :invalid_provenance}
    end
  end

  defp visible_conversation(conversation_id, workspace_id)
       when is_binary(workspace_id) and workspace_id != "" do
    case Repo.one(
           from conversation in Conversation,
             where:
               conversation.id == ^conversation_id and conversation.status == "active" and
                 conversation.scope == "workspace" and
                 conversation.workspace_id == ^workspace_id and
                 conversation.visibility == "user"
         ) do
      nil -> {:error, :inaccessible}
      conversation -> {:ok, conversation}
    end
  end

  defp visible_conversation(_conversation_id, _workspace_id), do: {:error, :inaccessible}

  defp public_settled?(entry) do
    entry.role != "internal" and entry.message_type != "internal" and
      entry.content_type not in ["memory_reflection", "model_compaction"] and
      entry.status not in ["streaming", "running"] and
      entry.tool_status not in ["streaming", "running"]
  end

  defp source_attrs(relation, source_kind, workspace_id, conversation_id, entries) do
    first = hd(entries)
    last = List.last(entries)

    %{
      relation: relation,
      source_kind: source_kind,
      source_workspace_id: workspace_id,
      source_conversation_id: conversation_id,
      start_conversation_entry_id: first.id,
      end_conversation_entry_id: last.id,
      start_entry_id: first.entry_id,
      start_sequence: first.sequence,
      start_revision: first.revision,
      end_entry_id: last.entry_id,
      end_sequence: last.sequence,
      end_revision: last.revision,
      member_count: length(entries),
      anchor_digest: digest(entries),
      fidelity: :exact
    }
  end

  defp insert_event(engram, kind, actor, provenance, opts) do
    attrs = %{
      engram_id: engram.id,
      engram_revision: engram.revision,
      kind: kind,
      actor: actor,
      operation_conversation_id: optional_string(provenance, :operation_conversation_id),
      operation_run_id: optional_string(provenance, :operation_run_id),
      operation_tool_call_id: optional_string(provenance, :operation_tool_call_id),
      idempotency_key: optional_string(provenance, :idempotency_key),
      metadata:
        provenance
        |> value(:metadata)
        |> normalize_metadata()
        |> Map.put("operation", Atom.to_string(Keyword.fetch!(opts, :provenance_operation)))
        |> Map.put(
          "request_fingerprint",
          Keyword.fetch!(opts, :provenance_request_fingerprint)
        )
    }

    result =
      %EngramEvent{}
      |> EngramEvent.changeset(attrs)
      |> Repo.insert()

    case result do
      {:error, %Ecto.Changeset{} = changeset} ->
        if idempotency_unique_conflict?(changeset),
          do: {:error, :idempotency_conflict},
          else: {:error, changeset}

      result ->
        result
    end
  end

  defp idempotency_unique_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:idempotency_key, {_message, opts}} -> opts[:constraint] == :unique
      _error -> false
    end)
  end

  defp insert_sources(event, sources) do
    Enum.reduce_while(sources, :ok, fn attrs, :ok ->
      changeset =
        %EngramProvenance{}
        |> EngramProvenance.changeset(Map.put(attrs, :event_id, event.id))

      case Repo.insert(changeset) do
        {:ok, _source} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Legacy metadata was never independently authorized and may contain stale or
  # foreign identifiers. Only a same-workspace, authorized reflector checkpoint
  # identifier is projected from exact events.
  defp projected_metadata(%EngramEvent{actor: :reflector, metadata: metadata}, sources) do
    if sources != [] and Enum.all?(sources, &(&1.status in [:available, :changed])) do
      case (metadata || %{})["checkpoint_id"] do
        checkpoint_id when is_binary(checkpoint_id) and checkpoint_id != "" ->
          %{"checkpoint_id" => checkpoint_id}

        _ ->
          %{}
      end
    else
      %{}
    end
  end

  defp projected_metadata(_event, _sources), do: %{}

  defp projection_context(events, workspace_id) do
    provenances = Enum.flat_map(events, & &1.provenances)

    conversation_ids =
      provenances
      |> Enum.filter(&(&1.source_workspace_id == workspace_id))
      |> Enum.map(& &1.source_conversation_id)
      |> Enum.uniq()

    conversations = load_projection_conversations(conversation_ids)

    accessible =
      Enum.filter(provenances, fn provenance ->
        provenance.source_workspace_id == workspace_id and
          accessible_conversation?(conversations[provenance.source_conversation_id], workspace_id) and
          not is_nil(provenance.start_conversation_entry_id) and
          not is_nil(provenance.end_conversation_entry_id)
      end)

    %{conversations: conversations, entries: load_projection_entries(accessible)}
  end

  defp load_projection_conversations([]), do: %{}

  defp load_projection_conversations(conversation_ids) do
    Conversation
    |> where([conversation], conversation.id in ^conversation_ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp load_projection_entries([]), do: %{}

  defp load_projection_entries(provenances) do
    condition =
      Enum.reduce(provenances, dynamic(false), fn provenance, condition ->
        conversation_id = provenance.source_conversation_id
        start_sequence = provenance.start_sequence
        end_sequence = provenance.end_sequence

        dynamic(
          [entry],
          ^condition or
            (entry.conversation_id == ^conversation_id and
               entry.sequence >= ^start_sequence and entry.sequence <= ^end_sequence)
        )
      end)

    ConversationEntry
    |> where(^condition)
    |> order_by([entry], asc: entry.conversation_id, asc: entry.sequence, asc: entry.id)
    |> Repo.all()
    |> Enum.group_by(& &1.conversation_id)
  end

  defp project_source(%EngramProvenance{fidelity: :legacy_coarse}, _workspace_id, _context),
    do: %{
      relation: :legacy,
      source_kind: :legacy,
      fidelity: :legacy_coarse,
      status: :unresolved_legacy
    }

  defp project_source(provenance, workspace_id, context) do
    base = %{
      relation: provenance.relation,
      source_kind: provenance.source_kind,
      fidelity: provenance.fidelity,
      member_count: provenance.member_count
    }

    case source_status(provenance, workspace_id, context) do
      {:available, entries} -> Map.merge(base, source_projection(provenance, entries))
      status -> Map.put(base, :status, status)
    end
  end

  defp source_status(provenance, workspace_id, context) do
    cond do
      provenance.source_workspace_id != workspace_id ->
        :inaccessible

      true ->
        conversation = context.conversations[provenance.source_conversation_id]

        cond do
          is_nil(conversation) ->
            :deleted

          not accessible_conversation?(conversation, workspace_id) ->
            :inaccessible

          is_nil(provenance.start_conversation_entry_id) or
              is_nil(provenance.end_conversation_entry_id) ->
            :deleted

          true ->
            source_status_for_accessible_conversation(provenance, context.entries)
        end
    end
  end

  defp accessible_conversation?(
         %Conversation{
           status: "active",
           scope: "workspace",
           workspace_id: workspace_id,
           visibility: "user"
         },
         workspace_id
       ),
       do: true

  defp accessible_conversation?(_conversation, _workspace_id), do: false

  defp source_status_for_accessible_conversation(provenance, entries_by_conversation) do
    entries =
      entries_by_conversation
      |> Map.get(provenance.source_conversation_id, [])
      |> Enum.filter(
        &(&1.sequence >= provenance.start_sequence and &1.sequence <= provenance.end_sequence)
      )

    cond do
      entries == [] -> :deleted
      not Enum.all?(entries, &public_settled?/1) -> :changed
      exact_projection?(provenance, entries) -> {:available, entries}
      true -> :changed
    end
  end

  defp exact_projection?(provenance, entries) do
    first = hd(entries)
    last = List.last(entries)

    exact_entry?(
      first,
      provenance.start_entry_id,
      provenance.start_sequence,
      provenance.start_revision
    ) and
      exact_entry?(
        last,
        provenance.end_entry_id,
        provenance.end_sequence,
        provenance.end_revision
      ) and length(entries) == provenance.member_count and
      digest(entries) == provenance.anchor_digest
  end

  defp source_projection(provenance, entries) do
    first = hd(entries)
    last = List.last(entries)

    %{
      status: :available,
      conversation_id: provenance.source_conversation_id,
      start: %{entry_id: first.entry_id, sequence: first.sequence, revision: first.revision},
      end: %{entry_id: last.entry_id, sequence: last.sequence, revision: last.revision}
    }
  end

  defp digest(entries) do
    entries
    |> Enum.map(&[&1.entry_id, &1.sequence, &1.revision])
    |> Handbean.JSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp entry_map(entry) do
    Handbean.ConversationTranscriptStore.ConversationStore.public_entry(entry)
  end

  defp exact_entry?(entry, entry_id, sequence, revision) do
    entry.entry_id == entry_id and entry.sequence == sequence and entry.revision == revision
  end

  defp normalize_actor(actor) when actor in @actors, do: {:ok, actor}

  defp normalize_actor(actor) when is_binary(actor) do
    case Enum.find(@actors, &(Atom.to_string(&1) == actor)) do
      nil -> {:error, :invalid_provenance}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_actor(_actor), do: {:error, :invalid_provenance}

  defp validate_optional_string(map, key) do
    case value(map, key) do
      nil -> :ok
      string when is_binary(string) and string != "" -> :ok
      _ -> {:error, :invalid_provenance}
    end
  end

  defp optional_string(map, key) do
    case value(map, key) do
      string when is_binary(string) and string != "" -> string
      _ -> nil
    end
  end

  defp provenance_value(opts, key) do
    opts |> Keyword.get(:provenance, %{}) |> value(key)
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_map, _key), do: nil

  defp valid_string?(value), do: is_binary(value) and value != ""
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}
end
