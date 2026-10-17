defmodule Handbean.Extension.LoaderTest do
  use ExUnit.Case, async: true

  alias Handbean.Extension.Loader

  @tmp_base Path.join(System.tmp_dir!(), "sigil_loader_test")

  setup do
    tmp = Path.join(@tmp_base, "test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp write_manifest(dir, name, overrides \\ %{}) do
    File.mkdir_p!(dir)
    manifest = Map.merge(%{"name" => name}, overrides)
    File.write!(Path.join(dir, "extension.json"), Jason.encode!(manifest))
  end

  defp write_invalid_json(dir) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "extension.json"), "not valid json {{{")
  end

  describe "from_project/1" do
    test "discovers project extensions from .handbean/extensions", %{tmp: tmp} do
      ext_dir = Path.join(tmp, ".handbean/extensions/my-ext")
      write_manifest(ext_dir, "my-ext", %{"version" => "0.1.0"})

      result = Loader.from_project(tmp)

      assert length(result.extensions) == 1
      ext = hd(result.extensions)
      assert ext.name == "my-ext"
      assert ext.version == "0.1.0"
      assert ext.root == ext_dir
    end

    test "returns empty when no .handbean/extensions directory", %{tmp: tmp} do
      result = Loader.from_project(tmp)
      assert result.extensions == []
    end

    test "returns empty when directory exists but is empty", %{tmp: tmp} do
      sigil_ext = Path.join(tmp, ".handbean/extensions")
      File.mkdir_p!(sigil_ext)

      result = Loader.from_project(tmp)
      assert result.extensions == []
    end

    test "prefers extension.json over manifest.json", %{tmp: tmp} do
      ext_dir = Path.join(tmp, ".handbean/extensions/my-ext")
      write_manifest(ext_dir, "my-ext", %{"version" => "0.1.0"})
      # Also write a manifest.json with different version
      File.write!(
        Path.join(ext_dir, "manifest.json"),
        Jason.encode!(%{"name" => "my-ext", "version" => "0.2.0"})
      )

      result = Loader.from_project(tmp)
      assert length(result.extensions) == 1
      ext = hd(result.extensions)
      assert ext.version == "0.1.0"
    end

    test "falls back to manifest.json", %{tmp: tmp} do
      ext_dir = Path.join(tmp, ".handbean/extensions/my-ext")
      File.mkdir_p!(ext_dir)

      File.write!(
        Path.join(ext_dir, "manifest.json"),
        Jason.encode!(%{"name" => "my-ext", "version" => "0.2.0"})
      )

      result = Loader.from_project(tmp)
      assert length(result.extensions) == 1
      ext = hd(result.extensions)
      assert ext.version == "0.2.0"
    end

    test "discovers nested extension directories", %{tmp: tmp} do
      nested = Path.join(tmp, ".handbean/extensions/group/my-ext")
      write_manifest(nested, "my-ext")

      result = Loader.from_project(tmp)
      assert length(result.extensions) == 1
    end

    test "skips hidden directories", %{tmp: tmp} do
      hidden = Path.join(tmp, ".handbean/extensions/.hidden-ext")
      write_manifest(hidden, "hidden-ext")

      result = Loader.from_project(tmp)
      assert result.extensions == []
    end

    test "skips node_modules", %{tmp: tmp} do
      nm = Path.join(tmp, ".handbean/extensions/node_modules/some-ext")
      write_manifest(nm, "some-ext")

      result = Loader.from_project(tmp)
      assert result.extensions == []
    end

    test "handles invalid JSON with diagnostic", %{tmp: tmp} do
      bad = Path.join(tmp, ".handbean/extensions/bad-ext")
      write_invalid_json(bad)

      result = Loader.from_project(tmp)
      assert result.extensions == []
      assert length(result.diagnostics) == 1
      assert hd(result.diagnostics).type == :parse_error
    end

    test "handles duplicate names (first wins)", %{tmp: tmp} do
      ext1 = Path.join(tmp, ".handbean/extensions/my-ext")
      ext2 = Path.join(tmp, ".handbean/extensions/deeper/my-ext")
      write_manifest(ext1, "my-ext", %{"version" => "0.1.0"})
      write_manifest(ext2, "my-ext", %{"version" => "0.2.0"})

      result = Loader.from_project(tmp)
      assert length(result.extensions) == 1
      ext = hd(result.extensions)
      # First discovered keeps version 0.1.0
      assert ext.version == "0.1.0"
      assert length(result.diagnostics) >= 1
    end

    test "disabled extension is loaded but not active", %{tmp: tmp} do
      ext_dir = Path.join(tmp, ".handbean/extensions/disabled-ext")
      write_manifest(ext_dir, "disabled-ext", %{"enabled" => false})

      result = Loader.from_project(tmp)
      assert length(result.extensions) == 1
      ext = hd(result.extensions)
      assert ext.enabled == false
    end
  end

  describe "from_user/2" do
    test "discovers user extensions from custom home", %{tmp: tmp} do
      home = Path.join(tmp, "fake_home")
      ext_dir = Path.join(home, ".handbean/extensions/user-ext")
      write_manifest(ext_dir, "user-ext", %{"version" => "1.0.0"})
      File.mkdir_p!(ext_dir)

      result = Loader.from_user(home)
      assert length(result.extensions) == 1
      ext = hd(result.extensions)
      assert ext.name == "user-ext"
      assert ext.version == "1.0.0"
    end

    test "returns empty when user home has no extensions", %{tmp: tmp} do
      home = Path.join(tmp, "fake_home_empty")
      File.mkdir_p!(Path.join(home, ".handbean/extensions"))

      result = Loader.from_user(home)
      assert result.extensions == []
    end
  end

  describe "from_explicit/1" do
    test "loads a single manifest file", %{tmp: tmp} do
      ext_dir = Path.join(tmp, "single-ext")
      write_manifest(ext_dir, "single-ext")

      result = Loader.from_explicit(ext_dir)
      assert length(result.extensions) == 1
      assert hd(result.extensions).name == "single-ext"
    end

    test "loads a directory containing multiple extension dirs", %{tmp: tmp} do
      parent = Path.join(tmp, "multi-ext")
      write_manifest(Path.join(parent, "ext-a"), "ext-a")
      write_manifest(Path.join(parent, "ext-b"), "ext-b")

      result = Loader.from_explicit(parent)
      assert length(result.extensions) == 2
      names = Enum.map(result.extensions, & &1.name) |> Enum.sort()
      assert names == ["ext-a", "ext-b"]
    end

    test "returns error for nonexistent directory" do
      result = Loader.from_explicit("/nonexistent/path/12345")
      assert result.extensions == []
      assert length(result.diagnostics) > 0
    end
  end

  describe "load/1 - combined" do
    test "project wins over user for duplicate names", %{tmp: tmp} do
      # User
      home = Path.join(tmp, "user_home")
      user_ext = Path.join(home, ".handbean/extensions/shared-ext")
      write_manifest(user_ext, "shared-ext", %{"version" => "0.1.0-user"})

      # Project
      proj_ext = Path.join(tmp, ".handbean/extensions/shared-ext")
      write_manifest(proj_ext, "shared-ext", %{"version" => "0.2.0-proj"})

      result = Loader.load(project: tmp, user_home: home)

      assert length(result.extensions) == 1
      ext = hd(result.extensions)
      assert ext.version == "0.2.0-proj"
    end

    test "user extensions loaded when no project overlap", %{tmp: tmp} do
      home = Path.join(tmp, "user_home")
      user_ext = Path.join(home, ".handbean/extensions/user-only")
      write_manifest(user_ext, "user-only")

      result = Loader.load(project: tmp, user_home: home)
      assert length(result.extensions) == 1
      assert hd(result.extensions).name == "user-only"
    end

    test "combines project and user extensions", %{tmp: tmp} do
      home = Path.join(tmp, "user_home")
      write_manifest(Path.join(home, ".handbean/extensions/ext-user"), "ext-user")
      write_manifest(Path.join(tmp, ".handbean/extensions/ext-proj"), "ext-proj")

      result = Loader.load(project: tmp, user_home: home)

      assert length(result.extensions) == 2
      names = Enum.map(result.extensions, & &1.name) |> Enum.sort()
      assert names == ["ext-proj", "ext-user"]
    end
  end
end
