defmodule Mix.Tasks.Handbean.InspectConfig do
  use Mix.Task

  @shortdoc "Print a redacted, read-only host/configuration report (does not start Handbean)"
  @moduledoc """
  Usage: `mix handbean.inspect_config [--workspace PATH]`.

  Loads Mix configuration and compiled modules, but does not start Handbean,
  initialize stores or bootstrap MCP. This inspects this Mix VM, not a running
  native host. In a running host call `Handbean.ConfigInspection.report/1`.
  """
  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [workspace: :string])

    if rest != [] or invalid != [],
      do: Mix.raise("Usage: mix handbean.inspect_config [--workspace PATH]")

    Mix.Task.run("loadpaths")
    Mix.Task.run("compile")
    Mix.Task.run("app.config")
    Mix.shell().info(Handbean.JSON.encode!(Handbean.ConfigInspection.report(opts), pretty: true))
  end
end
