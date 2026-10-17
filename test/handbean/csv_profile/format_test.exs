defmodule Handbean.CsvProfile.FormatTest do
  use ExUnit.Case, async: true

  alias Handbean.CsvProfile.Format

  test "json output is valid json" do
    report = %{
      file: "sample.csv",
      total_rows: 2,
      columns: [
        %{
          name: "a",
          total_rows: 2,
          empty_count: 0,
          non_empty_count: 2,
          unique_count: 2,
          type: :integer,
          top_values: [%{value: "1", count: 1}, %{value: "2", count: 1}]
        }
      ]
    }

    json = Format.json(report)
    assert {:ok, decoded} = Jason.decode(json)
    assert decoded["file"] == "sample.csv"
  end
end
