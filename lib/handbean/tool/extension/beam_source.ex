defmodule Handbean.Tool.Extension.Beam.Source do
  @moduledoc """
  Get source file:line for a module or function from the BEAM.

  Uses `:beam_lib.chunks/2` to extract location info from compiled bytecode.
  Works with both `:elixir_v1` and `:elixir_erl` debug info backends.

  Accepts: Module, Module.function, Module.function/arity.
  """

  @behaviour Handbean.Agent.Tool

  @impl true
  def name, do: "ext__beam__source"

  @impl true
  def description do
    "Get source file:line for a module or function. " <>
      "The BEAM knows where everything is defined. " <>
      "Accepts: Module, Module.function, Module.function/arity."
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        reference: %{
          type: "string",
          description: "e.g. Enum, Enum.map, Enum.map/2"
        }
      },
      required: ["reference"]
    }
  end

  @impl true
  def execute(%{"reference" => ref}, _context) do
    case resolve_reference(ref) do
      {:module, mod} ->
        get_module_source(mod)

      {:function, mod, func, arity} ->
        get_function_source(mod, func, arity)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(_input, _context) do
    {:error, "reference is required"}
  end

  # ── Reference parsing ──

  defp resolve_reference(ref) when is_binary(ref) do
    ref = String.trim(ref)

    cond do
      String.match?(ref, ~r/^[A-Z][\w.]*\.[a-z_][a-zA-Z0-9_!?]*\/\d+$/) ->
        {mod_str, func_arity} = split_module_and_rest(ref)
        [func_str, arity_str] = String.split(func_arity, "/", parts: 2)

        with {:ok, mod} <- module_from_string(mod_str),
             {:ok, _} <- ensure_module(mod),
             {:ok, func} <- function_from_string(func_str),
             {:ok, arity} <- arity_from_string(arity_str) do
          {:function, mod, func, arity}
        end

      String.match?(ref, ~r/^[A-Z][\w.]*\.[a-z_][a-zA-Z0-9_!?]*$/) ->
        {mod_str, func_str} = split_module_and_rest(ref)

        with {:ok, mod} <- module_from_string(mod_str),
             {:ok, _} <- ensure_module(mod),
             {:ok, func} <- function_from_string(func_str) do
          {:function, mod, func, nil}
        end

      String.match?(ref, ~r/^[A-Z][\w.]*$/) ->
        with {:ok, mod} <- module_from_string(ref),
             {:ok, _} <- ensure_module(mod) do
          {:module, mod}
        end

      true ->
        {:error,
         "Cannot parse reference: #{ref}. Use Module, Module.function, or Module.function/arity."}
    end
  end

  defp resolve_reference(_ref) do
    {:error, "reference must be a string"}
  end

  defp split_module_and_rest(ref) do
    {rest, [func]} = Enum.split(String.split(ref, "."), -1)
    {Enum.join(rest, "."), func}
  end

  defp module_from_string(str) do
    if valid_module_name?(str) do
      {:ok, Module.concat(["Elixir" | String.split(str, ".")])}
    else
      {:error, "Module #{str} not found"}
    end
  end

  defp valid_module_name?(str) do
    String.match?(str, ~r/^[A-Z][A-Za-z0-9]*(\.[A-Z][A-Za-z0-9]*)*$/)
  end

  defp function_from_string(str) do
    case :erlang.binary_to_existing_atom(str, :utf8) do
      func when is_atom(func) -> {:ok, func}
    end
  catch
    :error, :badarg -> {:error, "Function #{str} not found"}
  end

  defp arity_from_string(str) do
    case Integer.parse(str) do
      {arity, ""} when arity >= 0 -> {:ok, arity}
      _ -> {:error, "Invalid arity: #{str}"}
    end
  end

  defp ensure_module(mod) do
    case Code.ensure_compiled(mod) do
      {:module, mod} -> {:ok, mod}
      {:error, _} -> {:error, "Module #{inspect(mod)} not found or not compiled"}
    end
  end

  # ── Source lookup ──

  defp get_module_source(mod) do
    beam_path = :code.which(mod)

    case extract_debug_info(beam_path, mod) do
      {:ok, file, _line_map} ->
        {:ok, "#{inspect(mod)}\n  Source: #{file}"}

      :error ->
        {:ok, "#{inspect(mod)}\n  BEAM: #{beam_path}\n  (source file could not be determined)"}
    end
  end

  defp get_function_source(mod, func, nil) do
    beam_path = :code.which(mod)

    case extract_debug_info(beam_path, mod) do
      {:ok, file, line_map} ->
        matches =
          line_map
          |> Enum.filter(fn {{name, _arity}, _line} -> name == func end)
          |> Enum.sort_by(fn {{_name, arity}, _line} -> arity end)

        lines =
          case matches do
            [] ->
              ["  (no matching function in debug info)"]

            matches ->
              Enum.map(matches, fn {{name, arity}, line} ->
                "  #{name}/#{arity}  #{file}:#{line}"
              end)
          end

        {:ok, Enum.join(["#{inspect(mod)}.#{func}", "  Source: #{file}" | lines], "\n")}

      :error ->
        {:ok,
         "#{inspect(mod)}.#{func}\n  BEAM: #{beam_path}\n  (source info could not be determined)"}
    end
  end

  defp get_function_source(mod, func, arity) do
    beam_path = :code.which(mod)

    case extract_debug_info(beam_path, mod) do
      {:ok, file, line_map} ->
        case Map.get(line_map, {func, arity}) do
          nil ->
            {:ok, "#{inspect(mod)}.#{func}/#{arity}\n  Source: #{file}\n  (exact line unknown)"}

          line ->
            {:ok, "#{inspect(mod)}.#{func}/#{arity}\n  Source: #{file}:#{line}"}
        end

      :error ->
        {:ok,
         "#{inspect(mod)}.#{func}/#{arity}\n  BEAM: #{beam_path}\n  (source info could not be determined)"}
    end
  end

  # ── Debug info extraction ──

  defp extract_debug_info(beam_path, mod) do
    case :beam_lib.chunks(beam_path, [:debug_info]) do
      {:ok, {^mod, [{:debug_info, info}]}} ->
        parse_debug_info(info)

      _ ->
        :error
    end
  end

  defp parse_debug_info({:debug_info_v1, :elixir_erl, {:elixir_v1, map, _specs}}) do
    parse_elixir_v1_map(map)
  end

  defp parse_debug_info({:debug_info_v1, :elixir_erl, metadata}) when is_tuple(metadata) do
    parse_elixir_erl_tuple(metadata)
  end

  defp parse_debug_info(_), do: :error

  # Elixir v1 format: %{file: path, definitions: [{...}, ...]}
  defp parse_elixir_v1_map(metadata) when is_map(metadata) do
    file = Map.get(metadata, :file)

    lines =
      metadata
      |> Map.get(:definitions, [])
      |> Enum.reduce(%{}, fn
        {{func, arity}, _kind, meta, _clauses}, acc ->
          line = Keyword.get(meta, :line, 0)
          Map.put(acc, {func, arity}, line)

        _, acc ->
          acc
      end)

    {:ok, file, lines}
  end

  # Elixir erl format: {module, specs, attrs, opts, deprecations}
  defp parse_elixir_erl_tuple(metadata) do
    {_module, _specs, _attrs, _opts, _deprecations} = metadata
    {:ok, "unknown", %{}}
  end
end
