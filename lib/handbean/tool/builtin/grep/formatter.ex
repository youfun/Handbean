defmodule Handbean.Tool.Builtin.Grep.Formatter do
  @moduledoc false

  alias Handbean.Tool.Builtin.Grep.ByteBudget

  @max_context 3

  @spec format_search([map()], String.t() | nil, map(), map(), map()) :: String.t()
  def format_search([], _cursor, inventory, _lines_by_path, _opts) do
    "No matches found" <> indexing_suffix(inventory)
  end

  def format_search(hits, next_cursor, inventory, lines_by_path, opts) do
    before_n = context_before(opts.input)
    after_n = context_after(opts.input)

    body =
      hits
      |> Enum.group_by(& &1.path)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("\n", fn {path, file_hits} ->
        lines = Map.get(lines_by_path, path, [])
        shown_path = if opts.absolute_paths?, do: Path.join(opts.workspace, path), else: path

        rendered =
          file_hits
          |> Enum.sort_by(& &1.line)
          |> Enum.flat_map(&format_hit(shown_path, lines, &1.line, before_n, after_n))
          |> Enum.uniq()
          |> Enum.join("\n")

        "== #{shown_path} ==\n" <>
          rendered <> capped_note(opts.capped, path, shown_path)
      end)

    continuation = if next_cursor, do: "next_cursor: #{next_cursor}\n", else: ""
    continuation <> body <> indexing_suffix(inventory)
  end

  @spec format_files([String.t()], map(), String.t(), boolean()) :: String.t()
  def format_files(files, inventory, workspace, absolute_paths?) do
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

    body <> indexing_suffix(inventory)
  end

  defp capped_note(capped, path, shown_path) do
    case capped do
      %{^path => more} -> "\n[+#{more} more in this file; pass path: #{shown_path} to see all]"
      _ -> ""
    end
  end

  defp format_hit(path, lines, index, before_n, after_n) do
    line_count = length(lines)

    if index <= line_count do
      start_i = max(1, index - before_n)
      end_i = min(line_count, index + after_n)

      for i <- start_i..end_i do
        separator = if i == index, do: ":", else: "-"
        text = lines |> Enum.at(i - 1) |> then(&ByteBudget.safe_text(&1 || ""))
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
end
