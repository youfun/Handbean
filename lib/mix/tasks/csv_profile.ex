defmodule Mix.Tasks.CsvProfile do
  @moduledoc "Analyze a CSV file and print a profiling report."

  use Mix.Task

  alias Handbean.CsvProfile.{Analyzer, Error, Format}

  @shortdoc "Profile a CSV file"

  @impl true
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, switches: [json: :boolean], strict: [json: :boolean])

    case {invalid, positional} do
      {[], [path]} -> execute(path, opts)
      _ -> Mix.raise("usage: mix csv_profile path/to/file.csv [--json]")
    end
  end

  defp execute(path, opts) do
    case Analyzer.analyze(path) do
      {:ok, report} ->
        output = if opts[:json], do: Format.json(report), else: Format.text(report)
        Mix.shell().info(output)

      {:error, %Error{} = error} ->
        Mix.shell().error(format_error(error))
        System.halt(1)
    end
  end

  defp format_error(%Error{code: code, message: message, path: path}) do
    base = %{error: Atom.to_string(code), message: message}
    base = if path, do: Map.put(base, :path, path), else: base
    Handbean.JSON.encode!(base)
  end
end
