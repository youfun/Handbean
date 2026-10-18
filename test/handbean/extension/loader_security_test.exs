defmodule Handbean.Extension.LoaderSecurityTest do
  use ExUnit.Case, async: false

  alias Handbean.Extension.Loader

  # 1 MiB
  @max_manifest_size 1_048_576

  setup do
    fixtures = System.tmp_dir!() |> Path.join("loader_sec_#{System.unique_integer([:positive])}")
    File.mkdir_p!(fixtures)
    on_exit(fn -> File.rm_rf!(fixtures) end)
    %{fixtures: fixtures}
  end

  describe "from_explicit — security" do
    test "does not follow symlinks to external directories", %{fixtures: fixtures} do
      # Symlink: <fixtures>/evil-link/evil -> /tmp
      link_dir = Path.join(fixtures, "evil-link")
      File.mkdir_p!(link_dir)
      File.write!(Path.join(link_dir, "manifest.json"), ~s({"name": "evil-link"}))
      File.ln_s!("/tmp", Path.join(link_dir, "evil"))

      result = Loader.from_explicit(fixtures)

      # Should find evil-link's own manifest, but NOT traverse the linked target.
      assert Enum.map(result.extensions, & &1.name) == ["evil-link"]
    end

    test "does not infinite-loop on symlink cycles", %{fixtures: fixtures} do
      # a -> b -> a  (both are extension dirs with manifests)
      dir_a = Path.join(fixtures, "cycle_a")
      dir_b = Path.join(fixtures, "cycle_b")
      File.mkdir_p!(dir_a)
      File.mkdir_p!(dir_b)
      File.ln_s!(dir_b, Path.join(dir_a, "to_b"))
      File.ln_s!(dir_a, Path.join(dir_b, "to_a"))
      File.write!(Path.join(dir_a, "manifest.json"), ~s({"name": "cycle-a"}))
      File.write!(Path.join(dir_b, "manifest.json"), ~s({"name": "cycle-b"}))

      # Should complete without stack overflow; both dirs found once
      result = Loader.from_explicit(fixtures)
      names = Enum.map(result.extensions, & &1.name)
      assert "cycle-a" in names
      assert "cycle-b" in names
      assert length(names) == 2
    end

    test "rejects manifest larger than 1 MiB before parsing", %{fixtures: fixtures} do
      dir = Path.join(fixtures, "huge-ext")
      File.mkdir_p!(dir)

      big = String.duplicate("x", @max_manifest_size + 1)
      File.write!(Path.join(dir, "manifest.json"), big)

      result = Loader.from_explicit(fixtures)

      # Must not OOM: no extensions loaded, diagnostic produced
      assert length(result.extensions) == 0

      assert Enum.any?(result.diagnostics, fn d ->
               String.contains?(d.message, "too large") or String.contains?(d.message, "size")
             end)
    end

    test "accepts manifest well under 1 MiB", %{fixtures: fixtures} do
      dir = Path.join(fixtures, "small-ext")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "manifest.json"), ~s({"name": "small-ext"}))

      result = Loader.from_explicit(fixtures)
      assert length(result.extensions) == 1
      assert hd(result.extensions).name == "small-ext"
    end
  end
end
