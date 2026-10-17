changed_lines =
  case System.get_env("HANDBEAN_CREDENCE_DIFF") do
    nil ->
      nil

    diff_path ->
      diff_path
      |> File.read!()
      |> String.split("\n")
      |> Enum.reduce({nil, %{}}, fn
        "+++ b/" <> file, {_current, lines} ->
          {file, Map.put_new(lines, file, MapSet.new())}

        "@@ " <> hunk, {file, lines} when is_binary(file) ->
          case Regex.run(~r/\+(\d+)(?:,(\d+))?/, hunk, capture: :all_but_first) do
            [start, count] ->
              first = String.to_integer(start)
              last = first + String.to_integer(count) - 1
              added = if last < first, do: MapSet.new(), else: MapSet.new(first..last)
              {file, Map.update!(lines, file, &MapSet.union(&1, added))}

            [start] ->
              line = String.to_integer(start)
              {file, Map.update!(lines, file, &MapSet.put(&1, line))}

            nil ->
              {file, lines}
          end

        _line, acc ->
          acc
      end)
      |> elem(1)
  end

files =
  case changed_lines do
    nil -> Path.wildcard("lib/**/*.ex") ++ Path.wildcard("test/support/**/*.ex")
    lines -> Map.keys(lines)
  end

issues =
  files
  |> Enum.flat_map(fn file ->
    code = File.read!(file)
    result = Credence.analyze(code, [])

    Enum.map(result.issues, fn issue ->
      {file, issue}
    end)
  end)
  |> Enum.filter(fn {file, issue} ->
    case changed_lines do
      nil ->
        true

      lines ->
        line = issue.meta[:line]
        is_integer(line) and MapSet.member?(Map.get(lines, file, MapSet.new()), line)
    end
  end)

if issues == [] do
  IO.puts("Credence found no issues.")
else
  IO.puts("Credence findings:")

  Enum.each(issues, fn {file, issue} ->
    line = issue.meta[:line] || "?"
    IO.puts("#{file}:#{line} #{issue.rule} #{issue.message}")
  end)

  System.halt(1)
end
