defmodule HandbeanProbe.ScriptCSVTest do
  use ExUnit.Case, async: false

  alias NimbleCSV.RFC4180, as: CSV

  @csv "name,note,empty\r\n张三,\"上海,浦东\",\r\n李四,\"他说\"\"你好\"\"\",\r\n王五,\"第一行\n第二行\",\r\n"
  @rows [
    ["name", "note", "empty"],
    ["张三", "上海,浦东", ""],
    ["李四", "他说\"你好\"", ""],
    ["王五", "第一行\n第二行", ""]
  ]

  test "runtime dependency parses quoted UTF-8 CSV and roundtrips every field" do
    assert :nimble_csv in Application.spec(:handbean_probe, :applications)
    assert CSV.parse_string(@csv, skip_headers: false) == @rows
    assert CSV.parse_string(@csv) == tl(@rows)

    assert @rows
           |> CSV.dump_to_iodata()
           |> IO.iodata_to_binary()
           |> CSV.parse_string(skip_headers: false) == @rows
  end

  test "the formal script tool can stream multiline CSV and write a roundtrip" do
    dir = Path.join(System.tmp_dir!(), "script_csv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.write!(Path.join(dir, "input.csv"), @csv)

    File.write!(Path.join(dir, "verify.exs"), """
    rows = Path.join(workspace, "input.csv")
      |> File.stream!()
      |> NimbleCSV.RFC4180.parse_stream(skip_headers: false)
      |> Enum.to_list()
    File.write!(Path.join(workspace, "output.csv"), NimbleCSV.RFC4180.dump_to_iodata(rows))
    rows
    """)

    assert {:ok, _, _} =
             Handbean.Tool.Builtin.RunElixirScript.execute(%{"path" => "verify.exs"}, %{
               working_directory: dir
             })

    assert dir |> Path.join("output.csv") |> File.read!() |> CSV.parse_string(skip_headers: false) ==
             @rows
  end

  test "script tool advertises the installed parser and header semantics" do
    previous = Application.get_env(:handbean, :host)

    try do
      Handbean.Host.put!(%{shell: false, host_script: true})
      prompt = Handbean.Tool.Builtin.RunElixirScript.description()
      assert prompt =~ "NimbleCSV.RFC4180 is installed"
      assert prompt =~ "skip_headers: false"
      assert prompt =~ "dump_to_iodata(rows)"
    after
      if previous,
        do: Application.put_env(:handbean, :host, previous),
        else: Application.delete_env(:handbean, :host)
    end
  end
end
