defmodule Handbean.Workspace.MixToolchainTest do
  use ExUnit.Case, async: false

  alias Handbean.Workspace.MixToolchain

  test "desktop host reports Mix and ExUnit from the running VM" do
    assert {:ok, info} = MixToolchain.info()
    assert info.source == :host
    assert info.mix?
    assert info.ex_unit?
    assert info.elixir == System.version()
    assert info.otp == to_string(:erlang.system_info(:otp_release))
    assert MixToolchain.available?()
    assert {:ok, loaded} = MixToolchain.ensure_loaded()
    assert loaded.source == :host
  end

  test "sync_to! copies Mix, ExUnit and Hex without Hex.HTTP.beam" do
    dest = Path.join(System.tmp_dir!(), "sigil_mix_tc_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dest) end)

    assert :ok = MixToolchain.sync_to!(dest)
    assert File.dir?(Path.join([dest, "mix", "ebin"]))
    assert File.dir?(Path.join([dest, "ex_unit", "ebin"]))
    assert File.dir?(Path.join([dest, "hex", "ebin"]))

    assert File.exists?(
             Path.join([dest, "mix", "ebin", "Elixir.Handbean.Workspace.MixShell.beam"])
           )

    refute File.exists?(Path.join([dest, "hex", "ebin", "Elixir.Hex.HTTP.beam"]))
    assert File.exists?(Path.join([dest, "hex", "ebin", "hex.app"]))

    manifest = dest |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
    assert manifest["elixir"] == System.version()
    assert manifest["otp"] == to_string(:erlang.system_info(:otp_release))
    assert manifest["hex"] == MixToolchain.hex_version()
    assert manifest["hex_http"] == "Handbean.Workspace.HexHttp"
  end

  test "pins Hex 2.4.1 for the packaged adapter" do
    assert MixToolchain.hex_version() == "2.4.1"
  end
end
