defmodule HandbeanWeb.AssetsTest do
  use ExUnit.Case, async: true

  for {mode, flags} <- [{:development, []}, {:production, ["--minify"]}] do
    test "#{mode} build generates every asset referenced by the root layout" do
      output =
        Path.join(System.tmp_dir!(), "handbean-assets-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(output) end)

      assert Esbuild.run(:handbean, unquote(flags) ++ ["--outdir=#{output}"]) == 0

      layout = File.read!("lib/handbean_web/components/layouts/root.html.heex")

      paths =
        Regex.scan(~r{~p"/assets/([^"]+)"}, layout, capture: :all_but_first)
        |> List.flatten()

      assert "css/workspace.css" in paths
      assert "default.css" in paths
      assert "js/app.js" in paths

      for path <- paths do
        assert File.stat!(Path.join(output, path)).size > 0
      end
    end
  end
end
