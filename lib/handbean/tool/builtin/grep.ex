defmodule Handbean.Tool.Builtin.Grep do
  @moduledoc """
  Search workspace file contents over the shared ExFff inventory.

  Results are grouped by file and paged with an opaque cursor. Ripgrep is used
  when available and its output is intersected with the shared inventory.
  Other hosts read that inventory directly with an Elixir matcher.
  """

  @behaviour Handbean.Agent.Tool

  @default_limit 50
  # One noisy file must not fill the page. The rest of a capped file is
  # summarised and skipped by the cursor; scoping path to that file lifts the cap.
  @max_hits_per_file 10
  @inventory_page 10_000
  @max_result_chars 20_000
  @max_file_bytes 5_000_000
  @max_line_number @max_file_bytes + 1
  @max_line_number_digits byte_size(Integer.to_string(@max_line_number))
  @max_page_bytes 48_000
  @max_line_bytes 2_000
  @max_context 3
  @scan_budget_ms 2_000
  @external_index_wait_ms 3_000
  @search_budget_ms 6_000

  @impl true
  def name, do: "grep"

  @impl true
  def description do
    "Search file contents for a regex or literal pattern. " <>
      "Omit pattern and pass glob to list matching files. " <>
      "Use file_search for fuzzy name search. " <>
      "path should be workspace-relative; an external path requires per-call approval unless the run is yolo. " <>
      "Results are grouped by file with at most #{@max_hits_per_file} matching lines per file; " <>
      "pass that file as path to see all of its matches. Pass next_cursor as cursor to continue."
  end

  @impl true
  def hint do
    "A failed search is not an empty result. Add a content pattern, or pass glob to list files. " <>
      "If path is outside the workspace, request per-call approval unless the run is yolo. " <>
      "Do not invent another user's absolute path, and do not repeat the same arguments unchanged."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        pattern: %{
          type: "string",
          description:
            "Content pattern (regex by default); omit only when glob is used to list files"
        },
        path: %{
          type: "string",
          description:
            "Workspace-relative file or directory. External paths require per-call approval unless the run is yolo"
        },
        glob: %{
          type: "string",
          description: "Optional file filter such as *.{ex,exs}; not a search pattern"
        },
        exclude: %{
          type: "array",
          items: %{type: "string"},
          description: "Path substrings to exclude"
        },
        cursor: %{
          type: "string",
          description: "Opaque next_cursor returned by the same query; omit for a new query"
        },
        ignore_case: %{type: "boolean", default: false},
        literal: %{type: "boolean", default: false},
        context: %{type: "integer", default: 0},
        before_context: %{type: "integer", default: 0},
        after_context: %{type: "integer", default: 0},
        limit: %{type: "integer", description: "Maximum matching lines", default: @default_limit}
      },
      required: []
    }
  end

  @impl true
  def max_result_chars, do: @max_result_chars

  @impl true
  def concurrent?, do: true

  @impl true
  def execute(input, context) when is_map(input) do
    # Include inventory, regex evaluation and rendering in the budget. The
    # linked task and its rg port also terminate when the tool is cancelled.
    deadline = System.monotonic_time(:millisecond) + @search_budget_ms
    task = Task.async(fn -> execute_search(input, context, deadline) end)

    case Task.yield(task, @search_budget_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> search_timeout()
    end
  end

  def execute(_input, _context), do: {:error, "pattern is required"}

  defp execute_search(input, context, deadline) do
    with {:ok, workspace, prefix, note, absolute_paths?} <- resolve_scope(input, context) do
      case fetch_pattern(input) do
        {:ok, pattern} ->
          input
          |> search_pattern(pattern, workspace, prefix, absolute_paths?, deadline)
          |> with_note(note)

        :missing ->
          if glob_present?(input) do
            list_by_glob(input, workspace, prefix, note, absolute_paths?, deadline)
          else
            {:error, missing_pattern_error(workspace)}
          end
      end
    end
  rescue
    error ->
      Handbean.Agent.Tool.Result.error(
        "grep failed due to an internal error; retry with a narrower path",
        %{code: :tool_exception, side_effect: :not_started},
        Handbean.Agent.ErrorReporter.capture_exception(error, __STACKTRACE__, :grep)
      )
  catch
    {:invalid_cursor, reason} ->
      {:error, reason, %{code: :cursor_invalid, side_effect: :not_started, status: :failed}}
  end

  defp search_timeout do
    {:error, "grep search timed out before completion; narrow path or glob and retry",
     %{code: :scan_timeout, status: :failed, side_effect: :not_started}}
  end

  defp inventory(index, workspace, prefix, input, deadline) do
    excludes = Handbean.Utils.SafeMap.get_any(input, "exclude", :exclude) || []
    matcher = glob_matcher(Handbean.Utils.SafeMap.get_any(input, "glob", :glob))

    collect_inventory(
      index,
      workspace,
      prefix,
      List.wrap(excludes),
      nil,
      [],
      nil,
      matcher,
      deadline
    )
  end

  defp collect_inventory(
         index,
         workspace,
         prefix,
         excludes,
         cursor,
         acc,
         status,
         matcher,
         deadline
       ) do
    timeout = max(min(deadline - System.monotonic_time(:millisecond), 5_000), 1)

    opts = [
      path: prefix,
      exclude: excludes,
      cursor: cursor,
      limit: @inventory_page,
      deadline: deadline,
      timeout: timeout
    ]

    with {:ok, page} <- Handbean.Search.files(index, opts) do
      next_acc = [Enum.filter(page.paths, matcher) | acc]

      if page.cursor do
        collect_inventory(
          index,
          workspace,
          prefix,
          excludes,
          page.cursor,
          next_acc,
          page.status,
          matcher,
          deadline
        )
      else
        {:ok,
         %{
           paths: next_acc |> Enum.reverse() |> List.flatten(),
           prefix: prefix,
           status: status || page.status,
           indexed_count: page.indexed_count
         }}
      end
    end
  end

  defp search(pattern, regex, inventory, workspace, input, absolute_paths?) do
    started_at = System.monotonic_time(:millisecond)

    cursor =
      decode_cursor(
        Handbean.Utils.SafeMap.get_any(input, "cursor", :cursor),
        input,
        workspace
      )

    wanted = limit(input) + 1

    if cursor == :invalid do
      throw(
        {:invalid_cursor,
         "Invalid cursor for this query or workspace. Omit cursor for a new query; to continue, use next_cursor returned by the same query."}
      )
    end

    files = Enum.sort(inventory.paths)
    collector = new_collector(wanted, per_file_cap(workspace, inventory.prefix))

    {matcher, collector, partial?} =
      case System.find_executable("rg") do
        nil ->
          {collector, partial?} = elixir_hits(files, workspace, regex, cursor, collector)
          {:elixir, collector, partial?}

        rg ->
          case rg_hits(
                 rg,
                 files,
                 workspace,
                 inventory.prefix,
                 pattern,
                 input,
                 cursor,
                 collector
               ) do
            {:ok, collector, partial?} ->
              {:ripgrep, collector, partial?}

            {:error, _code} ->
              {collector, partial?} = elixir_hits(files, workspace, regex, cursor, collector)
              {:elixir, collector, partial?}
          end
      end

    safe_hits = take_safe_hits(Enum.reverse(collector.hits), workspace, wanted)
    page = safe_hits |> Enum.take(limit(input)) |> fit_page_bytes()
    capped = capped_files(page, collector)

    next_cursor =
      if page != [] and (length(safe_hits) > length(page) or partial?) do
        last = Enum.max_by(page, &{&1.path, &1.line})
        # A capped file was summarised; continue after it rather than inside it.
        last =
          if Map.has_key?(capped, last.path), do: %{last | line: @max_line_number + 1}, else: last

        encode_cursor(last, input, workspace)
      end

    emit_telemetry(started_at, length(files), length(page), matcher, inventory.status)

    if partial? and page == [] do
      {:error, "grep scan timed out before completion; narrow path or glob and retry",
       %{code: :scan_timeout, status: :failed, side_effect: :not_started}}
    else
      {:ok,
       format_results(
         page,
         next_cursor,
         Map.put(inventory, :partial, partial?),
         workspace,
         input,
         absolute_paths?,
         capped
       )}
    end
  end

  defp per_file_cap(workspace, prefix) do
    if File.regular?(Path.join(workspace, prefix || ".")), do: nil, else: @max_hits_per_file
  end

  defp new_collector(wanted, cap),
    do: %{hits: [], kept: 0, shown: %{}, more: %{}, wanted: wanted, cap: cap}

  defp collector_full?(collector), do: collector.kept >= collector.wanted

  # rg output and the fallback scan are both path-sorted, so hits beyond a
  # file's cap are counted completely before the next file is reached.
  defp collect_hit(%{cap: cap} = collector, hit) do
    case Map.get(collector.shown, hit.path, 0) do
      shown when is_integer(cap) and shown >= cap ->
        %{collector | more: Map.update(collector.more, hit.path, 1, &(&1 + 1))}

      shown ->
        %{
          collector
          | hits: [hit | collector.hits],
            kept: collector.kept + 1,
            shown: Map.put(collector.shown, hit.path, shown + 1)
        }
    end
  end

  # Only files whose full capped share is on the page are summarised. A file cut
  # short by the page limit continues through next_cursor instead.
  defp capped_files(page, %{cap: cap, more: more}) do
    page
    |> Enum.frequencies_by(& &1.path)
    |> Enum.flat_map(fn {path, count} ->
      if count == cap and Map.has_key?(more, path), do: [{path, more[path]}], else: []
    end)
    |> Map.new()
  end

  defp elixir_hits(files, workspace, regex, cursor, collector) do
    validation = new_validation(workspace)
    deadline = System.monotonic_time(:millisecond) + @scan_budget_ms

    {collector, _validation, partial?} =
      Enum.reduce_while(files, {collector, validation, false}, fn relative,
                                                                  {collector, validation,
                                                                   _partial?} ->
        if System.monotonic_time(:millisecond) > deadline do
          {:halt, {collector, validation, true}}
        else
          {hits, validation} = file_hits(relative, workspace, regex, cursor, validation)

          collector =
            Enum.reduce_while(hits, collector, fn hit, collector ->
              if collector_full?(collector),
                do: {:halt, collector},
                else: {:cont, collect_hit(collector, hit)}
            end)

          if collector_full?(collector),
            do: {:halt, {collector, validation, false}},
            else: {:cont, {collector, validation, false}}
        end
      end)

    {collector, partial?}
  end

  defp file_hits(relative, workspace, regex, cursor, validation) do
    with {:ok, content, validation} <- read_search_file(workspace, relative, validation),
         true <- String.valid?(content) do
      hits =
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, number} ->
          hit = bound_hit(%{path: relative, line: number, text: line})

          if byte_size(line) <= @max_line_bytes and Regex.match?(regex, line) and
               after_cursor?(hit, cursor),
             do: [hit],
             else: []
        end)

      {hits, validation}
    else
      {:error, validation} -> {[], validation}
      false -> {[], validation}
    end
  end

  defp rg_hits(rg, files, workspace, prefix, pattern, input, cursor, collector) do
    inventory = MapSet.new(files)
    target = if prefix in [nil, "", "."], do: ".", else: prefix
    args = rg_args(input) ++ rg_globs(input) ++ rg_sensitive_globs() ++ ["--", pattern, target]

    stream_rg(rg, args, workspace, inventory, cursor, collector)
  end

  defp stream_rg(rg, args, workspace, inventory, cursor, collector) do
    port =
      Port.open(
        {:spawn_executable, rg},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:cd, workspace},
          {:args, args},
          {:line, @max_line_bytes}
        ]
      )

    collect_rg(
      port,
      inventory,
      cursor,
      collector,
      System.monotonic_time(:millisecond) + @scan_budget_ms,
      false
    )
  end

  defp collect_rg(port, inventory, cursor, collector, deadline, partial?) do
    overtime? = System.monotonic_time(:millisecond) > deadline

    cond do
      collector_full?(collector) or overtime? ->
        close_rg(port)
        {:ok, collector, true}

      true ->
        receive do
          {^port, {:data, {:eol, line}}} ->
            collector = maybe_add_rg_hit(collector, line_text(line), inventory, cursor)
            collect_rg(port, inventory, cursor, collector, deadline, partial?)

          {^port, {:data, {:noeol, _line}}} ->
            collect_rg(port, inventory, cursor, collector, deadline, true)

          {^port, {:data, data}} when is_binary(data) ->
            collector = maybe_add_rg_hit(collector, line_text(data), inventory, cursor)
            collect_rg(port, inventory, cursor, collector, deadline, true)

          {^port, {:exit_status, code}} when code in [0, 1] ->
            {:ok, collector, partial?}

          {^port, {:exit_status, code}} ->
            {:error, code}
        after
          200 ->
            if System.monotonic_time(:millisecond) > deadline do
              close_rg(port)
              {:ok, collector, true}
            else
              collect_rg(port, inventory, cursor, collector, deadline, partial?)
            end
        end
    end
  end

  defp maybe_add_rg_hit(collector, line, inventory, cursor) do
    case parse_rg_line(line) do
      nil ->
        collector

      hit ->
        hit = hit |> normalize_rg_hit() |> bound_hit()

        if MapSet.member?(inventory, hit.path) and after_cursor?(hit, cursor),
          do: collect_hit(collector, hit),
          else: collector
    end
  end

  defp line_text(line) when is_binary(line) do
    binary_part(line, 0, min(byte_size(line), @max_line_bytes))
  end

  defp line_text(_line), do: ""

  defp close_rg(port) do
    if Port.info(port), do: Port.close(port)
  catch
    _, _ -> :ok
  end

  defp rg_args(input) do
    # ripgrep omits the filename when only one path is searched unless this is
    # explicit. The parser and cursor contract always require path:line:text.
    base = [
      "--line-number",
      "--color=never",
      "--no-heading",
      "--with-filename",
      "--sort",
      "path",
      "--hidden",
      "--max-filesize",
      Integer.to_string(@max_file_bytes)
    ]

    base =
      if truthy?(Handbean.Utils.SafeMap.get_any(input, "ignore_case", :ignore_case)),
        do: base ++ ["-i"],
        else: base

    if truthy?(Handbean.Utils.SafeMap.get_any(input, "literal", :literal)),
      do: base ++ ["-F"],
      else: base
  end

  defp rg_globs(input) do
    case Handbean.Utils.SafeMap.get_any(input, "glob", :glob) do
      glob when is_binary(glob) ->
        # Our legacy '*' may cross slashes. Only push down suffix filters whose
        # rg meaning is a superset; other patterns remain inventory filters.
        patterns = expand_braces(glob)

        if Enum.all?(patterns, &Regex.match?(~r/^\*\.[a-zA-Z0-9_]+$/, &1)),
          do: Enum.flat_map(patterns, &["--glob", &1]),
          else: []

      _ ->
        []
    end
  end

  defp rg_sensitive_globs do
    globs =
      Handbean.Security.PathValidator.rg_exclude_globs() ++ ExFff.Config.rg_exclude_globs()

    Enum.flat_map(globs, &["--glob", &1])
  end

  defp parse_rg_line(line) when is_binary(line) do
    case rg_fields(line, :binary.matches(line, ":")) do
      {:ok, path, number, text} ->
        with true <- String.valid?(path),
             {:ok, line_number} <- rg_line_number(number) do
          %{path: path, line: line_number, text: safe_text(text)}
        else
          _ -> nil
        end

      :error ->
        nil
    end
  end

  defp rg_fields(line, [{path_end, 1}, {number_end, 1} | rest]) do
    number_start = path_end + 1
    number = binary_part(line, number_start, number_end - number_start)

    if path_end > 0 and decimal?(number) do
      text_start = number_end + 1
      text = binary_part(line, text_start, byte_size(line) - text_start)
      {:ok, binary_part(line, 0, path_end), number, text}
    else
      rg_fields(line, [{number_end, 1} | rest])
    end
  end

  defp rg_fields(_line, _colons), do: :error

  defp decimal?(<<digit, rest::binary>>) when digit in ?0..?9, do: decimal_tail?(rest)
  defp decimal?(_value), do: false

  defp decimal_tail?(<<digit, rest::binary>>) when digit in ?0..?9, do: decimal_tail?(rest)
  defp decimal_tail?(<<>>), do: true
  defp decimal_tail?(_value), do: false

  defp rg_line_number(number) when byte_size(number) <= @max_line_number_digits do
    case String.to_integer(number) do
      line_number when line_number in 1..@max_line_number -> {:ok, line_number}
      _line_number -> :error
    end
  end

  defp rg_line_number(_number), do: :error

  defp normalize_rg_hit(hit) do
    %{hit | path: hit.path |> String.replace("\\", "/") |> String.trim_leading("./")}
  end

  defp format_results([], _cursor, inventory, _workspace, _input, _absolute_paths?, _capped) do
    "No matches found" <> indexing_suffix(inventory)
  end

  defp format_results(hits, next_cursor, inventory, workspace, input, absolute_paths?, capped) do
    before_n = context_before(input)
    after_n = context_after(input)

    body =
      hits
      |> Enum.group_by(& &1.path)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("\n", fn {path, file_hits} ->
        lines = read_lines(workspace, path)
        shown_path = if absolute_paths?, do: Path.join(workspace, path), else: path

        rendered =
          file_hits
          |> Enum.sort_by(& &1.line)
          |> Enum.flat_map(&format_hit(shown_path, lines, &1.line, before_n, after_n))
          |> Enum.uniq()
          |> Enum.join("\n")

        "== #{shown_path} ==\n" <> rendered <> capped_note(capped, path, shown_path)
      end)

    continuation = if next_cursor, do: "next_cursor: #{next_cursor}\n", else: ""
    continuation <> body <> indexing_suffix(inventory)
  end

  defp capped_note(capped, path, shown_path) do
    case capped do
      %{^path => more} -> "\n[+#{more} more in this file; pass path: #{shown_path} to see all]"
      _ -> ""
    end
  end

  defp read_lines(workspace, relative) do
    case read_search_file(workspace, relative) do
      {:ok, content} when is_binary(content) ->
        content
        |> String.replace_invalid("�")
        |> String.split("\n")

      _ ->
        []
    end
  end

  defp take_safe_hits(hits, workspace, wanted) do
    {safe, _checked} =
      Enum.reduce_while(hits, {[], %{}}, fn hit, {acc, checked} ->
        path = hit.path

        {allowed?, checked} =
          case checked do
            %{^path => allowed?} ->
              {allowed?, checked}

            _ ->
              allowed? = safe_search_file?(workspace, path)
              {allowed?, Map.put(checked, path, allowed?)}
          end

        next = if allowed?, do: [hit | acc], else: acc

        if length(next) >= wanted,
          do: {:halt, {next, checked}},
          else: {:cont, {next, checked}}
      end)

    Enum.reverse(safe)
  end

  defp read_search_file(workspace, relative) do
    path = Path.join(workspace, relative)

    with true <- safe_search_file?(workspace, relative),
         {:ok, %{size: size}} when size <= @max_file_bytes <- File.lstat(path),
         {:ok, content} <- File.read(path) do
      {:ok, content}
    else
      _ -> {:error, :unsafe_or_unreadable}
    end
  end

  defp read_search_file(workspace, relative, validation) do
    path = Path.join(workspace, relative)
    {directory_allowed?, validation} = validate_directory(Path.dirname(path), validation)

    with true <- directory_allowed?,
         :ok <- Handbean.Security.PathValidator.reject_sensitive(relative),
         {:ok, %{type: :regular, size: size}} when size <= @max_file_bytes <- File.lstat(path),
         {:ok, content} <- File.read(path) do
      {:ok, content, validation}
    else
      _ -> {:error, validation}
    end
  end

  defp new_validation(workspace) do
    root =
      case Handbean.Security.PathValidator.canonicalize(workspace) do
        {:ok, resolved} -> resolved
        {:error, _reason} -> Path.expand(workspace)
      end

    %{root: root, directories: %{}}
  end

  defp validate_directory(directory, validation) do
    case validation.directories do
      %{^directory => allowed?} ->
        {allowed?, validation}

      _ ->
        allowed? =
          case Handbean.Security.PathValidator.canonicalize(directory) do
            {:ok, resolved} ->
              contained?(resolved, validation.root) and
                Handbean.Security.PathValidator.reject_sensitive(resolved) == :ok

            {:error, _reason} ->
              false
          end

        {allowed?, put_in(validation.directories[directory], allowed?)}
    end
  end

  defp contained?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp safe_search_file?(workspace, relative) do
    path = Path.join(workspace, relative)

    Handbean.Security.PathValidator.reject_sensitive(relative) == :ok and
      Handbean.Security.PathValidator.validate_within_workspace(path, workspace) == :ok and
      Handbean.Security.PathValidator.reject_resolved(path) == :ok and
      regular_file?(path)
  end

  defp format_hit(path, lines, index, before_n, after_n) do
    line_count = length(lines)

    if index <= line_count do
      start_i = max(1, index - before_n)
      end_i = min(line_count, index + after_n)

      for i <- start_i..end_i do
        separator = if i == index, do: ":", else: "-"
        text = lines |> Enum.at(i - 1) |> then(&safe_text(&1 || ""))
        "#{path}#{separator}#{i}#{separator}#{text}"
      end
    else
      []
    end
  end

  defp indexing_suffix(%{status: :indexing, indexed_count: count}) do
    "\n[indexing: #{count} files scanned so far]"
  end

  defp indexing_suffix(%{partial: true}) do
    "\n[partial: scan budget reached; continue with next_cursor or narrow path/glob]"
  end

  defp indexing_suffix(_inventory), do: ""

  defp after_cursor?(_hit, nil), do: true

  defp after_cursor?(hit, {path, line, _query, _workspace}),
    do: {hit.path, hit.line} > {path, line}

  defp after_cursor?(_hit, :invalid), do: false

  defp encode_cursor(%{path: path, line: line}, input, workspace) do
    payload = {1, path, line, query_key(input), workspace_key(workspace)}
    Base.url_encode64(:erlang.term_to_binary(payload), padding: false)
  end

  defp decode_cursor(cursor, _input, _workspace) when cursor in [nil, ""], do: nil

  defp decode_cursor(cursor, input, workspace) when is_binary(cursor) do
    with {:ok, binary} <- Base.url_decode64(cursor, padding: false),
         {:ok, {1, path, line, query, workspace_key}} <- cursor_term(binary),
         true <- is_binary(path) and is_integer(line) and query == query_key(input),
         true <- workspace_key == workspace_key(workspace) do
      {path, line, query, workspace_key}
    else
      _ -> :invalid
    end
  end

  defp decode_cursor(_cursor, _input, _workspace), do: :invalid

  defp cursor_term(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> :error
  end

  defp query_key(input) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({
        Handbean.Utils.SafeMap.get_any(input, ["pattern", :pattern]),
        Handbean.Utils.SafeMap.get_any(input, "path", :path),
        Handbean.Utils.SafeMap.get_any(input, "glob", :glob),
        Handbean.Utils.SafeMap.get_any(input, "literal", :literal),
        Handbean.Utils.SafeMap.get_any(input, "ignore_case", :ignore_case)
      })
    )
    |> Base.encode16(case: :lower)
  end

  defp workspace_key(workspace), do: Path.expand(workspace || "")

  defp bound_hit(hit), do: %{hit | text: safe_text(hit.text || "")}

  defp safe_text(text) do
    text
    |> String.replace_invalid("�")
    |> take_utf8_bytes(@max_line_bytes)
  end

  defp take_utf8_bytes(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp take_utf8_bytes(text, max_bytes) do
    prefix = binary_part(text, 0, max_bytes)

    case :unicode.characters_to_binary(prefix, :utf8, :utf8) do
      valid when is_binary(valid) -> valid
      {:incomplete, valid, _rest} -> IO.iodata_to_binary(valid)
      {:error, valid, _rest} -> IO.iodata_to_binary(valid)
    end
  end

  defp fit_page_bytes(hits) do
    {kept, _bytes} =
      Enum.reduce_while(hits, {[], 0}, fn hit, {acc, bytes} ->
        next = bytes + byte_size(hit.text || "") + byte_size(hit.path || "") + 16

        if acc != [] and next > @max_page_bytes do
          {:halt, {acc, bytes}}
        else
          {:cont, {[hit | acc], next}}
        end
      end)

    Enum.reverse(kept)
  end

  defp compile_pattern(pattern, input) do
    source =
      if truthy?(Handbean.Utils.SafeMap.get_any(input, ["literal", :literal])),
        do: Regex.escape(pattern),
        else: pattern

    options =
      if truthy?(Handbean.Utils.SafeMap.get_any(input, ["ignore_case", :ignore_case])),
        do: "i",
        else: ""

    case Regex.compile(source, options) do
      {:ok, regex} -> {:ok, regex}
      {:error, {reason, _}} -> {:error, "invalid pattern: #{reason}"}
    end
  end

  defp search_pattern(input, pattern, workspace, prefix, absolute_paths?, deadline) do
    with {:ok, regex} <- compile_pattern(pattern, input),
         {:ok, index} <- Handbean.Search.ensure_started(workspace),
         :ok <- await_external_index(index, absolute_paths?),
         {:ok, inventory} <- inventory(index, workspace, prefix, input, deadline) do
      search(pattern, regex, inventory, workspace, input, absolute_paths?)
    end
  end

  defp list_by_glob(input, workspace, prefix, note, absolute_paths?, deadline) do
    with {:ok, index} <- Handbean.Search.ensure_started(workspace),
         :ok <- await_external_index(index, absolute_paths?),
         {:ok, inventory} <- inventory(index, workspace, prefix, input, deadline) do
      files =
        inventory.paths
        |> Enum.filter(&safe_search_file?(workspace, &1))
        |> Enum.sort()
        |> Enum.take(limit(input))

      body =
        case files do
          [] ->
            "No matches found"

          paths ->
            paths
            |> Enum.map(fn path ->
              if absolute_paths?, do: Path.join(workspace, path), else: path
            end)
            |> Enum.join("\n")
        end

      {:ok, body <> indexing_suffix(inventory)}
      |> with_note(note)
    end
  end

  defp await_external_index(index, true) do
    Handbean.Search.await(index, @external_index_wait_ms)
  catch
    :exit, {:timeout, _} -> search_timeout()
  end

  defp await_external_index(_index, false), do: :ok

  defp fetch_pattern(input) do
    pattern = Handbean.Utils.SafeMap.get_any(input, ["pattern", :pattern, "query", :query])

    if is_binary(pattern) and String.trim(pattern) != "",
      do: {:ok, pattern},
      else: :missing
  end

  defp glob_present?(input) do
    case Handbean.Utils.SafeMap.get_any(input, ["glob", :glob]) do
      glob when is_binary(glob) -> String.trim(glob) != ""
      _ -> false
    end
  end

  defp missing_pattern_error(workspace) do
    "pattern is required to search contents. Pass glob to list files, or use file_search. " <>
      "Omit path or use a workspace-relative path under #{workspace}. " <>
      "Do not invent another user's absolute path."
  end

  defp resolve_scope(input, context) do
    workspace =
      Handbean.Utils.SafeMap.get_any(context, [:working_directory, "working_directory"]) ||
        File.cwd!()

    workspace = Path.expand(workspace)

    raw_path =
      Handbean.Utils.SafeMap.get_any(input, "path", :path) ||
        Handbean.Utils.SafeMap.get_any(input, "file_path", :file_path) || "."

    raw_path = Handbean.Agent.Tool.Helpers.expand_tilde(raw_path)

    requested =
      if Path.type(raw_path) == :absolute, do: raw_path, else: Path.expand(raw_path, workspace)

    {path, note} = maybe_reroot(requested, workspace, context)

    with {:ok, resolved} <- Handbean.Agent.Tool.resolve_path(path, context, :search),
         true <- File.exists?(resolved) do
      if Handbean.Security.PathValidator.validate_within_workspace(resolved, workspace) == :ok do
        {:ok, workspace, Path.relative_to(resolved, workspace), note, false}
      else
        external_scope(resolved)
      end
    else
      false ->
        {:error, path_not_found(path, note)}

      {:error, "Path traversal blocked: " <> _} ->
        {:error, outside_workspace_error(requested, workspace)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_reroot(requested, workspace, context) do
    if Handbean.Agent.Tool.outside_workspace_allowed?(context, requested, :search) do
      {requested, nil}
    else
      case reroot_foreign_workspace(requested, workspace) do
        {:ok, rerooted} ->
          relative = Path.relative_to(rerooted, workspace)

          {rerooted,
           "path rewritten into workspace #{workspace} as #{relative}; do not invent another user's absolute path"}

        :error ->
          {requested, nil}
      end
    end
  end

  defp external_scope(path) do
    if File.dir?(path) do
      {:ok, path, ".", nil, true}
    else
      {:ok, Path.dirname(path), Path.basename(path), nil, true}
    end
  end

  # Cursor native Grep often sends an absolute path. A path that merely repeats this
  # workspace's directory name is the same project with a hallucinated home, not a
  # request to read another user's tree.
  defp reroot_foreign_workspace(path, workspace) do
    cond do
      Handbean.Security.PathValidator.validate_within_workspace(path, workspace) == :ok ->
        :error

      true ->
        base = workspace |> Path.basename() |> String.downcase()
        parts = path |> Path.split() |> Enum.reject(&(&1 in ["/", "\\"]))

        case Enum.with_index(parts)
             |> Enum.filter(fn {part, _index} -> String.downcase(part) == base end) do
          [] ->
            :error

          matches ->
            {_part, index} = List.last(matches)

            relative =
              case Enum.drop(parts, index + 1) do
                [] -> "."
                rest -> Path.join(rest)
              end

            rerooted = Path.expand(relative, workspace)

            case Handbean.Security.PathValidator.validate_within_workspace(rerooted, workspace) do
              :ok -> {:ok, rerooted}
              {:error, _} -> :error
            end
        end
    end
  end

  defp path_not_found(path, nil), do: "Path not found: #{path}"

  defp path_not_found(path, note), do: "Path not found: #{path}. #{note}"

  defp outside_workspace_error(path, workspace) do
    "Path traversal blocked: #{path} is outside workspace. " <>
      "Current workspace is #{workspace}. Omit path or pass a workspace-relative path. " <>
      "Do not invent another user's home directory."
  end

  defp with_note({:ok, output}, note) when is_binary(output) and is_binary(note) do
    {:ok, output <> "\n[" <> note <> "]"}
  end

  defp with_note(result, _note), do: result

  defp regular_file?(path), do: match?({:ok, %{type: :regular}}, File.lstat(path))

  defp glob_matcher(glob) when is_binary(glob) and glob != "" do
    regexes = glob |> expand_braces() |> Enum.map(&glob_regex/1)

    fn path ->
      basename = Path.basename(path)
      Enum.any?(regexes, &(Regex.match?(&1, path) or Regex.match?(&1, basename)))
    end
  end

  defp glob_matcher(_glob), do: fn _path -> true end

  defp glob_regex(pattern) do
    source =
      pattern
      |> String.replace("\\", "/")
      |> String.trim_leading("/")
      |> String.graphemes()
      |> Enum.map(fn
        "*" -> ".*"
        "?" -> "."
        char -> Regex.escape(char)
      end)
      |> IO.iodata_to_binary()

    Regex.compile!("^" <> source <> "$")
  end

  defp expand_braces(pattern) do
    case Regex.run(~r/\{([^{}]+)\}/, pattern, return: :index) do
      [{start, length}, {content_start, content_length}] ->
        prefix = binary_part(pattern, 0, start)
        suffix_start = start + length
        suffix = binary_part(pattern, suffix_start, byte_size(pattern) - suffix_start)

        pattern
        |> binary_part(content_start, content_length)
        |> String.split(",", trim: true)
        |> Enum.flat_map(&expand_braces(prefix <> &1 <> suffix))

      nil ->
        [pattern]
    end
  end

  defp context_before(input) do
    context = int_value(input, ["context", :context, "-C"])
    before = int_value(input, ["before_context", :before_context, "-B"])
    min(if(context > 0, do: context, else: before), @max_context)
  end

  defp context_after(input) do
    context = int_value(input, ["context", :context, "-C"])
    after_context = int_value(input, ["after_context", :after_context, "-A"])
    min(if(context > 0, do: context, else: after_context), @max_context)
  end

  defp limit(input) do
    case int_value(input, ["limit", :limit]) do
      value when value > 0 -> min(value, 1_000)
      _ -> @default_limit
    end
  end

  defp int_value(input, keys) do
    Enum.find_value(keys, 0, fn key ->
      case Map.get(input, key) do
        value when is_integer(value) -> value
        value when is_binary(value) -> parse_int(value)
        _ -> nil
      end
    end)
  end

  defp parse_int(value) do
    case Integer.parse(value) do
      {integer, _} -> integer
      :error -> nil
    end
  end

  defp truthy?(value), do: value in [true, "true", "1", 1]

  defp emit_telemetry(started_at, file_count, result_count, matcher, status) do
    :telemetry.execute(
      [:handbean, :search, :grep],
      %{
        duration_ms: System.monotonic_time(:millisecond) - started_at,
        file_count: file_count,
        result_count: result_count
      },
      %{matcher: matcher, status: status}
    )
  end
end
