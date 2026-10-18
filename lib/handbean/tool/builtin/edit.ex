defmodule Handbean.Tool.Builtin.Edit do
  @moduledoc """
  Edit files with precise string replacement.

  Two-layer matching: exact match → fuzzy match (5-step normalization).
  Supports BOM detection, CRLF handling, and diff generation.
  """

  @behaviour Handbean.Agent.Tool

  @max_file_bytes 10_485_760
  @bom <<0xEF, 0xBB, 0xBF>>

  @impl true
  def name, do: "edit"

  @impl true
  def description do
    "Replace text in a file using exact string replacement. " <>
      "Use old_string/new_string for one replacement, or edits/replacements for multiple " <>
      "ordered replacements in one call. Prefer edit for precise changes; use write only for " <>
      "new files or complete rewrites. If matching fails, re-read the file and retry with " <>
      "current exact text. Supports fuzzy matching for whitespace/normalization differences."
  end

  @impl true
  def hint do
    "Re-read the file and retry with the current exact text, including whitespace. " <>
      "Do not repeat the same old_string."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        file_path: %{type: "string", description: "Path to the file to edit"},
        old_string: %{
          type: "string",
          description:
            "Text to replace for a single edit (must be unique unless replace_all is true)"
        },
        new_string: %{type: "string", description: "Replacement text for a single edit"},
        edits: %{
          type: "array",
          description:
            "Multiple ordered replacements to apply in one call. Use this instead of repeated edit calls for separate precise changes.",
          items: %{
            type: "object",
            properties: %{
              old_string: %{
                type: "string",
                description: "Text to replace (must be unique unless replace_all is true)"
              },
              new_string: %{type: "string", description: "Replacement text"},
              replace_all: %{
                type: "boolean",
                description: "Replace all occurrences for this replacement",
                default: false
              }
            },
            required: ["old_string", "new_string"]
          }
        },
        replacements: %{
          type: "array",
          description: "Alias for edits. Each item has old_string and new_string."
        },
        replace_all: %{type: "boolean", description: "Replace all occurrences", default: false},
        mode: %{
          type: "string",
          description: "Edit mode: replace (default) or diff",
          default: "replace"
        },
        diff: %{
          type: "string",
          description: "Unified diff content (when mode=diff)"
        },
        retry_of: %{
          type: "string",
          description:
            "operation_id from a failed edit. Reuses saved new_string/diff; override only old_string or file_path."
        }
      },
      required: ["file_path"]
    }
  end

  @impl true
  def max_result_chars, do: 5_000

  @impl true
  def concurrent?, do: false

  @impl true
  def execute(%{"mode" => "diff"} = input, context) do
    with {:ok, input, operation_id} <-
           Handbean.Agent.Tool.SavedInput.prepare("edit", input, context, ["file_path"]) do
      result = run_prepared_diff(operation_id, input, context)

      Handbean.Agent.Tool.SavedInput.attach(
        operation_id,
        result,
        context,
        ["file_path"]
      )
    end
  end

  def execute(%{"file_path" => fp} = input, context) do
    with {:ok, input, operation_id} <-
           Handbean.Agent.Tool.SavedInput.prepare("edit", input, context, [
             "file_path",
             "old_string"
           ]) do
      result = run_prepared_replace(input, fp, context, operation_id)

      Handbean.Agent.Tool.SavedInput.attach(
        operation_id,
        result,
        context,
        ["file_path", "old_string"]
      )
    end
  end

  def execute(_input, _context) do
    {:error, "file_path and either old_string/new_string or edits are required"}
  end

  defp run_prepared_replace(input, fp, context, operation_id) do
    with {:ok, replacements} <- normalize_replacements(input),
         {:ok, path} <- Handbean.Agent.Tool.resolve_path(fp, context),
         :ok <- Handbean.Security.PathValidator.validate_writeable(path),
         :ok <- validate_replacements(replacements),
         :ok <- validate_file(path),
         :ok <- check_not_binary(path),
         {:ok, raw} <- File.read(path) do
      {content, bom} = strip_bom(raw)
      {normalized, line_ending} = detect_line_endings(content)

      case apply_replacements(normalized, replacements) do
        {:ok, edited, count} ->
          restored = restore_line_endings(edited, line_ending)
          final = restore_bom(restored, bom)

          case Handbean.Agent.Tool.FileCommit.commit(path, final, context,
                 operation_id: operation_id
               ) do
            {:ok, commit} ->
              _ = Handbean.Extension.HotReloader.notify_path(path)
              diff = compute_diff(normalized, edited)
              diff_lines = diff_to_lines(diff)
              change = Handbean.ChangeSnapshot.build_edit_snapshot(path, raw, final, diff_lines)
              change_details = Handbean.ChangeSnapshot.result_details(change, context)

              {:ok, "Edited #{path}: #{count} replacement(s)\n#{diff_text(diff)}",
               Map.merge(change_details, %{
                 file_path: path,
                 operation_id: commit.operation_id,
                 status: :succeeded,
                 side_effect: commit.side_effect,
                 replacements: count,
                 edit_count: length(replacements),
                 diff_first_changed_line: diff.first_changed_line,
                 diff_lines: diff_lines
               })}

            {:error, reason, details} ->
              {:error, reason, details}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp run_prepared_diff(operation_id, input, context),
    do: run_diff_mode(input, context, operation_id)

  # ── Validation ──

  defp normalize_replacements(input) do
    cond do
      is_list(input["edits"]) -> normalize_replacement_list(input["edits"])
      is_list(input["replacements"]) -> normalize_replacement_list(input["replacements"])
      is_binary(input["old_string"]) and is_binary(input["new_string"]) -> normalize_single(input)
      true -> {:error, "old_string/new_string or edits are required"}
    end
  end

  defp normalize_single(input) do
    {:ok,
     [
       %{
         old_string: input["old_string"],
         new_string: input["new_string"],
         replace_all: Map.get(input, "replace_all", false)
       }
     ]}
  end

  defp normalize_replacement_list([]), do: {:error, "edits must contain at least one replacement"}

  defp normalize_replacement_list(items) do
    items
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case normalize_replacement_item(item, index) do
        {:ok, replacement} -> {:cont, {:ok, [replacement | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, replacements} -> {:ok, Enum.reverse(replacements)}
      error -> error
    end
  end

  defp normalize_replacement_item(item, index) when is_map(item) do
    old =
      Handbean.Utils.SafeMap.get_any(item, "old_string", :old_string) ||
        Handbean.Utils.SafeMap.get_any(item, "oldText", :oldText)

    new =
      Handbean.Utils.SafeMap.get_any(item, "new_string", :new_string) ||
        Handbean.Utils.SafeMap.get_any(item, "newText", :newText)

    replace_all =
      Handbean.Utils.SafeMap.get_any(item, "replace_all", :replace_all) || false

    if is_binary(old) and is_binary(new) do
      {:ok, %{old_string: old, new_string: new, replace_all: replace_all}}
    else
      {:error, "edit ##{index} must include old_string and new_string"}
    end
  end

  defp normalize_replacement_item(_item, index) do
    {:error, "edit ##{index} must be an object with old_string and new_string"}
  end

  defp validate_replacements(replacements) do
    replacements
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {replacement, index}, :ok ->
      case validate_params(replacement.old_string, replacement.new_string, index) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_params("", _, index), do: {:error, "edit ##{index}: old_string cannot be empty"}

  defp validate_params(old, new, index) when old == new,
    do: {:error, "edit ##{index}: old_string and new_string are identical"}

  defp validate_params(_, _, _), do: :ok

  defp validate_file(path) do
    cond do
      not File.exists?(path) -> {:error, "File not found: #{path}"}
      File.dir?(path) -> {:error, "#{path}: Is a directory"}
      true -> validate_file_size(path)
    end
  end

  defp validate_file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_file_bytes ->
        mb = Float.round(size / 1_048_576, 1)
        {:error, "File too large (#{mb} MB). Max #{div(@max_file_bytes, 1_048_576)} MB."}

      _ ->
        :ok
    end
  end

  # ── BOM handling ──

  defp strip_bom(<<@bom, rest::binary>>), do: {rest, @bom}
  defp strip_bom(content), do: {content, nil}

  defp restore_bom(content, nil), do: content
  defp restore_bom(content, bom), do: bom <> content

  # ── Line endings ──

  defp detect_line_endings(content) do
    ending = if String.contains?(content, "\r\n"), do: :crlf, else: :lf
    {String.replace(content, "\r\n", "\n"), ending}
  end

  defp restore_line_endings(content, :lf), do: content
  defp restore_line_endings(content, :crlf), do: String.replace(content, "\n", "\r\n")

  # ── Edit logic ──

  defp apply_replacements(content, replacements) do
    replacements
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, content, 0}, fn {replacement, index}, {:ok, current, total} ->
      old_lf = String.replace(replacement.old_string, "\r\n", "\n")
      new_lf = String.replace(replacement.new_string, "\r\n", "\n")

      case apply_edit(current, old_lf, new_lf, replacement.replace_all, index) do
        {:ok, edited, count} -> {:cont, {:ok, edited, total + count}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, edited, count} -> {:ok, edited, count}
      error -> error
    end
  end

  defp apply_edit(content, old_str, new_str, replace_all, index) do
    case count_occurrences(content, old_str) do
      0 ->
        fuzzy_edit(content, old_str, new_str, replace_all, index)

      1 ->
        {:ok, String.replace(content, old_str, new_str, global: false), 1}

      n when replace_all ->
        {:ok, String.replace(content, old_str, new_str), n}

      n ->
        {:error,
         "edit ##{index}: Found #{n} occurrences. Text must be unique — provide more context."}
    end
  end

  defp fuzzy_edit(content, old_str, new_str, replace_all, index) do
    norm_content = normalize(content)
    norm_old = normalize(old_str)

    case count_occurrences(norm_content, norm_old) do
      0 ->
        {:error,
         "edit ##{index}: Could not find text. Re-read the file and retry with the current exact text, including whitespace and newlines."}

      1 ->
        case find_fuzzy_range(content, old_str) do
          {:ok, start, len} ->
            before = binary_part(content, 0, start)
            after_text = binary_part(content, start + len, byte_size(content) - start - len)
            {:ok, before <> new_str <> after_text, 1}

          :error ->
            {:error,
             "edit ##{index}: Could not locate text after fuzzy matching. Re-read the file and retry with the current exact text."}
        end

      n when replace_all ->
        {:ok, fuzzy_replace_all(content, old_str, new_str), n}

      n ->
        {:error, "edit ##{index}: Found #{n} fuzzy matches. Text must be unique."}
    end
  end

  defp find_fuzzy_range(content, old_str) do
    norm_old = normalize(old_str)
    lines = String.split(content, "\n")
    old_lines = String.split(old_str, "\n")
    old_count = length(old_lines)

    result =
      lines
      |> Enum.with_index()
      |> Enum.find(fn {_line, idx} ->
        window = Enum.slice(lines, idx, old_count)
        normalize(Enum.join(window, "\n")) == norm_old
      end)

    case result do
      {_line, idx} ->
        before = Enum.take(lines, idx)
        before_bytes = byte_size(Enum.join(before, "\n"))
        start = if idx == 0, do: 0, else: before_bytes + 1
        matched = Enum.slice(lines, idx, old_count)
        matched_bytes = byte_size(Enum.join(matched, "\n"))
        {:ok, start, matched_bytes}

      nil ->
        :error
    end
  end

  defp fuzzy_replace_all(content, old_str, new_str) do
    case find_fuzzy_range(content, old_str) do
      {:ok, start, len} ->
        before = binary_part(content, 0, start)
        after_text = binary_part(content, start + len, byte_size(content) - start - len)
        fuzzy_replace_all(before <> new_str <> after_text, old_str, new_str)

      :error ->
        content
    end
  end

  # ── 5-step normalization ──

  defp normalize(text) do
    text
    |> strip_trailing_spaces()
    |> normalize_quotes()
    |> normalize_dashes()
    |> normalize_spaces()
    |> :unicode.characters_to_nfd_binary()
  end

  defp strip_trailing_spaces(text) do
    text |> String.split("\n") |> Enum.map_join("\n", &String.trim_trailing/1)
  end

  defp normalize_quotes(text) do
    text
    |> String.replace(~r/[\x{2018}\x{2019}\x{201A}\x{201B}]/u, "'")
    |> String.replace(~r/[\x{201C}\x{201D}\x{201E}\x{201F}]/u, "\"")
  end

  defp normalize_dashes(text) do
    String.replace(text, ~r/[\x{2010}-\x{2015}\x{2212}]/u, "-")
  end

  defp normalize_spaces(text) do
    String.replace(text, ~r/[\x{00A0}\x{2002}-\x{200A}\x{3000}]/u, " ")
  end

  # ── Diff ──

  @diff_context_lines 3

  defp compute_diff(old, new) when old == new, do: %{content: nil, first_changed_line: nil}

  defp compute_diff(old, new) do
    old_lines = String.split(old, "\n")
    new_lines = String.split(new, "\n")

    first_changed =
      Enum.zip(old_lines, new_lines)
      |> Enum.find_index(fn {a, b} -> a != b end)
      |> Kernel.||(min(length(old_lines), length(new_lines)))

    diff_list = List.myers_difference(old_lines, new_lines)
    %{content: diff_list, first_changed_line: first_changed + 1}
  end

  defp diff_text(%{content: nil}), do: "(no changes)"
  defp diff_text(%{content: []}), do: "(no changes)"

  defp diff_text(%{content: diff}) do
    diff
    |> Enum.flat_map(fn
      {:eq, lines} -> Enum.map(lines, &("  " <> &1))
      {:del, lines} -> Enum.map(lines, &("- " <> &1))
      {:ins, lines} -> Enum.map(lines, &("+ " <> &1))
    end)
    |> Enum.join("\n")
  end

  defp diff_to_lines(%{content: nil}), do: nil
  defp diff_to_lines(%{content: []}), do: nil

  defp diff_to_lines(%{content: diff}) do
    diff
    |> clip_diff_context()
    |> Enum.flat_map(fn
      {:eq, lines} -> Enum.map(lines, &%{"type" => "eq", "text" => &1})
      {:del, lines} -> Enum.map(lines, &%{"type" => "del", "text" => &1})
      {:ins, lines} -> Enum.map(lines, &%{"type" => "ins", "text" => &1})
      {:skip, count} -> [%{"type" => "skip", "text" => "... #{count} unchanged lines ..."}]
    end)
  end

  # ── Diff context clipping ──

  defp clip_diff_context(diff) do
    change_indices =
      diff
      |> Enum.with_index()
      |> Enum.filter(fn {{type, _lines}, _i} -> type != :eq end)
      |> Enum.map(fn {_chunk, i} -> i end)

    if change_indices == [] do
      diff
    else
      first = hd(change_indices)
      last = List.last(change_indices)
      ctx = @diff_context_lines

      Enum.flat_map(Enum.with_index(diff), fn {{type, lines}, i} ->
        case type do
          :eq ->
            cond do
              i < first -> clip_before(lines, ctx)
              i > last -> clip_after(lines, ctx)
              true -> clip_middle(lines, ctx)
            end

          :del ->
            [{:del, lines}]

          :ins ->
            [{:ins, lines}]
        end
      end)
    end
  end

  defp clip_before(lines, ctx) when length(lines) <= ctx, do: [{:eq, lines}]

  defp clip_before(lines, ctx) do
    keep = Enum.take(lines, -ctx)
    skipped = length(lines) - ctx
    [{:skip, skipped}, {:eq, keep}]
  end

  defp clip_after(lines, ctx) when length(lines) <= ctx, do: [{:eq, lines}]

  defp clip_after(lines, ctx) do
    keep = Enum.take(lines, ctx)
    skipped = length(lines) - ctx
    [{:eq, keep}, {:skip, skipped}]
  end

  defp clip_middle(lines, ctx) when length(lines) <= ctx * 2, do: [{:eq, lines}]

  defp clip_middle(lines, ctx) do
    head = Enum.take(lines, ctx)
    tail = Enum.take(lines, -ctx)
    skipped = length(lines) - ctx * 2
    [{:eq, head}, {:skip, skipped}, {:eq, tail}]
  end

  # ── Binary detection ──

  defp check_not_binary(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        chunk = IO.binread(device, 8192)
        File.close(device)

        case chunk do
          :eof ->
            :ok

          data when is_binary(data) ->
            if :binary.match(data, <<0>>) != :nomatch do
              {:error, "Binary file detected: #{path}. Edit only supports text files."}
            else
              :ok
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  # ── Diff mode ──

  defp run_diff_mode(%{"file_path" => fp, "diff" => diff}, context, operation_id) do
    with {:ok, path} <- Handbean.Agent.Tool.resolve_path(fp, context),
         :ok <- Handbean.Security.PathValidator.validate_writeable(path),
         :ok <- validate_diff_input(diff),
         :ok <- check_file_exists(path),
         :ok <- check_not_binary(path),
         {:ok, raw} <- File.read(path) do
      case apply_unified_diff(raw, diff) do
        {:ok, new_content, changes} ->
          case Handbean.Agent.Tool.FileCommit.commit(path, new_content, context,
                 operation_id: operation_id
               ) do
            {:ok, commit} ->
              _ = Handbean.Extension.HotReloader.notify_path(path)
              diff_map = compute_diff(raw, new_content)
              diff_lines = diff_to_lines(diff_map)

              change =
                Handbean.ChangeSnapshot.build_edit_snapshot(path, raw, new_content, diff_lines)

              change_details = Handbean.ChangeSnapshot.result_details(change, context)

              {:ok, "Edited #{path}: #{changes} change(s) (diff mode)\n#{diff_text(diff_map)}",
               Map.merge(change_details, %{
                 file_path: path,
                 operation_id: operation_id,
                 status: :succeeded,
                 side_effect: commit.side_effect,
                 replacements: changes,
                 mode: "diff",
                 diff_first_changed_line: diff_map.first_changed_line,
                 diff_lines: diff_lines
               })}

            {:error, reason, details} ->
              {:error, reason, details}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp run_diff_mode(_input, _context, _operation_id) do
    {:error, "diff parameter is required when mode=diff"}
  end

  defp validate_diff_input(nil), do: {:error, "diff parameter is required when mode=diff"}
  defp validate_diff_input(""), do: {:error, "diff parameter cannot be empty"}
  defp validate_diff_input(_), do: :ok

  defp check_file_exists(path) do
    if File.exists?(path) and not File.dir?(path),
      do: :ok,
      else: {:error, "File not found: #{path}"}
  end

  # ── Unified diff application ──

  @doc false
  def apply_unified_diff(content, diff_text) do
    lines = String.split(content, "\n")
    diff_lines = String.split(diff_text, "\n")

    hunks = parse_diff_hunks(diff_lines)

    if hunks == [] do
      {:error, "No valid hunks found in diff"}
    else
      # Apply hunks in reverse order to avoid line offset drift
      result =
        Enum.reduce(Enum.reverse(hunks), lines, fn hunk, acc ->
          apply_hunk(acc, hunk)
        end)

      changes = Enum.reduce(hunks, 0, fn hunk, acc -> acc + hunk.change_count end)

      if changes > 0 do
        {:ok, Enum.join(result, "\n"), changes}
      else
        {:error, "No changes applied from diff"}
      end
    end
  end

  defp parse_diff_hunks(diff_lines) do
    {hunks, _current} =
      Enum.reduce(diff_lines, {[], nil}, fn line, {hunks, current} ->
        case line do
          # Hunk header: @@ -old_start,old_count +new_start,new_count @@
          <<"@@", _::binary>> ->
            case Regex.run(~r/@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/, line) do
              [_, old_start_str | rest] ->
                old_start = String.to_integer(old_start_str)
                {old_count_str, _new_start_str} = extract_hunk_counts(rest)
                old_count = if old_count_str == "", do: 1, else: String.to_integer(old_count_str)

                hunk = %{
                  old_start: old_start,
                  old_count: old_count,
                  old_line: old_start - 1,
                  deletions: [],
                  additions: [],
                  change_count: 0
                }

                {[hunk | hunks], hunk}

              _ ->
                {hunks, current}
            end

          # Deleted line (appears in original but not in new)
          <<"-", rest::binary>> when current != nil ->
            hunk = %{
              current
              | deletions: [{current.old_line, rest} | current.deletions],
                change_count: current.change_count + 1
            }

            {replace_current(hunks, hunk), hunk}

          # Added line (appears in new but not in original)
          <<"+", rest::binary>> when current != nil ->
            hunk = %{
              current
              | additions: [{current.old_line, rest} | current.additions],
                change_count: current.change_count + 1
            }

            {replace_current(hunks, hunk), hunk}

          # Context line (unchanged)
          <<" ", _rest::binary>> when current != nil ->
            hunk = %{current | old_line: current.old_line + 1}
            {replace_current(hunks, hunk), hunk}

          # Non-diff lines (file headers, comments, empty lines) — skip
          _ ->
            {hunks, current}
        end
      end)

    # Hunks are in reverse order (we prepended). Reverse them back.
    Enum.reverse(hunks)
  end

  # Replace the head of the hunks list (most recent hunk)
  defp replace_current([_old | rest], new), do: [new | rest]
  defp replace_current([], _new), do: []

  defp apply_hunk(lines, hunk) do
    # Deletions happen at old_line (0-indexed positions in original)
    # Additions happen at old_line (insert before that line)
    # Process deletions and additions so we can apply them without offset drift
    del_indices =
      hunk.deletions
      |> Enum.map(fn {idx, _} -> idx end)
      |> Enum.sort(:desc)
      |> MapSet.new()

    # Build result by processing lines with additions interleaved
    # add_lines grouped by insertion point (descending)
    add_map =
      hunk.additions
      |> Enum.group_by(fn {idx, _} -> idx end, fn {_, content} -> content end)

    # Process lines from start to end
    # For each line: if it's deleted, skip it but include additions in its place.
    # If not deleted, include the line with additions inserted before it.
    lines
    |> Stream.with_index()
    |> Enum.reduce([], fn {line, idx}, acc ->
      additions_here = Map.get(add_map, idx, [])

      if MapSet.member?(del_indices, idx) do
        # Delete: skip this line, insert additions in its place
        additions_here ++ acc
      else
        # Keep line, insert additions before it
        [line | additions_here ++ acc]
      end
    end)
    |> Enum.reverse()
  end

  # Extract old_count and new_start from rest of regex capture (handles optional count)
  # rest = [old_count_str, new_start_str, new_count_str | _] if all groups matched
  # rest = [old_count_str, new_start_str] if new_count_str is absent
  defp extract_hunk_counts([count_str, new_start | _]), do: {count_str, new_start}
  defp extract_hunk_counts([new_start | _]), do: {"", new_start}
  defp extract_hunk_counts(_), do: {"", ""}

  # ── Helpers ──

  defp count_occurrences(haystack, needle) do
    length(String.split(haystack, needle)) - 1
  end
end
