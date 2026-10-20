defmodule Handbean.Tool.Builtin.FileSearch do
  @moduledoc """
  Fast fuzzy file search in the workspace using ExFff (ETS-based index).

  Replaces the fallback `rg`-based file search with an in-memory trigram index
  for millisecond-latency results. Uses frecency tracking to boost recently
  accessed files.

  ## Query Syntax

  - `"schema"` — one or two filename fragments, not a sentence
  - `"*.ex"` — extension filter
  - `"sidebar*.heex"` — a `*` without `/` matches the file name only
  - `"desktop/**/*webview*"` — a glob containing `/` matches the relative path
  - `"!test/"` — exclude paths containing this substring
  - contents are not searched; use `grep`
  """

  @behaviour Handbean.Agent.Tool

  @cold_index_wait_ms 3_000

  @impl true
  def name, do: "file_search"

  @impl true
  def description do
    "Find files by 1–2 filename fragments, not a natural-language sentence. " <>
      "A `*` or `?` without `/` matches the file name only; include `/` or `**` to match the full relative path (for example desktop/**/*webview*). " <>
      "`*.ex` filters by extension. `!test/` excludes a path substring. " <>
      "Does not search file contents — use grep for that."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        query: %{
          type: "string",
          description:
            "1–2 filename fragments, an extension (`*.ex`), a path glob (`desktop/**/*webview*`), or an exclusion (`!test/`). Not a sentence, and not file contents."
        },
        path: %{
          type: "string",
          description:
            "Workspace-relative prefix; an external path requires per-call approval unless the run is yolo"
        },
        exclude: %{
          type: "array",
          items: %{type: "string"},
          description: "Path substrings to exclude"
        },
        cursor: %{type: "string", description: "Opaque next_cursor from a previous result"},
        limit: %{type: "integer", description: "Max results to return", default: 20}
      },
      required: ["query"]
    }
  end

  @impl true
  def max_result_chars, do: 10_000

  @impl true
  def execute(%{"query" => query} = input, context) do
    limit = Map.get(input, "limit", 20)
    working_directory = Map.get(context, :working_directory)

    with {:ok, workspace} <- resolve_root(working_directory),
         {:ok, root, path, absolute_paths?} <-
           resolve_search_scope(workspace, input["path"], context),
         {:ok, index} <- Handbean.Search.ensure_started(root),
         search_opts = [
           limit: limit,
           path: path,
           exclude: List.wrap(input["exclude"] || []),
           cursor: input["cursor"]
         ],
         {:ok, result} <- search_with_cold_index_wait(index, query, search_opts) do
      paths =
        Enum.filter(result.paths, fn %{path: path} ->
          Handbean.Security.PathValidator.allowed_result?(root, path)
        end)

      {:ok, format_results(%{result | paths: paths}, root, absolute_paths?)}
    end
  end

  def execute(_input, _context) do
    {:error, "query is required"}
  end

  # ── Helpers ──

  # An empty answer from a half-built index reads as "no such file" to the model,
  # so wait (bounded, server-side) for the first scan before reporting zero.
  defp search_with_cold_index_wait(index, query, opts) do
    case Handbean.Search.search(index, query, [await: false] ++ opts) do
      {:ok, %{paths: [], status: :indexing}} ->
        Handbean.Search.search(index, query, [await: @cold_index_wait_ms] ++ opts)

      other ->
        other
    end
  end

  defp resolve_root(working_directory) when is_binary(working_directory) do
    cond do
      working_directory == "" ->
        {:error, "working_directory is required"}

      File.dir?(working_directory) ->
        {:ok, working_directory}

      true ->
        {:error, "working_directory is not a directory: #{working_directory}"}
    end
  end

  defp resolve_root(_working_directory) do
    {:error, "working_directory is required"}
  end

  defp resolve_search_scope(root, nil, _context), do: {:ok, root, nil, false}
  defp resolve_search_scope(root, "", _context), do: {:ok, root, nil, false}

  defp resolve_search_scope(root, path, context) when is_binary(path) do
    with {:ok, expanded} <- Handbean.Agent.Tool.resolve_path(path, context, :search) do
      if Handbean.Security.PathValidator.validate_within_workspace(expanded, root) == :ok do
        {:ok, root, Path.relative_to(expanded, root), false}
      else
        external_search_scope(expanded)
      end
    end
  end

  defp resolve_search_scope(_root, _path, _context), do: {:error, "path must be a string"}

  defp external_search_scope(path) do
    cond do
      File.dir?(path) -> {:ok, path, nil, true}
      File.dir?(Path.dirname(path)) -> {:ok, Path.dirname(path), Path.basename(path), true}
      true -> {:error, "path not found: #{path}"}
    end
  end

  defp format_results(%{paths: [], query: query, duration_ms: ms} = result, _root, _absolute?) do
    "# No files found for: #{query} (#{ms}ms)#{indexing_suffix(result)}\n" <>
      empty_hint(query, result)
  end

  defp format_results(%{paths: paths, query: query, duration_ms: ms} = result, root, absolute?) do
    lines =
      paths
      |> Enum.map(fn entry ->
        if absolute?, do: %{entry | path: Path.join(root, entry.path)}, else: entry
      end)
      |> Enum.with_index(1)
      |> Enum.map(&format_line/1)

    continuation = if result[:cursor], do: "next_cursor: #{result.cursor}\n", else: ""

    header =
      continuation <>
        partial_header(result) <>
        "# Found #{length(paths)} file(s) for: #{query} (#{ms}ms)#{indexing_suffix(result)}\n"

    header <> Enum.join(lines, "\n")
  end

  defp format_line({%{path: path} = entry, i}) do
    git = if entry[:git_status], do: "\t[git:#{entry.git_status}]", else: ""
    score = Map.get(entry, :match_score, entry.score)
    "#{i}.\t#{path}\t(#{Float.round(score, 1)})#{tier_tag(entry)}#{git}"
  end

  defp tier_tag(%{tier: tier}) when tier in [:exact, :filename, :path, :fuzzy], do: " [#{tier}]"
  defp tier_tag(_entry), do: ""

  defp partial_header(%{partial_match: %{matched: matched, total: total}})
       when is_integer(matched) and is_integer(total) do
    "partial match: #{matched}/#{total} terms\n"
  end

  defp partial_header(_result), do: ""

  defp empty_hint(_query, %{status: :indexing}) do
    "The workspace index is still being built, so this empty result is not conclusive. Retry file_search shortly, or use grep."
  end

  defp empty_hint(query, result) do
    [indexed_hint(result), glob_hint(query), search_hint()]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp indexed_hint(%{indexed_count: count}) when is_integer(count), do: "Indexed #{count} files."
  defp indexed_hint(_result), do: ""

  defp glob_hint(query) when is_binary(query) do
    if basename_glob_query?(query) do
      "这是文件名 glob，不是路径 glob。A `*` without `/` matches the file name only, and that pattern was also tried against the full relative path."
    else
      ""
    end
  end

  defp glob_hint(_query), do: ""

  defp basename_glob_query?(query) do
    query
    |> ExFff.Query.parse()
    |> Map.get(:globs, [])
    |> Enum.any?(&(&1.basename? == true))
  end

  defp search_hint do
    "file_search matches file names and paths, not file contents — use grep for contents. Use 1–2 filename fragments, not a natural-language sentence."
  end

  defp indexing_suffix(%{status: :indexing, indexed_count: count}),
    do: " — indexing (#{count} files scanned so far)"

  defp indexing_suffix(%{status: :indexing}), do: " — indexing"
  defp indexing_suffix(_result), do: ""
end
