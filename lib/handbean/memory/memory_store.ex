defmodule Handbean.Memory.MemoryStore do
  @moduledoc """
  Memory store — CRUD operations for engrams and synapses.

  Provides recall (search), learn (create), reinforce (strengthen),
  and associate (link) operations.
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

      iex> MemoryStore.learn("User prefers snake_case", :preference)
      {:ok, %Engram{}}
  """
  @spec learn(String.t(), atom(), keyword()) :: {:ok, Engram.t()} | {:error, Ecto.Changeset.t()}
  def learn(content, kind, opts \\ []) do
    %Engram{}
    |> Engram.changeset(%{
      content: content,
      kind: kind,
      short_term: Keyword.get(opts, :short_term, true),
      metadata: Keyword.get(opts, :metadata, %{})
    })
    |> Repo.insert()
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
  """
  @spec list_engrams(keyword()) :: [Engram.t()]
  def list_engrams(opts \\ []) do
    now = DateTime.utc_now()

    Engram
    |> apply_list_scope_filter(opts)
    |> apply_list_query(Keyword.get(opts, :query))
    |> apply_lifecycle_filter(Keyword.get(opts, :lifecycle, :active), now)
    |> apply_kind_filter(Keyword.get(opts, :kind))
    |> order_by([e], asc: e.short_term, desc: e.updated_at, desc: e.id)
    |> Repo.all()
    |> Repo.preload([:source_synapses, :target_synapses])
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
  @spec reinforce(Engram.t()) :: {:ok, Engram.t()} | {:error, Ecto.Changeset.t()}
  def reinforce(%Engram{} = engram) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    changeset = Engram.changeset(engram, %{short_term: false, last_reinforced_at: now})

    if changeset.valid? do
      query = from(e in Engram, where: e.id == ^engram.id, select: e)

      case Repo.update_all(query,
             inc: [reinforced_count: 1],
             set: [short_term: false, expires_at: nil, last_reinforced_at: now, updated_at: now]
           ) do
        {1, [reinforced]} -> {:ok, reinforced}
        {0, []} -> raise Ecto.StaleEntryError, changeset: changeset, action: :update
      end
    else
      {:error, changeset}
    end
  end

  @doc """
  Create a synapse between two engrams.
  """
  @spec associate(Engram.t(), Engram.t(), atom()) ::
          {:ok, Synapse.t()} | {:error, Ecto.Changeset.t()}
  def associate(%Engram{id: source_id}, %Engram{id: target_id}, kind) do
    %Synapse{}
    |> Synapse.changeset(%{source_id: source_id, target_id: target_id, kind: kind})
    |> Repo.insert(on_conflict: :nothing)
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
      |> Repo.preload([:source_synapses, :target_synapses])
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

    case normalize_scope(Keyword.get(opts, :scope, :workspace)) do
      :workspace when is_binary(workspace_id) and workspace_id != "" ->
        where_workspace(query, workspace_id)

      :global ->
        where_global(query)

      :both when is_binary(workspace_id) and workspace_id != "" ->
        where_workspace_or_global(query, workspace_id)

      :both ->
        where_global(query)

      _other ->
        where(query, [e], e.id < 0)
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
    memory_scope = normalize_scope(Keyword.get(opts, :memory_scope))
    privacy_mode = normalize_privacy_mode(Keyword.get(opts, :privacy_mode))
    workspace_id = Keyword.get(opts, :workspace_id)

    cond do
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
        query
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
