defmodule Mix.Tasks.Mob.WriteMobExsTest do
  use ExUnit.Case, async: true

  test "checked-in template declares android static NIFs from the source snapshot" do
    template = File.read!(Mix.Tasks.Mob.WriteMobExs.template_path())

    assert template =~ "import Config"
    assert template =~ "%{module: :handbean_notify, archs: [:android]}"
    assert template =~ "%{module: :handbean_browser, archs: [:android]}"
    refute template =~ "%{module: :sigil_share, archs: [:android]}"
    refute template =~ "API_KEY"
    refute template =~ "token"
  end

  test "write! copies the template onto gitignored mob.exs" do
    dest = Mix.Tasks.Mob.WriteMobExs.dest_path()
    previous = if File.exists?(dest), do: File.read!(dest)

    on_exit(fn ->
      case previous do
        nil -> File.rm(dest)
        content -> File.write!(dest, content)
      end
    end)

    File.rm(dest)
    refute File.exists?(dest)

    written = Mix.Tasks.Mob.WriteMobExs.write!()
    assert written == dest
    assert File.read!(dest) == File.read!(Mix.Tasks.Mob.WriteMobExs.template_path())

    custom = File.read!(dest) <> "\n# local configuration\n"
    File.write!(dest, custom)
    assert Mix.Tasks.Mob.WriteMobExs.write!() == dest
    assert File.read!(dest) == custom
  end
end
