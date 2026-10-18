defmodule Handbean.Memory.MemoryStore do
  @moduledoc """
  Memory store — CRUD operations for engrams and synapses.

  Owns scope validation for recall, learn, reinforce, associate, update,
  and delete operations.
  """

  import Ecto.Query, warn: false

  alias Handbean.Memory.{Engram, Synapse}
  alias Handbean.Repo

  # Function words that show up in almost every sentence and should not drive a match.
  @recall_stop_words MapSet.new(
                       ~w(handbean the and for with this that from are use not you should what when how why can does have into will but was were been they them their there then than your our who which where all about would could we do to of in on at is it be or as if so an by 这个 那个 什么 怎么 为什么 可以 需要 已经 我们 你们 一下 现在 然后 没有 是否 问题 一个)
                     )
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
  # Underscore, hyphen, slash, dot, colon, and other punctuation (including CJK).
  @recall_separators ~r/[\p{P}]+/u
  @han_grapheme ~r/^\p{Han}$/u

  @doc """
  Recall engrams matching a keyword query.

  The query is downcased, punctuation is treated as whitespace, and tokens are
  deduped. At most the first #{@recall_token_limit} usable tokens are kept.
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
  `max(base, ceil(0.3 * token_count))`, also capped to the token count.
  Results are then ordered by how many tokens matched, FTS bm25, long-term
  first, reinforcement, and recency.

  ## Options

    * `:limit` — max results after scoring (default 10)
    * `:min_matches` — base token overlap required, before the proportional floor
  """
  @spec recall(String.t(), keyword()) :: [Engram.t()]
  def recall(query, opts \\ []) do
    case recall_tokens(query) do
      [] ->
        []

      tokens ->
        recall_scored(tokens, opts)
    end
  end

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

      insert_engram(content, kind, metadata, opts)
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

    %{
      active: count_lifecycle(base_query, :active, now),
      long_term: count_lifecycle(base_query, :long_term, now),
      short_term: count_lifecycle(base_query, :short_term, now),
      expired: count_lifecycle(base_query, :expired, now),
      by_kind: Map.new(@engram_kinds, &{&1, Map.get(kind_counts, &1, 0)})
    }
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
      reinforce_query(scoped_id_query(id, opts))
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
    with :ok <- validate_mutation_scope(opts) do
      Repo.transaction(fn ->
        with {:ok, source} <- fetch_scoped(source_id, opts),
             {:ok, target} <- fetch_scoped(target_id, opts),
             :ok <- ensure_same_identity(source, target),
             {:ok, synapse} <- insert_synapse(source_id, target_id, kind) do
          synapse
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
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
    with :ok <- validate_mutation_scope(opts),
         {:ok, engram} <- fetch_scoped(id, opts) do
      attrs = Map.take(attrs, [:content, "content", :kind, "kind"])

      engram
      |> Engram.changeset(attrs)
      |> require_update_change()
      |> Repo.update()
    end
  end

  def update(_id, _attrs, opts) do
    with :ok <- validate_mutation_scope(opts), do: {:error, :not_found}
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

  defp recall_tokens(query) when is_binary(query) do
    pieces =
      query
      |> String.downcase()
      |> String.replace(@recall_separators, " ")
      |> String.split(~r/\s+/u, trim: true)
      |> Enum.flat_map(&expand_recall_token/1)

    {tokens, _seen, _count} =
      Enum.reduce_while(pieces, {[], MapSet.new(), 0}, fn token, {tokens, seen, count} ->
        cond do
          count >= @recall_token_limit ->
            {:halt, {tokens, seen, count}}

          not usable_recall_token?(token) or MapSet.member?(seen, token) ->
            {:cont, {tokens, seen, count}}

          true ->
            {:cont, {[token | tokens], MapSet.put(seen, token), count + 1}}
        end
      end)

    Enum.reverse(tokens)
  end

  defp recall_tokens(_query), do: []

  defp expand_recall_token(token) do
    token
    |> String.graphemes()
    |> Enum.chunk_by(&han_grapheme?/1)
    |> Enum.flat_map(fn graphemes ->
      cond do
        han_grapheme?(hd(graphemes)) and length(graphemes) > 4 ->
          graphemes |> Enum.chunk_every(2, 1, :discard) |> Enum.map(&Enum.join/1)

        true ->
          [Enum.join(graphemes)]
      end
    end)
  end

  defp han_grapheme?(grapheme), do: String.match?(grapheme, @han_grapheme)

  defp usable_recall_token?(token) do
    String.length(token) >= 2 and not MapSet.member?(@recall_stop_words, token)
  end

  defp recall_scored(tokens, opts) do
    limit = Keyword.get(opts, :limit, 10)
    long_tokens = Enum.filter(tokens, &(String.length(&1) >= 3))
    short_tokens = Enum.filter(tokens, &(String.length(&1) == 2))
    bm25 = fts_bm25(long_tokens)
    ids = Enum.uniq(Map.keys(bm25) ++ short_token_ids(short_tokens))

    if ids == [] do
      []
    else
      min_matches = required_matches(tokens, opts)

      Engram
      |> where([e], e.id in ^ids)
      |> where([e], is_nil(e.expires_at) or e.expires_at > ^DateTime.utc_now())
      |> apply_scope_filter(opts)
      |> Repo.all()
      |> Enum.map(fn engram -> {matched_token_count(engram.content, tokens), engram} end)
      |> Enum.filter(fn {count, _engram} -> count >= min_matches end)
      |> Enum.sort_by(fn {count, engram} -> recall_sort_key(count, engram, bm25) end)
      |> Enum.take(limit)
      |> Enum.map(fn {_count, engram} -> engram end)
    end
  end

  defp fts_bm25([]), do: %{}

  defp fts_bm25(tokens) do
    %{rows: rows} =
      Repo.query!(
        "SELECT rowid, bm25(engrams_fts) FROM engrams_fts WHERE engrams_fts MATCH ?",
        [fts_match(tokens)]
      )

    Map.new(rows, fn [rowid, score] -> {rowid, score} end)
  end

  defp fts_match(tokens) do
    Enum.map_join(tokens, " OR ", fn token ->
      ~s|"#{String.replace(token, "\"", "\"\"")}"|
    end)
  end

  defp short_token_ids([]), do: []

  defp short_token_ids(tokens) do
    clauses = Enum.map(tokens, fn _token -> "instr(lower(content), ?) > 0" end)
    sql = "SELECT id FROM engrams WHERE " <> Enum.join(clauses, " OR ")
    %{rows: rows} = Repo.query!(sql, tokens)
    Enum.map(rows, fn [id] -> id end)
  end

  defp required_matches(tokens, opts) do
    count = length(tokens)

    base =
      case Keyword.get(opts, :min_matches) do
        n when is_integer(n) and n > 0 -> n
        _ -> if(count >= 2, do: 2, else: 1)
      end

    # ceil(0.3 * count). Exact for the 16-token cap.
    proportional = div(count * 3 + 9, 10)
    min(count, max(min(base, count), proportional))
  end

  defp matched_token_count(content, tokens) do
    lowered = String.downcase(content || "")
    Enum.count(tokens, &String.contains?(lowered, &1))
  end

  defp recall_sort_key(count, engram, bm25) do
    bm25_key =
      case Map.fetch(bm25, engram.id) do
        {:ok, score} -> {0, score}
        :error -> {1, 0.0}
      end

    {
      -count,
      bm25_key,
      if(engram.short_term, do: 1, else: 0),
      -(engram.reinforced_count || 0),
      recall_updated_desc(engram)
    }
  end

  defp recall_updated_desc(%{updated_at: %DateTime{} = updated_at}),
    do: -DateTime.to_unix(updated_at, :microsecond)

  defp recall_updated_desc(_engram), do: 0

  defp count_lifecycle(query, lifecycle, now) do
    query
    |> apply_lifecycle_filter(lifecycle, now)
    |> Repo.aggregate(:count, :id)
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

  defp apply_scope_filter(query, opts) do
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
