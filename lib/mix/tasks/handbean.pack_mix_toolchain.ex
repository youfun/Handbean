defmodule Mix.Tasks.Handbean.PackMixToolchain do
  @shortdoc "Copy Mix/ExUnit/Hex beams into priv/mix_toolchain"
  @moduledoc """
  Packages the host Mix, ExUnit and Hex #{Handbean.Workspace.MixToolchain.hex_version()}
  ebin trees into `priv/mix_toolchain` so mobile builds can load them without
  an RPC upload. Hex.HTTP.beam is omitted; mobile uses Handbean.Workspace.HexHttp.
  """

  use Mix.Task

  alias Handbean.Workspace.MixToolchain

  @impl Mix.Task
  def run(_args) do
    app = Mix.Project.deps_paths()[:handbean] || File.cwd!()
    dest = Path.join(app, "priv/mix_toolchain")
    Mix.shell().info("Packing Mix toolchain into #{dest}")
    MixToolchain.sync_to!(dest)

    mobile = Path.join(app, "mobile/priv/mix_toolchain")

    if File.dir?(Path.dirname(mobile)) do
      File.rm_rf!(mobile)
      File.cp_r!(dest, mobile)
      Mix.shell().info("Copied Mix toolchain into #{mobile}")
    end

    :ok
  end
end
