defmodule Handbean.CsvProfile.Analyzer do
  @moduledoc "CSV profiling core logic."

  alias Handbean.CsvProfile.Error

  @boolean_values MapSet.new(["true", "false", "1", "0", "yes", "no"])

  def analyze(path) when is_binary(path) do
    with {:ok, content} <- read_file(path),
         {:ok, rows} <- parse_csv(content),
         {:ok, headers, data_rows} <- split_rows(rows),
         {:ok, stats} <- build_stats(headers, data_rows) do
      {:ok, %{file: path, total_rows: length(data_rows), columns: stats}}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, ""} ->
        {:error, %Error{code: :empty_file, message: "file is empty", path: path}}

      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        {:error, %Error{code: :file_not_found, message: "file does not exist", path: path}}

      {:error, reason} ->
        {:error,
         %Error{
           code: :unable_to_read,
           message: "unable to read file: #{:file.format_error(reason)}",
           path: path
         }}
    end
  end

  defp parse_csv(content) do
    rows =
      content
      |> String.trim_trailing()
      |> String.split("\n", trim: false)
      |> Enum.map(&(&1 |> String.trim_trailing("\r") |> parse_csv_line()))

    if Enum.any?(rows, &match?({:error, _}, &1)) do
      {:error, %Error{code: :invalid_csv, message: "invalid CSV format"}}
    else
      {:ok, Enum.map(rows, fn {:ok, row} -> row end)}
    end
  end

  defp parse_csv_line(line) do
    try do
      {:ok, parse_fields(String.to_charlist(line), [], [], false) |> Enum.map(&List.to_string/1)}
    rescue
      ArgumentError -> {:error, :invalid_csv}
      RuntimeError -> {:error, :invalid_csv}
    end
  end

  defp parse_fields([], acc, current, false), do: Enum.reverse([Enum.reverse(current) | acc])
  defp parse_fields([], _acc, _current, true), do: raise(ArgumentError, "unclosed quote")
  defp parse_fields([?" | rest], acc, current, false), do: parse_quoted(rest, acc, current)

  defp parse_fields([?, | rest], acc, current, false),
    do: parse_fields(rest, [Enum.reverse(current) | acc], [], false)

  defp parse_fields([char | rest], acc, current, false),
    do: parse_fields(rest, acc, [char | current], false)

  defp parse_quoted([], _acc, _current), do: raise(ArgumentError, "unclosed quote")

  defp parse_quoted([34, 44 | rest], acc, current),
    do: parse_fields(rest, [Enum.reverse(current) | acc], [], false)

  defp parse_quoted([34], acc, current), do: Enum.reverse([Enum.reverse(current) | acc])
  defp parse_quoted([34 | rest], acc, current), do: parse_fields(rest, acc, current, false)
  defp parse_quoted([char | rest], acc, current), do: parse_quoted(rest, acc, [char | current])

  defp split_rows([]), do: {:error, %Error{code: :empty_file, message: "file is empty"}}

  defp split_rows([headers | rows]) do
    case Enum.find_index(rows, fn row -> length(row) != length(headers) end) do
      nil ->
        {:ok, headers, rows}

      idx ->
        {:error,
         %Error{
           code: :column_mismatch,
           message:
             "row #{idx + 2} has #{length(Enum.at(rows, idx))} columns; expected #{length(headers)}"
         }}
    end
  end

  defp build_stats(headers, rows) do
    columns =
      headers
      |> Enum.with_index()
      |> Enum.map(fn {header, idx} ->
        stats_for_column(header, Enum.map(rows, &Enum.at(&1, idx, "")))
      end)

    {:ok, columns}
  end

  defp stats_for_column(name, values) do
    total = length(values)
    empty_count = Enum.count(values, &empty?/1)
    non_empty = total - empty_count
    non_empty_values = Enum.reject(values, &empty?/1)
    type = infer_type(non_empty_values)
    frequencies = Enum.frequencies(values)

    top_values =
      frequencies
      |> Enum.sort_by(fn {v, c} -> {-c, v} end)
      |> Enum.take(3)
      |> Enum.map(fn {value, count} -> %{value: value, count: count} end)

    %{
      name: name,
      total_rows: total,
      empty_count: empty_count,
      non_empty_count: non_empty,
      unique_count: map_size(frequencies),
      type: type,
      top_values: top_values
    }
  end

  defp infer_type([]), do: :empty

  defp infer_type(values) do
    cond do
      Enum.all?(values, &integer?/1) -> :integer
      Enum.all?(values, &float?/1) -> :float
      Enum.all?(values, &boolean?/1) -> :boolean
      true -> :string
    end
  end

  defp integer?(value),
    do: match?({int, ""} when is_integer(int), Integer.parse(String.trim(value)))

  defp float?(value),
    do: match?({float, ""} when is_float(float), Float.parse(String.trim(value)))

  defp boolean?(value), do: String.downcase(String.trim(value)) in @boolean_values
  defp empty?(value), do: String.trim(value) == ""
end
