defmodule Handbean.Tool.Builtin.CodeSearch do
  @moduledoc """
  Locate code by symbol, path, or configured embeddings.

  Returns workspace-relative path and line numbers. File contents stay behind
  `read`. Without an embeddings config this is keyword search, not semantic
  search: a miss is not proof the code is absent. `index=partial` means the
  scan stopped at the budget.
  """

  @behaviour Handbean.Agent.Tool

  alias Handbean.CodeIndex
  alias Handbean.WorkspaceStore

  @default_limit 10
  @max_limit 20

  @impl true
  def name, do: "code_search"

  @impl true
  def description do
    "Find code locations in the workspace, or under an explicitly approved external path (automatic in yolo), by symbol, path, or meaning. " <>
      "Returns path and line numbers, not file contents; use read to inspect a hit. " <>
      "Without an embeddings config this is keyword/token search, not natural-language search. " <>
      "A keyword miss or index=partial does not mean the repository has no other matches. " <>
      "Use grep for exact text or regex."
  end

  @impl true
  def hint do
    "This failure is not an empty result. Use grep for an exact pattern, or read a known path. " <>
      "Do not repeat the same query unchanged."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        query: %{type: "string", description: "Symbol, path fragment, or question"},
        limit: %{
          type: "integer",
          description: "Maximum hits",
          default: @default_limit
        },
        path: %{
          type: "string",
          description:
            "Optional workspace-relative prefix; an external path requires per-call approval unless the run is yolo"
        },
        glob: %{type: "string", description: "Optional suffix filter such as .ex"}
      },
      required: ["query"]
    }
  end

  @impl true
  def max_result_chars, do: 8_000

  @impl true
  def concurrent?, do: true

  @impl true
  def execute(input, context) when is_map(input) do
    with {:ok, query} <- fetch_query(input),
         {:ok, workspace} <- workspace(context),
         {:ok, root, scoped_input, absolute_paths?} <- search_scope(workspace, input, context),
         {:ok, id} <- workspace_id(root, workspace, scoped_input, absolute_paths?, context) do
      parent = self()

      opts =
        scoped_input
        |> search_opts(context, parent)
        |> maybe_force_host_storage(absolute_paths?)

      case CodeIndex.search(root, id, query, opts) do
        {:ok, payload} ->
          payload =
            payload
            |> drop_sensitive_hits(root)
            |> filter_payload(scoped_input)

          {:ok, format(payload, scoped_input, root, absolute_paths?),
           details(payload, root, absolute_paths?)}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  def execute(_, _), do: {:error, "query is required"}

  defp search_opts(input, context, parent) do
    [
      limit: limit(input),
      path: blank_to_nil(Handbean.Utils.SafeMap.get_any(input, "path", :path)),
      glob: blank_to_nil(Handbean.Utils.SafeMap.get_any(input, "glob", :glob)),
      cancel: fn -> not Process.alive?(parent) end,
      models_file: context[:models_file]
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp maybe_force_host_storage(opts, true) do
    opts
    |> Keyword.put(:storage, :host_data)
    |> Keyword.put(:require_scope_sync, true)
  end

  defp maybe_force_host_storage(opts, false), do: opts

  defp fetch_query(input) do
    query = Handbean.Utils.SafeMap.get_any(input, "query", :query)

    if is_binary(query) and String.trim(query) != "" do
      {:ok, String.trim(query)}
    else
      {:error, "query is required"}
    end
  end

  defp workspace(context) do
    root =
      Handbean.Utils.SafeMap.get_any(context, :working_directory, "working_directory") ||
        File.cwd!()

    if File.dir?(root) do
      {:ok, Path.expand(root)}
    else
      {:error, "workspace not found"}
    end
  end

  defp search_scope(workspace, input, context) do
    case Handbean.Utils.SafeMap.get_any(input, "path", :path) do
      path when path in [nil, ""] ->
        {:ok, workspace, input, false}

      path when is_binary(path) ->
        with {:ok, resolved} <- Handbean.Agent.Tool.resolve_path(path, context, :search) do
          if Handbean.Security.PathValidator.validate_within_workspace(resolved, workspace) == :ok do
            {:ok, workspace, put_path(input, Path.relative_to(resolved, workspace)), false}
          else
            external_search_scope(resolved, input)
          end
        end

      _ ->
        {:error, "path must be a string"}
    end
  end

  defp external_search_scope(path, input) do
    cond do
      File.dir?(path) ->
        {:ok, path, put_path(input, nil), true}

      File.dir?(Path.dirname(path)) ->
        {:ok, Path.dirname(path), put_path(input, Path.basename(path)), true}

      true ->
        {:error, "path not found: #{path}"}
    end
  end

  defp put_path(input, nil), do: input |> Map.delete("path") |> Map.delete(:path)

  defp put_path(input, path) do
    input
    |> Map.delete(:path)
    |> Map.put("path", path)
  end

  defp workspace_id(root, workspace, input, external?, context) do
    base_result =
      case Handbean.Utils.SafeMap.get_any(context, :workspace_id, "workspace_id") do
        id when is_binary(id) and id != "" and root == workspace ->
          {:ok, id}

        _ ->
          case WorkspaceStore.get_by_path(root) do
            {:ok, %{"id" => id}} when is_binary(id) and id != "" -> {:ok, id}
            _ -> {:ok, "path-" <> hash_path(root)}
          end
      end

    with {:ok, id} <- base_result do
      {:ok, scoped_workspace_id(id, input, external?)}
    end
  end

  defp scoped_workspace_id(id, input, true) do
    case Handbean.Utils.SafeMap.get_any(input, "path", :path) do
      path when is_binary(path) and path != "" -> id <> "-scope-" <> hash_path(path)
      _ -> id
    end
  end

  defp scoped_workspace_id(id, _input, false), do: id

  defp hash_path(root) do
    :crypto.hash(:sha256, root) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp limit(input) do
    case Handbean.Utils.SafeMap.get_any(input, "limit", :limit) do
      n when is_integer(n) -> n |> max(1) |> min(@max_limit)
      _ -> @default_limit
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp format(
         %{hits: hits, mode: mode, index: index, elapsed_ms: elapsed},
         input,
         root,
         absolute?
       ) do
    filtered = filter_hits(hits, input)

    header =
      "# code_search  mode=#{mode}  index=#{index}  #{length(filtered)} hits  #{elapsed}ms"

    body =
      filtered
      |> Enum.with_index(1)
      |> Enum.map_join("\n", &format_hit(&1, root, absolute?))

    note =
      case mode do
        :keyword ->
          "Keyword mode matches symbols and tokens, not natural-language questions."

        :hybrid ->
          "Hybrid mode mixes keyword and embeddings. Use read to inspect a hit."
      end

    partial =
      if index == :ready do
        ""
      else
        "Partial or stale index means the scan stopped at the budget, not that the repo has no other hits."
      end

    [
      header,
      body,
      "Use read with offset/limit to inspect a hit. Do not treat this as file contents.",
      note,
      partial
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp format_hit({hit, n}, root, absolute?) do
    symbol = if is_binary(hit.symbol) and hit.symbol != "", do: "  #{hit.symbol}", else: ""
    score = hit |> Map.get(:score, 0.0) |> Float.round(2)
    path = if absolute?, do: Path.join(root, hit.path), else: hit.path
    "#{n}. #{path}:#{hit.start_line}-#{hit.end_line}#{symbol}  (#{score})"
  end

  defp filter_payload(%{hits: hits} = payload, input),
    do: %{payload | hits: filter_hits(hits, input)}

  defp filter_hits(hits, input) do
    path = Handbean.Utils.SafeMap.get_any(input, "path", :path)
    glob = Handbean.Utils.SafeMap.get_any(input, "glob", :glob)

    Enum.filter(hits, fn hit ->
      path_ok?(hit.path, path) and glob_ok?(hit.path, glob)
    end)
  end

  defp path_ok?(_hit, prefix) when prefix in [nil, ""], do: true

  defp path_ok?(hit, prefix) do
    normalized = prefix |> String.trim_leading("./") |> String.trim_trailing("/")
    hit == normalized or String.starts_with?(hit, normalized <> "/")
  end

  defp glob_ok?(_hit, glob) when glob in [nil, ""], do: true

  defp glob_ok?(hit, glob) do
    suffix = String.trim_leading(glob, "*")
    String.ends_with?(hit, suffix)
  end

  defp details(%{hits: hits}, root, absolute?) do
    case hits do
      [hit | _] ->
        %{
          file_path: if(absolute?, do: Path.join(root, hit.path), else: hit.path),
          start_line: hit.start_line,
          end_line: hit.end_line
        }

      _ ->
        %{}
    end
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: "code_search failed: #{inspect(reason)}"

  defp drop_sensitive_hits(%{hits: hits} = payload, root) do
    %{
      payload
      | hits:
          Enum.filter(hits, fn hit ->
            Handbean.Security.PathValidator.allowed_result?(root, hit.path)
          end)
    }
  end
end
