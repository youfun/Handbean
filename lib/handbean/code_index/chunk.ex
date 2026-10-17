defmodule Handbean.CodeIndex.Chunk do
  @moduledoc """
  Splits source into symbol-oriented chunks without tree-sitter.

  Fallback windows are about 100 lines with 20 lines of overlap. Chunks that
  look like secrets stay in the local FTS index but are marked `embed_skip`.
  """

  @max_lines 120
  @window 100
  @overlap 20
  @max_chunks 20_000

  @secret ~r/(?i)(api[_-]?key|secret|password|token|BEGIN [A-Z ]*PRIVATE KEY)\s*[:=]\s*\S{8,}/

  @type chunk :: %{
          start_line: pos_integer(),
          end_line: pos_integer(),
          symbol: String.t() | nil,
          kind: String.t(),
          text: String.t(),
          embed_skip: boolean()
        }

  @spec split(String.t(), String.t(), keyword()) :: [chunk()]
  def split(source, language, opts \\ []) when is_binary(source) and is_binary(language) do
    lines = String.split(source, ~r/\r?\n/, trim: false)
    max_chunks = Keyword.get(opts, :max_chunks, @max_chunks)

    lines
    |> blocks(language)
    |> Enum.take(max_chunks)
    |> Enum.map(&finish(&1, lines))
  end

  @doc "True when the chunk text looks like a secret assignment."
  @spec secret?(String.t()) :: boolean()
  def secret?(text) when is_binary(text), do: Regex.match?(@secret, text)
  def secret?(_), do: false

  defp blocks(lines, language) do
    case markers(language) do
      :windows ->
        windows(length(lines))

      {:markers, fun} ->
        headed = headed_blocks(lines, fun)
        if headed == [], do: windows(length(lines)), else: headed
    end
  end

  defp markers("elixir"), do: {:markers, &elixir_marker/1}
  defp markers("javascript"), do: {:markers, &js_marker/1}
  defp markers("typescript"), do: {:markers, &js_marker/1}
  defp markers("python"), do: {:markers, &python_marker/1}
  defp markers("go"), do: {:markers, &go_marker/1}
  defp markers("rust"), do: {:markers, &rust_marker/1}
  defp markers("c"), do: {:markers, &c_marker/1}
  defp markers("cpp"), do: {:markers, &c_marker/1}
  defp markers("markdown"), do: {:markers, &markdown_marker/1}
  defp markers(_), do: :windows

  defp headed_blocks(lines, fun) do
    indexed = Enum.with_index(lines, 1)

    heads =
      Enum.flat_map(indexed, fn {line, n} ->
        case fun.(line) do
          nil -> []
          {kind, symbol} -> [%{kind: kind, symbol: symbol, start_line: n}]
        end
      end)

    heads
    |> Enum.with_index()
    |> Enum.map(fn {head, idx} ->
      next = Enum.at(heads, idx + 1)
      last = if next, do: next.start_line - 1, else: length(lines)
      end_line = min(last, head.start_line + @max_lines - 1)
      Map.put(head, :end_line, max(end_line, head.start_line))
    end)
  end

  defp windows(0), do: []

  defp windows(total) do
    Stream.iterate(1, &(&1 + @window - @overlap))
    |> Enum.take_while(&(&1 <= total))
    |> Enum.map(fn start_line ->
      %{
        kind: "window",
        symbol: nil,
        start_line: start_line,
        end_line: min(total, start_line + @window - 1)
      }
    end)
  end

  defp finish(block, lines) do
    text =
      lines
      |> Enum.slice((block.start_line - 1)..(block.end_line - 1))
      |> Enum.join("\n")

    %{
      start_line: block.start_line,
      end_line: block.end_line,
      symbol: block.symbol,
      kind: block.kind,
      text: text,
      embed_skip: secret?(text)
    }
  end

  defp elixir_marker(line) do
    cond do
      match = Regex.run(~r/^\s*defmodule\s+([A-Za-z0-9_.]+)/, line) ->
        {"module", Enum.at(match, 1)}

      match = Regex.run(~r/^\s*defp?\s+([A-Za-z0-9_?!]+)/, line) ->
        {"function", Enum.at(match, 1)}

      match = Regex.run(~r/^\s*defmacro\s+([A-Za-z0-9_?!]+)/, line) ->
        {"macro", Enum.at(match, 1)}

      true ->
        nil
    end
  end

  defp js_marker(line) do
    cond do
      match = Regex.run(~r/^\s*(?:export\s+)?(?:async\s+)?function\s+([A-Za-z0-9_]+)/, line) ->
        {"function", Enum.at(match, 1)}

      match = Regex.run(~r/^\s*(?:export\s+)?class\s+([A-Za-z0-9_]+)/, line) ->
        {"class", Enum.at(match, 1)}

      true ->
        nil
    end
  end

  defp python_marker(line) do
    cond do
      match = Regex.run(~r/^\s*class\s+([A-Za-z0-9_]+)/, line) ->
        {"class", Enum.at(match, 1)}

      match = Regex.run(~r/^\s*(?:async\s+)?def\s+([A-Za-z0-9_]+)/, line) ->
        {"function", Enum.at(match, 1)}

      true ->
        nil
    end
  end

  defp go_marker(line) do
    cond do
      match = Regex.run(~r/^\s*func\s+(?:\([^)]+\)\s*)?([A-Za-z0-9_]+)/, line) ->
        {"function", Enum.at(match, 1)}

      match = Regex.run(~r/^\s*type\s+([A-Za-z0-9_]+)/, line) ->
        {"type", Enum.at(match, 1)}

      true ->
        nil
    end
  end

  defp rust_marker(line) do
    cond do
      match = Regex.run(~r/^\s*(?:pub\s+)?fn\s+([A-Za-z0-9_]+)/, line) ->
        {"function", Enum.at(match, 1)}

      match = Regex.run(~r/^\s*(?:pub\s+)?struct\s+([A-Za-z0-9_]+)/, line) ->
        {"type", Enum.at(match, 1)}

      true ->
        nil
    end
  end

  defp c_marker(line) do
    case Regex.run(~r/^[A-Za-z_][\w\s\*]+\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/, line) do
      [_, name] when name not in ~w(if for while switch return) -> {"function", name}
      _ -> nil
    end
  end

  defp markdown_marker(line) do
    case Regex.run(~r/^\#{1,6}\s+(.+)$/, line) do
      [_, title] -> {"heading", String.trim(title)}
      _ -> nil
    end
  end
end
