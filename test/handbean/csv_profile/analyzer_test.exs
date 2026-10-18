defmodule Handbean.CsvProfile.AnalyzerTest do
  use ExUnit.Case, async: true

  alias Handbean.CsvProfile.Analyzer

  test "normal csv parsing and stats" do
    path = Path.join(System.tmp_dir!(), "csv_profile_ok.csv")
    File.write!(path, "name,age,active\nAlice,30,true\nBob,25,false\nAlice,40,yes\n")

    try do
      {:ok, report} = Analyzer.analyze(path)
      assert report.total_rows == 3
      assert length(report.columns) == 3
      assert Enum.find(report.columns, &(&1.name == "age")).type == :integer
      assert Enum.find(report.columns, &(&1.name == "active")).type == :boolean

      assert Enum.find(report.columns, &(&1.name == "name")).top_values |> hd() |> Map.get(:value) ==
               "Alice"
    after
      File.rm(path)
    end
  end

  test "type inference" do
    path = Path.join(System.tmp_dir!(), "csv_profile_types.csv")
    File.write!(path, "i,f,b,s,e\n1,1.5,yes,abc,\n2,2.0,no,def,\n")

    try do
      {:ok, report} = Analyzer.analyze(path)
      types = Map.new(report.columns, &{&1.name, &1.type})
      assert types["i"] == :integer
      assert types["f"] == :float
      assert types["b"] == :boolean
      assert types["s"] == :string
      assert types["e"] == :empty
    after
      File.rm(path)
    end
  end

  test "file empty error" do
    path = Path.join(System.tmp_dir!(), "csv_profile_empty.csv")
    File.write!(path, "")

    try do
      {:error, error} = Analyzer.analyze(path)
      assert error.code == :empty_file
    after
      File.rm(path)
    end
  end

  test "column mismatch error" do
    path = Path.join(System.tmp_dir!(), "csv_profile_bad_cols.csv")
    File.write!(path, "a,b\n1,2\n3\n")

    try do
      {:error, error} = Analyzer.analyze(path)
      assert error.code == :column_mismatch
    after
      File.rm(path)
    end
  end

  test "invalid csv error" do
    path = Path.join(System.tmp_dir!(), "csv_profile_invalid.csv")
    File.write!(path, "a,b\n\"unclosed,2\n")

    try do
      {:error, error} = Analyzer.analyze(path)
      assert error.code == :invalid_csv
    after
      File.rm(path)
    end
  end
end
