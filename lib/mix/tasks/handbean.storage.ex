defmodule Mix.Tasks.Handbean.Storage do
  use Mix.Task

  @shortdoc "Run SQLite diagnostics or create a verified online backup"

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [backup: :string])

    if rest != [] or invalid != [],
      do: Mix.raise("Usage: mix handbean.storage [--backup PATH]")

    Mix.Task.run("app.start")

    result =
      case opts[:backup] do
        nil -> Handbean.Storage.Diagnostics.check()
        path -> Handbean.Storage.Diagnostics.backup(path)
      end

    case result do
      {:ok, report} -> Mix.shell().info(Handbean.JSON.encode!(report, pretty: true))
      {:error, reason} -> Mix.raise("storage operation failed: #{inspect(reason)}")
    end
  end
end
