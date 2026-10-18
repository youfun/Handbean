defmodule Handbean.CsvProfile.Format do
  @moduledoc "Formatting helpers for CSV profile output."

  def text(%{file: file, total_rows: total_rows, columns: columns}) do
    [
      "CSV Profile Report",
      "File: #{file}",
      "Total rows: #{total_rows}",
      "",
      Enum.map_join(columns, "\n\n", &format_column/1)
    ]
    |> Enum.join("\n")
  end

  def json(report), do: Handbean.JSON.encode!(report)

  defp format_column(column) do
    top_values =
      column.top_values
      |> Enum.map_join(", ", fn %{value: value, count: count} ->
        "#{inspect(value)} (#{count})"
      end)

    [
      "Column: #{column.name}",
      "  Type: #{column.type}",
      "  Total values: #{column.total_rows}",
      "  Empty values: #{column.empty_count}",
      "  Non-empty values: #{column.non_empty_count}",
      "  Unique values: #{column.unique_count}",
      "  Top 3 values: #{top_values}"
    ]
    |> Enum.join("\n")
  end
end
