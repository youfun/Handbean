defmodule Handbean.Memory.MemoryStore.Recall do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Handbean.Memory.Engram
  alias Handbean.Memory.MemoryStore
  alias Handbean.Repo

  @recall_stop_words MapSet.new(
                       ~w(handbean the and for with this that from are use not you should what when how why can does have into will but was were been they them their there then than your our who which where all about would could we do to of in on at is it be or as if so an by 这个 那个 什么 怎么 为什么 可以 需要 已经 我们 你们 一下 现在 然后 没有 是否 问题 一个)
                     )
  @recall_token_limit 16
  @recall_separators ~r/[\p{P}]+/u
  @han_grapheme ~r/^\p{Han}$/u

  @spec recall(String.t(), keyword()) :: [Engram.t()]
  def recall(query, opts) do
    case recall_tokens(query, opts) do
      [] -> []
      tokens -> recall_scored(tokens, opts)
    end
  end

  defp recall_tokens(query, opts) when is_binary(query) do
    tokens =
      query
      |> String.downcase()
      |> String.replace(@recall_separators, " ")
      |> String.split(~r/\s+/u, trim: true)
      |> Enum.flat_map(&expand_recall_token/1)
      |> Enum.reduce({[], MapSet.new()}, fn token, {tokens, seen} ->
        if usable_recall_token?(token) and not MapSet.member?(seen, token),
          do: {[token | tokens], MapSet.put(seen, token)},
          else: {tokens, seen}
      end)
      |> elem(0)
      |> Enum.reverse()

    select_recall_tokens(tokens, Keyword.get(opts, :token_window, :head))
  end

  defp recall_tokens(_query, _opts), do: []

  defp select_recall_tokens(tokens, :head_tail) do
    if length(tokens) <= @recall_token_limit do
      tokens
    else
      half = div(@recall_token_limit, 2)
      Enum.take(tokens, half) ++ Enum.take(tokens, -half)
    end
  end

  defp select_recall_tokens(tokens, _strategy), do: Enum.take(tokens, @recall_token_limit)

  defp expand_recall_token(token) do
    token
    |> String.graphemes()
    |> Enum.chunk_by(&han_grapheme?/1)
    |> Enum.flat_map(fn graphemes ->
      if han_grapheme?(hd(graphemes)) and length(graphemes) > 4,
        do: graphemes |> Enum.chunk_every(2, 1, :discard) |> Enum.map(&Enum.join/1),
        else: [Enum.join(graphemes)]
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
    ids = Enum.uniq(Map.keys(bm25) ++ short_token_ids(short_tokens, opts))

    if ids == [] do
      []
    else
      min_matches = required_matches(tokens, opts)

      Engram
      |> where([e], e.id in ^ids)
      |> where([e], is_nil(e.expires_at) or e.expires_at > ^DateTime.utc_now())
      |> MemoryStore.apply_scope_filter(opts)
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

  defp short_token_ids([], _opts), do: []

  defp short_token_ids(tokens, opts) do
    condition =
      Enum.reduce(tokens, dynamic(false), fn token, condition ->
        dynamic([e], ^condition or fragment("instr(lower(?), ?) > 0", e.content, ^token))
      end)

    Engram
    |> where(^condition)
    |> where([e], is_nil(e.expires_at) or e.expires_at > ^DateTime.utc_now())
    |> MemoryStore.apply_scope_filter(opts)
    |> select([e], e.id)
    |> Repo.all()
  end

  defp required_matches(tokens, opts) do
    count = length(tokens)

    base =
      case Keyword.get(opts, :min_matches) do
        n when is_integer(n) and n > 0 -> n
        _ -> if(count >= 2, do: 2, else: 1)
      end

    percent =
      case Keyword.get(opts, :match_percent, 30) do
        value when is_integer(value) and value in 1..100 -> value
        _other -> 30
      end

    proportional = div(count * percent + 99, 100)
    required = min(count, max(min(base, count), proportional))

    case Keyword.get(opts, :max_required_matches) do
      value when is_integer(value) and value > 0 -> min(required, value)
      _other -> required
    end
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
end
