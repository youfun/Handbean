defmodule Handbean.Tool.Extension.Beam.Schemas do
  @moduledoc """
  List all Ecto schema modules with file paths.

  Scans compiled modules for Ecto schema markers (__schema__/1 export).
  Prefer over grep for schema discovery.
  """

  @behaviour Handbean.Agent.Tool

  @impl true
  def name, do: "ext__beam__schemas"

  @impl true
  def description do
    "List all Ecto schema modules with file paths. " <>
      "Prefer over grep for schema discovery."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{},
      required: []
    }
  end

  @impl true
  def execute(_input, _context) do
    schemas = discover_schemas()

    output =
      if schemas == [] do
        "No Ecto schemas found in loaded applications."
      else
        [
          "# Ecto Schemas (#{length(schemas)})",
          "",
          Enum.map_join(schemas, "\n", fn {mod, source} ->
            "#{inspect(mod)}  →  #{source || "unknown"}"
          end)
        ]
        |> Enum.join("\n")
      end

    {:ok, output}
  end

  defp discover_schemas do
    # Get all loaded modules from application controller
    apps = Application.loaded_applications()

    app_modules =
      Enum.flat_map(apps, fn {app, _, _} ->
        case Application.spec(app, :modules) do
          mods when is_list(mods) -> mods
          _ -> []
        end
      end)

    app_modules
    |> Enum.uniq()
    |> Enum.filter(&ecto_schema?/1)
    |> Enum.map(fn mod -> {mod, find_source(mod)} end)
    |> Enum.sort_by(fn {mod, _} -> inspect(mod) end)
  end

  defp ecto_schema?(mod) do
    match?({:module, _}, Code.ensure_compiled(mod)) and function_exported?(mod, :__schema__, 1)
  end

  defp find_source(mod) do
    beam = :code.which(mod)

    case :beam_lib.chunks(beam, [:debug_info]) do
      {:ok, {_, [{:debug_info, info}]}} ->
        case info do
          {:debug_info_v1, :elixir_erl, {:elixir_v1, map, _}} -> Map.get(map, :file)
          _ -> beam_to_lib(beam)
        end

      _ ->
        beam_to_lib(beam)
    end
  end

  defp beam_to_lib(path) when is_list(path) do
    path |> List.to_string() |> String.replace(~r{/ebin/[^/]+\.beam$}, "/lib")
  end

  defp beam_to_lib(_), do: nil
end
