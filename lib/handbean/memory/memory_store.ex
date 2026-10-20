defmodule Handbean.Memory.MemoryStore do
  @moduledoc """
  Memory store — CRUD operations for engrams and synapses.

  Owns scope validation for recall, learn, reinforce, associate, update,
  and delete operations.
  """

  import Ecto.Query, warn: false

  alias Handbean.Memory.{Engram, EngramEvent, Provenance, Synapse}
  alias Handbean.Memory.MemoryStore.{Fingerprint, Recall}
  alias Handbean.Repo

  @recall_token_limit 16
  @engram_kinds [:preference, :rule, :pattern, :fact, :context]
  @identity_metadata_keys [
    "scope",
    :scope,
    "workspace_id",
    :workspace_id,
    "privacy_mode",
    :privacy_mode
  ]
  @lifecycle_filters [:active, :long_term, :short_term, :expired, :all]

  @doc """
  Recall engrams matching a keyword query.

  The query is downcased, punctuation is treated as whitespace, and tokens are
  deduped. At most #{@recall_token_limit} usable tokens are kept. By default they
  come from the start; `token_window: :head_tail` keeps an even split from the
  start and end for long natural-language prompts.
  Tokens shorter than 2 graphemes and stop words (common English function words,
  plus a few common Chinese ones) are dropped. A CJK run (`\\p{Han}`) of 2 to 4
  graphemes stays one token; a longer CJK run is replaced by its overlapping
  2-grapheme bigrams. Mixed tokens such as `ui设置` are split into ASCII and
  Han parts first.

  Tokens of 3 or more graphemes are matched with the FTS5 trigram index.
  2-grapheme tokens, including CJK bigrams, use a substring match.

  An engram must contain enough distinct query tokens. The base is `:min_matches`
  when that option is a positive integer, otherwise 2 when there are at least
  two usable tokens and 1 when there is one. The base is capped to the usable
  token count. The effective threshold is
  `max(base, ceil(match_percent / 100 * token_count))`, also capped to the token count.
  `match_percent` defaults to 30.
  Results are then ordered by how many tokens matched, FTS bm25, long-term
  first, reinforcement, and recency.

  ## Options

    * `:limit` — max results after scoring (default 10)
    * `:min_matches` — base token overlap required, before the proportional floor
    * `:match_percent` — proportional token-overlap floor, 1..100 (default 30)
    * `:max_required_matches` — optional cap for the final overlap threshold
    * `:token_window` — `:head` (default) or `:head_tail` for long prompts
  """
  @spec recall(String.t(), keyword()) :: [Engram.t()]
  def recall(query, opts \\ []), do: Recall.recall(query, opts)

  @doc """
  Return memory recall metrics for a query without loading full associations.

  Metrics are intended for evaluating Observational Memory effectiveness and
  isolation behaviour: hit counts, workspace/global mix, and scoped leakage.
  """
  @spec recall_metrics(String.t(), keyword()) :: map()
  def recall_metrics(query, opts \\ []) do
    results = recall(query, opts)
    workspace_id = Keyword.get(opts, :workspace_id)

    %{
      query: query,
      total_hits: length(results),
      workspace_hits: Enum.count(results, &(metadata_value(&1, "scope") == "workspace")),
      global_hits: Enum.count(results, &(metadata_value(&1, "scope") == "global")),
      current_workspace_hits:
        Enum.count(results, fn engram ->
          metadata_value(engram, "scope") == "workspace" and
            metadata_value(engram, "workspace_id") == workspace_id
        end),
      cross_workspace_hits:
        Enum.count(results, fn engram ->
          metadata_value(engram, "scope") == "workspace" and
            not is_nil(workspace_id) and metadata_value(engram, "workspace_id") != workspace_id
        end)
    }
  end

  @doc """
  Learn a new engram.

  ## Examples

      iex> MemoryStore.learn("User prefers snake_case", :preference,
      ...>   memory_scope: :workspace, workspace_id: "workspace-id")
      {:ok, %Engram{}}
  """
  @spec learn(String.t(), atom(), keyword()) ::
          {:ok, Engram.t()} | {:error, Ecto.Changeset.t() | :invalid_scope}
  def learn(content, kind, opts \\ []) do
    with {:ok, identity} <- write_identity(opts) do
      metadata =
        opts
        |> Keyword.get(:metadata, %{})
        |> normalize_metadata()
        |> Map.drop(@identity_metadata_keys)
        |> Map.merge(identity)

      fingerprint =
        operation_fingerprint({
          :created,
          content,
          kind,
          Keyword.get(opts, :short_term, true),
          Keyword.get(opts, :ttl_hours, 24),
          metadata,
          fingerprint_provenance(opts)
        })

      transactional_write(
        opts,
        fn event_opts ->
          with {:ok, engram} <- insert_engram(content, kind, metadata, opts),
               {:ok, _event} <- Provenance.record(engram, :created, event_opts) do
            {:ok, engram}
          end
        end,
        :created,
        fingerprint
      )
    end
  end

  @doc """
  List engrams for the memory settings page.

  The query is always scope-aware. Workspace scope without a valid
  `:workspace_id` returns no records, so callers cannot accidentally expose
  memories from another workspace.

  ## Options

    * `:workspace_id` — workspace used by `:workspace` and `:both` scopes
    * `:scope` — `:workspace`, `:global`, or `:both` (default `:workspace`)
    * `:lifecycle` — `:active`, `:long_term`, `:short_term`, `:expired`, or `:all`
    * `:kind` — one of the five engram kinds
    * `:query` — a content substring, or an exact numeric ID such as `#48`
    * `:preload_synapses` — load visible associations for presentation (default `true`)
  """
  @spec list_engrams(keyword()) :: [Engram.t()]
  def list_engrams(opts \\ []) do
    now = DateTime.utc_now()

    results =
      Engram
      |> apply_list_scope_filter(opts)
      |> apply_list_query(Keyword.get(opts, :query))
      |> apply_lifecycle_filter(Keyword.get(opts, :lifecycle, :active), now)
      |> apply_kind_filter(Keyword.get(opts, :kind))
      |> order_by([e], asc: e.short_term, desc: e.updated_at, desc: e.id)
      |> Repo.all()

    if Keyword.get(opts, :preload_synapses, true),
      do: preload_visible_synapses(results),
      else: results
  end

  @doc """
  Count memories visible to a workspace for the settings page.

  Lifecycle totals use the requested scope, query, and optional kind while
  ignoring the selected lifecycle. `:by_kind` additionally applies the
  requested lifecycle, which lets the UI keep kind chips in sync with the
  active lifecycle card.
  """
  @spec count_summary(String.t() | nil, keyword()) :: %{
          active: non_neg_integer(),
          long_term: non_neg_integer(),
          short_term: non_neg_integer(),
          expired: non_neg_integer(),
          by_kind: %{atom() => non_neg_integer()}
        }
  def count_summary(workspace_id, opts \\ []) do
    now = DateTime.utc_now()
    opts = Keyword.put(opts, :workspace_id, workspace_id)

    base_query =
      Engram
      |> apply_list_scope_filter(opts)
      |> apply_list_query(Keyword.get(opts, :query))
      |> apply_kind_filter(Keyword.get(opts, :kind))

    kind_counts =
      base_query
      |> apply_lifecycle_filter(Keyword.get(opts, :lifecycle, :active), now)
      |> group_by([e], e.kind)
      |> select([e], {e.kind, count(e.id)})
      |> Repo.all()
      |> Map.new()

    base_query
    |> lifecycle_counts(now)
    |> Map.put(:by_kind, Map.new(@engram_kinds, &{&1, Map.get(kind_counts, &1, 0)}))
  end

  @doc """
  Reinforce an engram — promote from short-term to long-term memory.

  Increments the reinforcement counter and updates the timestamp.
  """
  @spec reinforce(integer(), keyword()) ::
          {:ok, Engram.t()} | {:error, :invalid_scope | :not_found}
  def reinforce(id, opts \\ [])

  def reinforce(id, opts) when is_integer(id) do
    with :ok <- validate_mutation_scope(opts) do
      transactional_write(
        opts,
        fn event_opts ->
          with {:ok, reinforced} <- reinforce_query(active_scoped_id_query(id, opts)),
               {:ok, _event} <- Provenance.record(reinforced, :reinforced, event_opts) do
            {:ok, reinforced}
          end
        end,
        :reinforced,
        operation_fingerprint({:reinforced, id, fingerprint_provenance(opts)}),
        id
      )
    end
  end

  def reinforce(_id, opts) do
    with :ok <- validate_mutation_scope(opts), do: {:error, :not_found}
  end

  defp reinforce_query(query) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    query = select(query, [e], e)

    case Repo.update_all(query,
           inc: [reinforced_count: 1],
           set: [short_term: false, expires_at: nil, last_reinforced_at: now, updated_at: now]
         ) do
      {1, [reinforced]} -> {:ok, reinforced}
      {0, []} -> {:error, :not_found}
    end
  end

  @doc """
  Create a synapse between two engrams.
  """
  @spec associate(integer(), integer(), atom(), keyword()) ::
          {:ok, Synapse.t()}
          | {:error, Ecto.Changeset.t() | :invalid_scope | :not_found | :scope_mismatch}
  def associate(source_id, target_id, kind, opts \\ [])

  def associate(source_id, target_id, kind, opts)
      when is_integer(source_id) and is_integer(target_id) do
    with :ok <- validate_mutation_scope(opts),
         {:ok, source} <- fetch_active_scoped(source_id, opts),
         {:ok, target} <- fetch_active_scoped(target_id, opts),
         :ok <- ensure_same_identity(source, target) do
      insert_synapse(source_id, target_id, kind)
    end
  end

  def associate(_source_id, _target_id, _kind, opts) do
    with :ok <- validate_mutation_scope(opts), do: {:error, :not_found}
  end

  defp insert_synapse(source_id, target_id, kind) do
    %Synapse{}
    |> Synapse.changeset(%{source_id: source_id, target_id: target_id, kind: kind})
    |> Repo.insert(on_conflict: :nothing)
  end

  @doc """
  Find an active same-kind engram whose normalized content matches exactly.

  Exact matching normalizes Unicode to NFC, trims the ends, and collapses
  Unicode whitespace. Scope validation remains owned by this module so callers
  such as reflection never need to query the repository directly.
  """
  @spec find_active_exact(String.t(), atom(), keyword()) ::
          {:ok, Engram.t()} | :none | {:error, :invalid_scope}
  def find_active_exact(content, kind, opts)
      when is_binary(content) and kind in @engram_kinds do
    with :ok <- validate_mutation_scope(opts) do
      normalized_content = normalize_content(content)
      now = DateTime.utc_now()

      Engram
      |> where([e], e.kind == ^kind)
      |> apply_lifecycle_filter(:active, now)
      |> apply_scope_filter(opts)
      |> Repo.all()
      |> Enum.find(&(normalize_content(&1.content) == normalized_content))
      |> case do
        nil -> :none
        engram -> {:ok, engram}
      end
    end
  end

  def find_active_exact(_content, _kind, opts) do
    with :ok <- validate_mutation_scope(opts), do: :none
  end

  @doc false
  @spec validate_scope(keyword()) :: :ok | {:error, :invalid_scope}
  def validate_scope(opts), do: validate_mutation_scope(opts)

  @doc "Update the correctable fields of a scoped engram."
  @spec update(integer(), map(), keyword()) ::
          {:ok, Engram.t()} | {:error, Ecto.Changeset.t() | :invalid_scope | :not_found}
  def update(id, attrs, opts \\ [])

  def update(id, attrs, opts) when is_integer(id) and is_map(attrs) do
    with :ok <- validate_mutation_scope(opts) do
      semantic_attrs = Map.take(attrs, [:content, "content", :kind, "kind"])

      transactional_write(
        opts,
        fn event_opts ->
          with {:ok, engram} <- fetch_active_scoped(id, opts),
               {:ok, updated} <- update_semantic_fields(engram, semantic_attrs),
               {:ok, updated} <- record_update_if_changed(engram, updated, event_opts) do
            {:ok, updated}
          end
        end,
        :updated,
        operation_fingerprint({:updated, id, semantic_attrs, fingerprint_provenance(opts)}),
        id
      )
    end
  end

  def update(_id, _attrs, opts) do
    with :ok <- validate_mutation_scope(opts), do: {:error, :not_found}
  end

  @doc "Read the authorized provenance projection for a scoped engram."
  @spec provenance(integer(), keyword()) ::
          {:ok, [map()]} | {:error, :invalid_scope | :not_found}
  def provenance(id, opts \\ [])

  def provenance(id, opts) when is_integer(id) do
    with {:ok, projections} <- provenance_many([id], opts),
         {:ok, events} <- Map.fetch(projections, id) do
      {:ok, events}
    else
      :error -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def provenance(_id, opts) do
    with :ok <- validate_mutation_scope(opts), do: {:error, :not_found}
  end

  @doc "Read authorized provenance projections for multiple scoped engrams."
  @spec provenance_many([integer()], keyword()) ::
          {:ok, %{integer() => [map()]}} | {:error, :invalid_scope | :not_found}
  def provenance_many(ids, opts \\ [])

  def provenance_many(ids, opts) when is_list(ids) do
    with :ok <- validate_mutation_scope(opts),
         {:ok, ids} <- normalize_engram_ids(ids) do
      scoped_ids =
        Engram
        |> where([engram], engram.id in ^ids)
        |> apply_scope_filter(opts)
        |> select([engram], engram.id)
        |> Repo.all()

      events =
        EngramEvent
        |> where([event], event.engram_id in ^scoped_ids)
        |> order_by([event], asc: event.engram_id, asc: event.id)
        |> preload([event],
          provenances: ^from(source in Handbean.Memory.EngramProvenance, order_by: source.id)
        )
        |> Repo.all()

      projected = Provenance.project(events, Keyword.get(opts, :workspace_id))
      initial = Map.new(scoped_ids, &{&1, []})

      projections =
        events
        |> Enum.zip(projected)
        |> Enum.reduce(initial, fn {event, projection}, acc ->
          Map.update!(acc, event.engram_id, &[projection | &1])
        end)
        |> Map.new(fn {id, projections} -> {id, Enum.reverse(projections)} end)

      {:ok, projections}
    end
  end

  def provenance_many(_ids, opts) do
    with :ok <- validate_mutation_scope(opts), do: {:error, :not_found}
  end

  defp normalize_engram_ids(ids) do
    if Enum.all?(ids, &(is_integer(&1) and &1 > 0)),
      do: {:ok, Enum.uniq(ids)},
      else: {:error, :not_found}
  end

  @doc "Delete an engram visible in the explicit mutation scope."
  @spec delete(integer(), keyword()) ::
          {:ok, Engram.t()} | {:error, Ecto.Changeset.t() | :invalid_scope | :not_found}
  def delete(id, opts \\ [])

  def delete(id, opts) when is_integer(id) do
    with :ok <- validate_mutation_scope(opts),
         {:ok, engram} <- fetch_scoped(id, opts) do
      Repo.delete(engram)
    end
  end

  def delete(_id, opts) do
    with :ok <- validate_mutation_scope(opts), do: {:error, :not_found}
  end

  defp update_semantic_fields(engram, attrs) do
    attrs = Map.take(attrs, [:content, "content", :kind, "kind"])

    changeset =
      engram
      |> Engram.changeset(attrs)
      |> require_update_change()

    if changeset.valid? do
      if map_size(changeset.changes) == 0 do
        {:ok, engram}
      else
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        revision = engram.revision + 1
        content = Ecto.Changeset.get_field(changeset, :content)
        kind = Ecto.Changeset.get_field(changeset, :kind)

        query =
          Engram
          |> where([candidate], candidate.id == ^engram.id)
          |> where([candidate], candidate.revision == ^engram.revision)
          |> select([candidate], candidate)

        case Repo.update_all(query,
               set: [content: content, kind: kind, revision: revision, updated_at: now]
             ) do
          {1, [updated]} -> {:ok, updated}
          {0, []} -> {:error, :conflict}
        end
      end
    else
      {:error, changeset}
    end
  end

  defp record_update_if_changed(
         %Engram{revision: revision},
         %Engram{revision: revision} = updated,
         opts
       ) do
    case provenance_idempotency_key(opts) do
      key when is_binary(key) and key != "" ->
        with {:ok, _event} <- Provenance.record(updated, :observed, opts), do: {:ok, updated}

      _ ->
        {:ok, updated}
    end
  end

  defp record_update_if_changed(_before, updated, opts) do
    with {:ok, _event} <- Provenance.record(updated, :updated, opts), do: {:ok, updated}
  end

  defp transactional_write(opts, operation, operation_kind, fingerprint, expected_id \\ nil) do
    event_opts =
      opts
      |> Keyword.put(:provenance_operation, operation_kind)
      |> Keyword.put(:provenance_request_fingerprint, fingerprint)

    case Repo.transaction(fn ->
           case idempotent_scoped_engram(event_opts, operation_kind, fingerprint, expected_id) do
             {:ok, engram} ->
               engram

             :none ->
               case operation.(event_opts) do
                 {:ok, engram} -> engram
                 {:error, reason} -> Repo.rollback(reason)
               end

             {:error, reason} ->
               Repo.rollback(reason)
           end
         end) do
      {:ok, engram} ->
        {:ok, engram}

      {:error, :idempotency_conflict} ->
        resolve_idempotency_race(event_opts, operation_kind, fingerprint, expected_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_idempotency_race(opts, operation, fingerprint, expected_id) do
    case idempotent_scoped_engram(opts, operation, fingerprint, expected_id) do
      {:ok, engram} -> {:ok, engram}
      _other -> {:error, :idempotency_conflict}
    end
  end

  defp idempotent_scoped_engram(opts, operation, fingerprint, expected_id) do
    case Provenance.idempotent_engram(opts, operation, fingerprint) do
      {:ok, engram} when is_nil(expected_id) or engram.id == expected_id ->
        case Repo.one(scoped_id_query(engram.id, opts)) do
          nil -> {:error, :idempotency_conflict}
          scoped -> {:ok, scoped}
        end

      {:ok, _engram} ->
        {:error, :idempotency_conflict}

      {:error, :idempotency_conflict} = error ->
        error

      :none ->
        :none
    end
  end

  defp provenance_idempotency_key(opts) do
    provenance = Keyword.get(opts, :provenance, %{})
    Map.get(provenance, :idempotency_key) || Map.get(provenance, "idempotency_key")
  end

  defp fingerprint_provenance(opts) do
    opts
    |> Keyword.get(:provenance, %{})
    |> Map.drop([:idempotency_key, "idempotency_key"])
  end

  defp operation_fingerprint(term), do: Fingerprint.hash(term)

  defp insert_engram(content, kind, metadata, opts) do
    %Engram{}
    |> Engram.changeset(
      %{
        content: content,
        kind: kind,
        short_term: Keyword.get(opts, :short_term, true),
        metadata: metadata
      },
      ttl_hours: Keyword.get(opts, :ttl_hours, 24)
    )
    |> Repo.insert()
  end

  defp require_update_change(%Ecto.Changeset{params: params} = changeset)
       when is_map(params) and map_size(params) > 0,
       do: changeset

  defp require_update_change(changeset),
    do: Ecto.Changeset.add_error(changeset, :base, "content or kind is required")

  defp fetch_scoped(id, opts) do
    case Repo.one(scoped_id_query(id, opts)) do
      nil -> {:error, :not_found}
      engram -> {:ok, engram}
    end
  end

  defp fetch_active_scoped(id, opts) do
    case Repo.one(active_scoped_id_query(id, opts)) do
      nil -> {:error, :not_found}
      engram -> {:ok, engram}
    end
  end

  defp active_scoped_id_query(id, opts) do
    id
    |> scoped_id_query(opts)
    |> apply_lifecycle_filter(:active, DateTime.utc_now())
  end

  defp scoped_id_query(id, opts) do
    Engram
    |> where([e], e.id == ^id)
    |> apply_scope_filter(opts)
  end

  defp ensure_same_identity(source, target) do
    if memory_identity(source) == memory_identity(target) and memory_identity(source) != :invalid,
      do: :ok,
      else: {:error, :scope_mismatch}
  end

  defp memory_identity(engram) do
    case {metadata_value(engram, "scope"), metadata_value(engram, "workspace_id")} do
      {"global", _workspace_id} ->
        {:global}

      {"workspace", workspace_id} when is_binary(workspace_id) and workspace_id != "" ->
        {:workspace, workspace_id}

      _other ->
        :invalid
    end
  end

  defp write_identity(opts) do
    scope = scope_option(opts)
    workspace_id = Keyword.get(opts, :workspace_id)
    privacy_mode = privacy_mode_option(opts)

    cond do
      privacy_mode == :invalid ->
        {:error, :invalid_scope}

      privacy_mode == :local_only and scope == :global ->
        {:error, :invalid_scope}

      scope in [:workspace, :both] and valid_workspace_id?(workspace_id) ->
        {:ok,
         %{
           "scope" => "workspace",
           "workspace_id" => workspace_id,
           "privacy_mode" => Atom.to_string(privacy_mode)
         }}

      scope == :global ->
        {:ok, %{"scope" => "global", "privacy_mode" => Atom.to_string(privacy_mode)}}

      true ->
        {:error, :invalid_scope}
    end
  end

  defp validate_mutation_scope(opts) do
    scope = scope_option(opts)
    workspace_id = Keyword.get(opts, :workspace_id)
    privacy_mode = privacy_mode_option(opts)

    cond do
      privacy_mode == :invalid ->
        {:error, :invalid_scope}

      privacy_mode == :local_only and scope == :global ->
        {:error, :invalid_scope}

      scope in [:workspace, :both] and not valid_workspace_id?(workspace_id) ->
        {:error, :invalid_scope}

      scope in [:workspace, :global, :both] ->
        :ok

      true ->
        {:error, :invalid_scope}
    end
  end

  defp scope_option(opts) do
    opts
    |> Keyword.get(:memory_scope, Keyword.get(opts, :scope))
    |> normalize_scope()
  end

  defp privacy_mode_option(opts) do
    case Keyword.fetch(opts, :privacy_mode) do
      :error -> :standard
      {:ok, mode} -> normalize_privacy_mode(mode) || :invalid
    end
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp normalize_content(content) when is_binary(content) do
    content
    |> String.normalize(:nfc)
    |> String.trim()
    |> String.replace(~r/\s+/u, " ")
  end

  defp normalize_content(_content), do: ""

  defp preload_visible_synapses([]), do: []

  defp preload_visible_synapses(engrams) do
    visible_ids = MapSet.new(engrams, & &1.id)

    engrams
    |> Repo.preload([:source_synapses, :target_synapses])
    |> Enum.map(fn engram ->
      %{
        engram
        | source_synapses:
            Enum.filter(engram.source_synapses, &MapSet.member?(visible_ids, &1.target_id)),
          target_synapses:
            Enum.filter(engram.target_synapses, &MapSet.member?(visible_ids, &1.source_id))
      }
    end)
  end

  @doc """
  Clean up expired short-term engrams.
  """
  @spec cleanup_expired() :: {integer(), nil}
  def cleanup_expired do
    {count, _} =
      from(e in Engram, where: e.short_term == true and e.expires_at < ^DateTime.utc_now())
      |> Repo.delete_all()

    {count, nil}
  end

  defp lifecycle_counts(query, now) do
    query
    |> select([engram], %{
      active:
        fragment(
          "COALESCE(SUM(CASE WHEN ? = 0 OR (? = 1 AND ? IS NOT NULL AND ? > ?) THEN 1 ELSE 0 END), 0)",
          engram.short_term,
          engram.short_term,
          engram.expires_at,
          engram.expires_at,
          ^now
        ),
      long_term:
        fragment(
          "COALESCE(SUM(CASE WHEN ? = 0 THEN 1 ELSE 0 END), 0)",
          engram.short_term
        ),
      short_term:
        fragment(
          "COALESCE(SUM(CASE WHEN ? = 1 AND ? IS NOT NULL AND ? > ? THEN 1 ELSE 0 END), 0)",
          engram.short_term,
          engram.expires_at,
          engram.expires_at,
          ^now
        ),
      expired:
        fragment(
          "COALESCE(SUM(CASE WHEN ? = 1 AND ? IS NOT NULL AND ? <= ? THEN 1 ELSE 0 END), 0)",
          engram.short_term,
          engram.expires_at,
          engram.expires_at,
          ^now
        )
    })
    |> Repo.one!()
  end

  defp apply_list_scope_filter(query, opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    privacy_mode = privacy_mode_option(opts)

    cond do
      privacy_mode == :invalid ->
        where_none(query)

      privacy_mode == :local_only and valid_workspace_id?(workspace_id) ->
        where_workspace(query, workspace_id)

      privacy_mode == :local_only ->
        where_none(query)

      true ->
        scope =
          opts
          |> Keyword.get(:scope, Keyword.get(opts, :memory_scope, :workspace))
          |> normalize_scope()

        case scope do
          :workspace ->
            if valid_workspace_id?(workspace_id),
              do: where_workspace(query, workspace_id),
              else: where_none(query)

          :global ->
            where_global(query)

          :both ->
            if valid_workspace_id?(workspace_id),
              do: where_workspace_or_global(query, workspace_id),
              else: where_shareable_global(query)

          _other ->
            where_none(query)
        end
    end
  end

  defp apply_list_query(query, value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        query

      match = Regex.run(~r/^#?(\d+)$/, value) ->
        [_, id] = match
        where(query, [e], e.id == ^String.to_integer(id))

      true ->
        where(query, [e], fragment("instr(lower(?), lower(?)) > 0", e.content, ^value))
    end
  end

  defp apply_list_query(query, _value), do: query

  defp apply_kind_filter(query, nil), do: query
  defp apply_kind_filter(query, :all), do: query
  defp apply_kind_filter(query, "all"), do: query

  defp apply_kind_filter(query, kind) do
    case normalize_kind(kind) do
      nil -> where(query, [e], e.id < 0)
      normalized -> where(query, [e], e.kind == ^normalized)
    end
  end

  defp apply_lifecycle_filter(query, lifecycle, now) do
    case normalize_lifecycle(lifecycle) do
      :active ->
        where(
          query,
          [e],
          e.short_term == false or
            (e.short_term == true and not is_nil(e.expires_at) and e.expires_at > ^now)
        )

      :long_term ->
        where(query, [e], e.short_term == false)

      :short_term ->
        where(
          query,
          [e],
          e.short_term == true and not is_nil(e.expires_at) and e.expires_at > ^now
        )

      :expired ->
        where(
          query,
          [e],
          e.short_term == true and not is_nil(e.expires_at) and e.expires_at <= ^now
        )

      :all ->
        query

      nil ->
        where(query, [e], e.id < 0)
    end
  end

  defp normalize_kind(kind) when kind in @engram_kinds, do: kind

  defp normalize_kind(kind) when is_binary(kind) do
    Enum.find(@engram_kinds, &(Atom.to_string(&1) == kind))
  end

  defp normalize_kind(_kind), do: nil

  defp normalize_lifecycle(lifecycle) when lifecycle in @lifecycle_filters, do: lifecycle

  defp normalize_lifecycle(lifecycle) when is_binary(lifecycle) do
    Enum.find(@lifecycle_filters, &(Atom.to_string(&1) == lifecycle))
  end

  defp normalize_lifecycle(_lifecycle), do: nil

  # ── Scope / Privacy Filtering ──

  @doc false
  def apply_scope_filter(query, opts) do
    memory_scope = scope_option(opts)
    privacy_mode = privacy_mode_option(opts)
    workspace_id = Keyword.get(opts, :workspace_id)

    cond do
      privacy_mode == :invalid ->
        where_none(query)

      privacy_mode == :local_only and valid_workspace_id?(workspace_id) ->
        where_workspace(query, workspace_id)

      privacy_mode == :local_only ->
        where_none(query)

      memory_scope == :workspace and valid_workspace_id?(workspace_id) ->
        where_workspace(query, workspace_id)

      memory_scope == :workspace ->
        where_none(query)

      memory_scope == :global ->
        where_global(query)

      memory_scope == :both and valid_workspace_id?(workspace_id) ->
        where_workspace_or_global(query, workspace_id)

      memory_scope == :both ->
        where_shareable_global(query)

      true ->
        where_none(query)
    end
  end

  defp where_workspace(query, workspace_id) do
    where(
      query,
      [e],
      fragment("json_extract(?, '$.scope')", e.metadata) == "workspace" and
        fragment("json_extract(?, '$.workspace_id')", e.metadata) == ^workspace_id
    )
  end

  defp where_global(query) do
    where(query, [e], fragment("json_extract(?, '$.scope')", e.metadata) == "global")
  end

  defp where_shareable_global(query) do
    where(
      query,
      [e],
      fragment("json_extract(?, '$.scope')", e.metadata) == "global" and
        fragment("coalesce(json_extract(?, '$.privacy_mode'), '')", e.metadata) != "local_only"
    )
  end

  defp where_none(query), do: where(query, [e], e.id < 0)

  defp valid_workspace_id?(workspace_id),
    do: is_binary(workspace_id) and String.trim(workspace_id) != ""

  defp where_workspace_or_global(query, workspace_id) do
    where(
      query,
      [e],
      fragment("json_extract(?, '$.scope')", e.metadata) == "global" or
        (fragment("json_extract(?, '$.scope')", e.metadata) == "workspace" and
           fragment("json_extract(?, '$.workspace_id')", e.metadata) == ^workspace_id)
    )
  end

  defp normalize_scope(scope) when scope in [:global, :workspace, :both], do: scope

  defp normalize_scope(scope) when scope in ["global", "workspace", "both"],
    do: String.to_existing_atom(scope)

  defp normalize_scope(_), do: nil

  defp normalize_privacy_mode(mode) when mode in [:standard, :local_only], do: mode
  defp normalize_privacy_mode("standard"), do: :standard
  defp normalize_privacy_mode("local_only"), do: :local_only
  defp normalize_privacy_mode(_), do: nil

  defp metadata_value(%Engram{metadata: metadata}, key), do: metadata_value(metadata, key)

  defp metadata_value(metadata, key) when is_map(metadata),
    do: Handbean.Utils.SafeMap.get(metadata, key)

  defp metadata_value(_, _), do: nil
end
