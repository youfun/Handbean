defmodule Handbean.CodeIndex.Search do
  @moduledoc """
  FTS and optional vector search with reciprocal rank fusion.

  An empty or timed-out vector side does not dilute FTS scores. Keyword mode
  never calls an embedder.
  """

  alias Handbean.CodeIndex.{Embedder, Store}

  @rrf_k 60

  @spec query(Store.t(), String.t(), pos_integer(), keyword()) :: [map()]
  def query(store, text, limit, opts \\ []) do
    fts =
      store
      |> Store.search_fts(fts_query(text), limit * 5)
      |> filter_hits(opts)
      |> Enum.take(limit * 3)

    case Keyword.get(opts, :mode, :keyword) do
      :hybrid -> fuse(fts, vectors(store, text, opts), limit)
      _ -> take_fts(fts, limit)
    end
  end

  defp filter_hits(hits, opts) do
    path = Keyword.get(opts, :path)
    glob = Keyword.get(opts, :glob)

    Enum.filter(hits, fn hit ->
      path_ok?(hit.path, path) and glob_ok?(hit.path, glob)
    end)
  end

  defp path_ok?(_hit, prefix) when prefix in [nil, ""], do: true

  defp path_ok?(hit, prefix) do
    normalized = prefix |> to_string() |> String.trim_leading("./") |> String.trim_trailing("/")
    hit == normalized or String.starts_with?(hit, normalized <> "/")
  end

  defp glob_ok?(_hit, glob) when glob in [nil, ""], do: true

  defp glob_ok?(hit, glob) do
    String.ends_with?(hit, glob |> to_string() |> String.trim_leading("*"))
  end

  @doc false
  def fuse(fts, [], limit), do: take_fts(fts, limit)
  def fuse([], vectors, limit), do: take_vectors(vectors, limit)

  def fuse(fts, vectors, limit) do
    scores =
      %{}
      |> add_ranks(fts, &key/1)
      |> add_ranks(vectors, &key/1)

    by_key =
      (fts ++ vectors)
      |> Enum.reduce(%{}, fn hit, acc -> Map.put_new(acc, key(hit), hit) end)

    scores
    |> Enum.map(fn {id, score} ->
      hit = Map.fetch!(by_key, id)
      Map.put(hit, :score, score)
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  defp vectors(store, text, opts) do
    embedder = Keyword.get(opts, :embedder, Embedder.Noop)
    budget = Keyword.get(opts, :vector_budget_ms, 0)
    scan_limit = Keyword.get(opts, :vector_scan_limit, 0)
    deadline = System.monotonic_time(:millisecond) + budget

    with true <- scan_limit > 0 and budget > 0,
         {:ok, config} <- embedder.config(opts),
         {:ok, [query_vec]} <- embedder.embed([text], config),
         true <- System.monotonic_time(:millisecond) < deadline do
      model = config.model

      store
      |> Store.embeddings_for_scan(model, scan_limit)
      |> Enum.reduce_while([], fn row, acc ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:halt, []}
        else
          {:cont, [Map.put(row, :score, dot(query_vec, decode(row.vector))) | acc]}
        end
      end)
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(Keyword.get(opts, :limit, 10) * 3)
    else
      _ -> []
    end
  end

  defp take_fts(hits, limit) do
    hits
    |> Enum.with_index(1)
    |> Enum.take(limit)
    |> Enum.map(fn {hit, rank} -> Map.put(hit, :score, 1 / (@rrf_k + rank)) end)
  end

  defp take_vectors(hits, limit) do
    hits
    |> Enum.take(limit)
    |> Enum.map(fn hit -> Map.put(hit, :score, hit.score) end)
  end

  defp add_ranks(scores, hits, key_fun) do
    hits
    |> Enum.with_index(1)
    |> Enum.reduce(scores, fn {hit, rank}, acc ->
      Map.update(acc, key_fun.(hit), 1 / (@rrf_k + rank), &(&1 + 1 / (@rrf_k + rank)))
    end)
  end

  defp key(hit), do: {hit.path, hit.start_line, hit.end_line}

  @doc false
  def fts_query(text) when is_binary(text) do
    text
    |> String.split(~r/[^\p{L}\p{N}_]+/u, trim: true)
    |> Enum.map(&String.replace(&1, "\"", ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.map_join(" OR ", &~s("#{&1}"))
    |> case do
      "" -> "\"\""
      query -> query
    end
  end

  defp dot(left, right) when length(left) == length(right) do
    left
    |> Enum.zip(right)
    |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
  end

  defp dot(_, _), do: 0.0

  defp decode(blob) when is_binary(blob) do
    for <<value::float-little-32 <- blob>>, do: value
  end

  defp decode(_), do: []
end
