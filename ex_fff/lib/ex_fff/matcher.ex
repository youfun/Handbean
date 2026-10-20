defmodule ExFff.Matcher do
  @moduledoc """
  Fuzzy path matching engine for ExFff.

  Provides tokenization of file paths into trigrams and tiered scoring.
  Match quality (exact name, filename, path, fuzzy) outranks frecency.
  Frecency decays with a 7-day half-life and only reorders a tier.
  """

  # Half-life decay replaces the old unbounded `old * 0.9 + 100` accumulator.
  @half_life_seconds 7 * 24 * 60 * 60
  @frecency_cap 32.0
  @frecency_boost 1.0
  @frecency_weight 0.2
  @git_boost 0.05
  @similarity_floor 0.5
  @tier_gap 10.0
  # Larger than any within-tier score, so more matched terms always outrank fewer.
  @partial_gap 100.0
  # Reference used only to compress pre-decay persisted scores into the cap.
  @legacy_frecency_span 1000.0

  @doc """
  Tokenize a file path into unique trigrams.

  Splits on `/`, `_`, `-`, `.`, then further splits on case boundaries.
  Each resulting token of length >= 3 graphemes yields sliding-window
  trigrams over **graphemes** (not bytes), so CJK and other multi-byte
  UTF-8 characters are handled correctly.

  Returns `[]` if `path` is not a valid UTF-8 binary (so that callers
  using raw filesystem bytes never crash).

  ## Examples

      iex> ExFff.Matcher.tokenize("lib/user.ex")
      ["lib", "use", "ser"]

  """
  @spec tokenize(String.t()) :: [String.t()]
  def tokenize(path) when is_binary(path) do
    if String.valid?(path) do
      path
      |> String.split(~r{[/_\-\.]})
      |> Enum.flat_map(&split_camel_case/1)
      |> Enum.flat_map(&trigrams/1)
      |> Enum.uniq()
    else
      []
    end
  end

  @doc """
  Advance a frecency score after an access.

  The previous score decays with a 7-day half-life over `elapsed_seconds`,
  then a unit boost is added. The result is capped so repeated touches cannot
  grow without bound. `elapsed_seconds` defaults to `0` (a burst of touches).
  """
  @spec compute_frecency(number(), number()) :: float()
  def compute_frecency(old_score, elapsed_seconds \\ 0)
      when is_number(old_score) and is_number(elapsed_seconds) do
    elapsed = max(elapsed_seconds, 0)
    decayed = max(old_score, 0) * :math.pow(0.5, elapsed / @half_life_seconds)
    min(decayed + @frecency_boost, @frecency_cap)
  end

  @doc """
  Map a persisted frecency value onto the bounded scale.

  Scores already within the cap are kept. Older unbounded accumulators
  (`old * 0.9 + 100`, often hundreds) are log-compressed so their order
  survives without dominating the new scale.
  """
  @spec normalize_stored_frecency(number()) :: float()
  def normalize_stored_frecency(score) when is_number(score) do
    score = max(score * 1.0, 0.0)

    if score <= @frecency_cap do
      score
    else
      (:math.log(1 + score) / :math.log(1 + @legacy_frecency_span) * @frecency_cap)
      |> min(@frecency_cap)
      |> max(0.0)
    end
  end

  @doc false
  @spec decay_frecency(number(), number()) :: float()
  def decay_frecency(score, elapsed_seconds)
      when is_number(score) and is_number(elapsed_seconds) do
    elapsed = max(elapsed_seconds, 0)
    max(score, 0) * :math.pow(0.5, elapsed / @half_life_seconds)
  end

  @doc """
  Match query against the index tables and return scored results.

  Returns a list of maps sorted by descending score. Each map has `path`,
  `score`, and usually `tier` (`:exact`, `:filename`, `:path`, or `:fuzzy`).
  A basename glob that matches nothing is retried against the full relative
  path, with `*` allowed to cross `/`. When two or more terms have an empty
  AND, results are the OR ranked by how many terms matched.

  Arguments:
  - `query` — `%ExFff.Query{}`
  - `files_tab` — ETS table id for Files
  - `trigram_tab` — ETS table id for Trigrams
  - `frecency_tab` — ETS table id for Frecency
  """
  @spec match(ExFff.Query.t(), :ets.tid(), :ets.tid(), :ets.tid()) :: [map()]
  def match(query, files_tab, trigram_tab, frecency_tab) do
    do_match(query, files_tab, trigram_tab, frecency_tab, nil, [])
  end

  @doc false
  @spec match(ExFff.Query.t(), :ets.tid(), :ets.tid(), :ets.tid(), :ets.tid() | nil) :: [map()]
  def match(query, files_tab, trigram_tab, frecency_tab, git_tab) do
    match(query, files_tab, trigram_tab, frecency_tab, git_tab, [])
  end

  @doc false
  def match(query, files_tab, trigram_tab, frecency_tab, git_tab, opts) do
    do_match(query, files_tab, trigram_tab, frecency_tab, git_tab, opts)
  end

  defp do_match(query, files_tab, trigram_tab, frecency_tab, git_tab, opts) do
    now = System.system_time(:second)
    frecency_tab = frecency_scores(frecency_tab, now, opts)
    and_hits = rank(query, files_tab, trigram_tab, frecency_tab, git_tab, now, :and, opts)

    {query, and_hits} =
      if and_hits == [] and basename_globs?(query) do
        widened = widen_basename_globs(query)
        {widened, rank(widened, files_tab, trigram_tab, frecency_tab, git_tab, now, :and, opts)}
      else
        {query, and_hits}
      end

    cond do
      and_hits != [] ->
        and_hits

      length(query.terms) >= 2 ->
        rank(query, files_tab, trigram_tab, frecency_tab, git_tab, now, :or, opts)

      true ->
        []
    end
  end

  defp rank(query, files_tab, trigram_tab, frecency_tab, git_tab, now, mode, opts) do
    prepared =
      query
      |> find_candidates(files_tab, trigram_tab, mode, opts)
      |> Stream.filter(fn path ->
        check_deadline(opts)
        Keyword.get(opts, :path_filter, fn _ -> true end).(path)
      end)
      |> Stream.map(&%{path: &1})
      |> apply_filters(query)
      |> Stream.map(fn candidate ->
        check_deadline(opts)
        prepare_candidate(candidate, query, frecency_tab, git_tab, now, mode)
      end)
      |> Stream.reject(&reject_candidate?(&1, query, mode))
      |> Enum.to_list()

    max_freq =
      Enum.reduce(prepared, 0.0, fn candidate, max_freq ->
        check_deadline(opts)
        max(candidate.freq, max_freq)
      end)

    prepared
    |> Stream.map(&finalize_score(&1, max_freq, mode))
    |> top_results(query.limit, mode, opts)
  end

  defp top_results(results, limit, mode, opts) do
    results
    |> Enum.reduce(:gb_sets.empty(), fn result, kept ->
      check_deadline(opts)
      terms = if mode == :or, do: result.matched_terms, else: 0
      kept = :gb_sets.add({-terms, -result.score, result.path, result}, kept)

      if :gb_sets.size(kept) > limit,
        do: :gb_sets.delete(:gb_sets.largest(kept), kept),
        else: kept
    end)
    |> :gb_sets.to_list()
    |> Enum.map(&elem(&1, 3))
  end

  # ── Candidate Discovery ──

  defp find_candidates(%ExFff.Query{terms: terms}, _files_tab, trigram_tab, :or, opts) do
    terms
    |> Enum.map(&term_path_set(&1, trigram_tab, opts))
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
  end

  defp find_candidates(%ExFff.Query{terms: []}, files_tab, trigram_tab, :and, opts) do
    if :ets.info(files_tab, :size) in [:undefined, 0] do
      trigram_tab
      |> table_rows(opts)
      |> Stream.map(fn {_trigram, path} -> path end)
      |> Enum.reduce(MapSet.new(), &MapSet.put(&2, &1))
    else
      files_tab
      |> table_rows(opts)
      |> Stream.map(fn {path, _meta} -> path end)
    end
  end

  defp find_candidates(%ExFff.Query{terms: terms}, _files_tab, trigram_tab, :and, opts) do
    terms
    |> Enum.map(&term_path_set(&1, trigram_tab, opts))
    |> reduce_intersection()
  end

  defp term_path_set(term, trigram_tab, opts) do
    check_deadline(opts)

    MapSet.union(
      path_set_for_term(term, trigram_tab, opts),
      direct_substring_matches(term, trigram_tab, opts)
    )
  end

  defp path_set_for_term(term, trigram_tab, opts) do
    term
    |> tokenize()
    |> Enum.reduce(MapSet.new(), fn trigram, acc ->
      check_deadline(opts)
      paths = lookup_trigram(trigram, trigram_tab, opts)
      MapSet.union(acc, paths)
    end)
  end

  defp lookup_trigram(trigram, trigram_tab, opts) do
    trigram_tab
    |> select_rows([{{trigram, :"$1"}, [], [:"$1"]}], opts)
    |> Enum.reduce(MapSet.new(), &MapSet.put(&2, &1))
  end

  defp direct_substring_matches(term, trigram_tab, opts) do
    # Also find paths where the term appears as a substring of any token
    # We check by matching any trigram that contains the term as a substring.
    # `String.contains?/2` is byte-level, so it tolerates trigrams that were
    # generated from non-UTF-8-safe sources — but the term still needs to be
    # downcased safely.
    needle = safe_downcase(term)

    # Trigrams contain graphemes, while this legacy match is a byte substring.
    # A needle can begin or end inside a decorated grapheme or a ZWJ sequence,
    # so its standalone grapheme count cannot safely eliminate this scan.
    trigram_tab
    |> table_rows(opts)
    |> Enum.reduce(MapSet.new(), fn {trigram, path}, paths ->
      if is_binary(trigram) and String.contains?(trigram, needle),
        do: MapSet.put(paths, path),
        else: paths
    end)
  end

  defp check_deadline(opts) do
    case Keyword.get(opts, :deadline) do
      deadline when is_integer(deadline) ->
        if System.monotonic_time(:millisecond) >= deadline, do: throw(:search_timeout)

      _ ->
        :ok
    end
  end

  defp reduce_intersection([first | rest]) do
    Enum.reduce(rest, first, &MapSet.intersection/2)
  end

  defp reduce_intersection([]), do: MapSet.new()

  defp table_rows(table, opts), do: select_rows(table, [{:_, [], [:"$_"]}], opts)

  defp select_rows(table, match_spec, opts) do
    Stream.resource(
      fn -> :start end,
      fn
        :"$end_of_table" ->
          {:halt, :"$end_of_table"}

        continuation ->
          check_deadline(opts)

          result =
            if continuation == :start,
              do: :ets.select(table, match_spec, 128),
              else: :ets.select(continuation)

          case result do
            :"$end_of_table" -> {:halt, :"$end_of_table"}
            {rows, next} -> {rows, next}
          end
      end,
      fn _ -> :ok end
    )
  end

  # ── Scoring ──
  #
  # Tiers (exact filename > filename prefix/contains > path contains > fuzzy)
  # are separated by `@tier_gap`, which is larger than any within-tier bonus.
  # Frecency and git status can only reorder files inside the same tier:
  #
  #     within = sim * (1 + 0.2 * norm_frec) + git_boost
  #     norm_frec = log(1 + freq) / log(1 + max_freq)

  defp prepare_candidate(%{path: path}, query, frecency_tab, git_tab, now, mode) do
    hits = Enum.map(query.terms, &term_hit(path, &1))
    counted = if mode == :or, do: Enum.filter(hits, & &1.matched?), else: hits
    {tier, sim} = classify_hits(counted, query, mode)

    %{
      path: path,
      tier: tier,
      sim: sim,
      freq: effective_frecency(path, frecency_tab, now),
      git_status: fetch_git_status(path, git_tab),
      matched_terms: length(counted),
      term_count: length(query.terms)
    }
  end

  defp term_hit(path, term) do
    {tier, sim} = term_match(path, term)
    # A keyword counts only when the path actually contains it. Jaro can clear
    # the similarity floor without sharing the term, which would hide the
    # partial-match header behind a fake 3/3.
    %{tier: tier, sim: sim, matched?: tier in [:exact, :filename, :path]}
  end

  defp classify_hits([], query, _mode), do: empty_term_class(query)

  # AND keeps the worst term, so one fuzzy token cannot borrow an exact hit.
  defp classify_hits(hits, _query, :and) do
    tier = hits |> Enum.map(& &1.tier) |> Enum.min_by(&tier_rank/1)
    sim = hits |> Enum.map(& &1.sim) |> average()
    {tier, sim}
  end

  # OR ranks and labels by the best matched term.
  defp classify_hits(hits, _query, :or) do
    tier = hits |> Enum.map(& &1.tier) |> Enum.max_by(&tier_rank/1)
    sim = hits |> Enum.map(& &1.sim) |> average()
    {tier, sim}
  end

  defp empty_term_class(%{globs: []}), do: {nil, 1.0}

  defp empty_term_class(%{globs: globs}) do
    path? =
      Enum.any?(globs, fn glob ->
        Map.get(glob, :path_fallback?) == true or Map.get(glob, :basename?) == false
      end)

    if path?, do: {:path, 1.0}, else: {:filename, 1.0}
  end

  defp reject_candidate?(_candidate, %{terms: []}, _mode), do: false
  defp reject_candidate?(%{matched_terms: 0}, _query, :or), do: true
  defp reject_candidate?(%{sim: sim}, _query, _mode), do: sim < @similarity_floor

  defp finalize_score(candidate, max_freq, mode) do
    norm = if max_freq > 0, do: :math.log(1 + candidate.freq) / :math.log(1 + max_freq), else: 0.0
    within = candidate.sim * (1 + @frecency_weight * norm) + git_boost(candidate.git_status)
    partial = if mode == :or, do: candidate.matched_terms * @partial_gap, else: 0.0
    score = partial + tier_rank(candidate.tier) * @tier_gap + within

    result = %{
      path: candidate.path,
      score: score,
      match_score: within,
      git_status: candidate.git_status
    }

    result = if candidate.tier, do: Map.put(result, :tier, candidate.tier), else: result

    if mode == :or do
      Map.merge(result, %{
        matched_terms: candidate.matched_terms,
        term_count: candidate.term_count,
        partial?: true
      })
    else
      result
    end
  end

  defp basename_globs?(%{globs: globs}) do
    Enum.any?(globs, fn glob ->
      Map.get(glob, :basename?) == true and is_binary(Map.get(glob, :pattern))
    end)
  end

  defp widen_basename_globs(%{globs: globs} = query) do
    %{query | globs: Enum.map(globs, &widen_glob/1)}
  end

  defp widen_glob(%{basename?: true, pattern: pattern} = glob) when is_binary(pattern) do
    source = "^" <> cross_slash_source(pattern) <> "$"

    Map.merge(glob, %{
      regex: Regex.compile!(source, [:caseless]),
      basename?: false,
      path_fallback?: true
    })
  end

  defp widen_glob(glob), do: glob

  defp cross_slash_source(pattern) do
    pattern
    |> String.graphemes()
    |> cross_slash_source([])
    |> IO.iodata_to_binary()
  end

  defp cross_slash_source([], acc), do: Enum.reverse(acc)
  defp cross_slash_source(["*", "*" | rest], acc), do: cross_slash_source(rest, [".*" | acc])
  defp cross_slash_source(["*" | rest], acc), do: cross_slash_source(rest, [".*" | acc])
  defp cross_slash_source(["?" | rest], acc), do: cross_slash_source(rest, ["[^/]" | acc])

  defp cross_slash_source([char | rest], acc),
    do: cross_slash_source(rest, [Regex.escape(char) | acc])

  defp term_match(path, term) do
    needle = safe_downcase(term)
    basename = path |> Path.basename() |> safe_downcase()
    normalized_path = safe_downcase(path)
    sim = similarity_to_term(normalized_path, needle)

    cond do
      needle != "" and basename == needle ->
        {:exact, max(sim, 1.0)}

      needle != "" and
          (String.starts_with?(basename, needle) or String.contains?(basename, needle)) ->
        {:filename, max(sim, 0.9)}

      needle != "" and String.contains?(normalized_path, needle) ->
        {:path, max(sim, 0.75)}

      true ->
        {:fuzzy, sim}
    end
  end

  defp tier_rank(:exact), do: 3
  defp tier_rank(:filename), do: 2
  defp tier_rank(:path), do: 1
  defp tier_rank(:fuzzy), do: 0
  defp tier_rank(nil), do: 0

  defp average([]), do: 0.0
  defp average(scores), do: Enum.sum(scores) / length(scores)

  defp fetch_git_status(_path, nil), do: nil

  defp fetch_git_status(path, git_tab) do
    case :ets.lookup(git_tab, path) do
      [{^path, status}] -> status
      [] -> nil
    end
  end

  defp git_boost(nil), do: 0.0
  defp git_boost(_status), do: @git_boost

  defp similarity_to_term(normalized_path, normalized_term) do
    # Jaro against a short path token inflates long queries (the match window
    # is half the longer string). Scale by length so only similar-length
    # tokens count as a real fuzzy hit; substring and tier floors cover
    # prefix/contains matches.
    substring_bonus =
      if normalized_term != "" and String.contains?(normalized_path, normalized_term),
        do: 0.9,
        else: 0.0

    basename_jaro =
      safe_jaro(normalized_term, Path.basename(normalized_path)) *
        length_ratio(normalized_term, Path.basename(normalized_path))

    token_jaro =
      normalized_path
      |> split_path_tokens()
      |> Enum.map(fn token ->
        safe_jaro(normalized_term, token) * length_ratio(normalized_term, token)
      end)
      |> Enum.max(fn -> 0.0 end)

    max(substring_bonus, max(basename_jaro, token_jaro))
  end

  defp length_ratio(a, b) do
    la = max(String.length(a), 1)
    lb = max(String.length(b), 1)
    min(la, lb) / max(la, lb)
  end

  defp safe_downcase(binary) when is_binary(binary) do
    if String.valid?(binary), do: String.downcase(binary), else: binary
  end

  defp safe_jaro(a, b) when is_binary(a) and is_binary(b) do
    if String.valid?(a) and String.valid?(b) do
      String.jaro_distance(a, b)
    else
      0.0
    end
  end

  defp split_path_tokens(path) do
    String.split(path, ~r{[/_\-\.]})
  end

  defp effective_frecency(path, scores, _now), do: Map.get(scores, path, 0.0)

  defp frecency_scores(table, now, opts) do
    # The table is keyed by {score, path}, so matching one path scans it.
    # Build one lookup map per query instead of doing that for every candidate.
    :ets.foldl(
      fn {{score, path}, meta}, scores ->
        check_deadline(opts)

        elapsed =
          case frecency_timestamp(meta) do
            nil -> 0
            touched_at -> max(now - touched_at, 0)
          end

        Map.put_new(scores, path, decay_frecency(score, elapsed))
      end,
      %{},
      table
    )
  end

  defp frecency_timestamp(ts) when is_integer(ts), do: ts
  defp frecency_timestamp(%{touched_at: ts}) when is_integer(ts), do: ts
  defp frecency_timestamp(_meta), do: nil

  # ── Filters ──

  defp apply_filters(candidates, query) do
    candidates
    |> apply_include_patterns(query.include_patterns)
    |> apply_exclude_patterns(query.exclude_patterns)
    |> apply_globs(Map.get(query, :globs, []))
  end

  defp apply_globs(candidates, []), do: candidates

  defp apply_globs(candidates, globs) do
    Stream.filter(candidates, fn %{path: path} ->
      Enum.all?(globs, &glob_match?(&1, path))
    end)
  end

  defp glob_match?(%{regex: regex, basename?: true}, path) do
    regex_match?(regex, Path.basename(path))
  end

  defp glob_match?(%{regex: regex}, path), do: regex_match?(regex, path)

  defp regex_match?(regex, value) do
    String.valid?(value) and Regex.match?(regex, value)
  end

  defp apply_include_patterns(candidates, []), do: candidates

  defp apply_include_patterns(candidates, patterns) do
    Stream.filter(candidates, fn %{path: path} ->
      Enum.any?(patterns, fn pattern ->
        String.ends_with?(String.downcase(path), String.downcase(pattern))
      end)
    end)
  end

  defp apply_exclude_patterns(candidates, []), do: candidates

  defp apply_exclude_patterns(candidates, patterns) do
    Stream.filter(candidates, fn %{path: path} ->
      not Enum.any?(patterns, fn pattern ->
        String.contains?(String.downcase(path), String.downcase(pattern))
      end)
    end)
  end

  # ── Tokenization Helpers ──

  @doc false
  def split_camel_case(""), do: []

  def split_camel_case(token) do
    token
    |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
    |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1 \\2")
    |> String.split()
    |> Enum.map(&String.downcase/1)
  end

  # Grapheme-based sliding window so that multi-byte characters
  # (CJK, accented Latin, emoji, …) are never sliced in the middle and
  # never produce invalid UTF-8 binaries.
  defp trigrams(token) when is_binary(token) do
    if String.valid?(token) do
      graphemes = String.graphemes(token)

      if length(graphemes) < 3 do
        []
      else
        graphemes
        |> Enum.chunk_every(3, 1, :discard)
        |> Enum.map(&Enum.join/1)
      end
    else
      []
    end
  end
end
