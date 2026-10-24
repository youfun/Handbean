defmodule Handbean.Extension.Capabilities do
  @moduledoc false

  alias Handbean.Extension.{Command, Diagnostic, Provider}

  # Dynamic module atoms live for the lifetime of the VM. Keep the development
  # allowance generous, but place per-root and VM-wide ceilings on distinct
  # entry revisions. The budget itself uses binary map keys
  # and is persisted for the VM lifetime so process or supervisor restarts
  # cannot reset it while generated atoms remain allocated.
  @max_source_bytes 1_048_576
  @max_static_atoms_per_generation 256
  @max_modules_per_generation 64
  @max_generations_per_root 256
  @max_generation_atoms_total 50_000
  @minimum_atom_headroom 100_000
  @generation_budget_key {__MODULE__, :generation_budget}

  def prepare(ext, modules) do
    with {:ok, commands} <- declarations(ext, ext.commands, modules, Command, :commands),
         {:ok, providers} <- declarations(ext, ext.providers, modules, Provider, :providers) do
      {:ok, %{commands: commands, providers: providers}}
    end
  rescue
    exception -> error(Exception.message(exception))
  catch
    kind, reason -> error("#{kind}: #{inspect(reason)}")
  end

  @doc false
  def generation_limit, do: @max_generations_per_root

  @doc false
  def generation_atom_budget, do: @max_generation_atoms_total

  @doc false
  def reserve_generation(root, digest, atom_cost \\ 1)
      when is_binary(root) and is_binary(digest) and is_integer(atom_cost) and atom_cost > 0 do
    case :global.trans({@generation_budget_key, self()}, fn ->
           budgets = :persistent_term.get(@generation_budget_key, %{})
           generations = Map.get(budgets, root, %{})
           total_atom_cost = generation_atom_cost(budgets)

           cond do
             Map.has_key?(generations, digest) ->
               :ok

             map_size(generations) >= @max_generations_per_root ->
               {:error, :generation_limit}

             total_atom_cost + atom_cost > @max_generation_atoms_total ->
               {:error, :global_atom_budget}

             not atom_headroom_available?(atom_cost) ->
               {:error, :global_atom_budget}

             true ->
               updated = Map.put(budgets, root, Map.put(generations, digest, atom_cost))
               :persistent_term.put(@generation_budget_key, updated)
               :ok
           end
         end) do
      :aborted -> {:error, :generation_budget_unavailable}
      result -> result
    end
  end

  defp generation_atom_cost(budgets) do
    Enum.reduce(budgets, 0, fn {_root, entries}, total ->
      Enum.reduce(entries, total, fn
        {_digest, cost}, subtotal when is_integer(cost) -> subtotal + cost
        {_digest, _legacy_reservation}, subtotal -> subtotal + 1
      end)
    end)
  end

  defp atom_headroom_available?(atom_cost) do
    :erlang.system_info(:atom_count) + atom_cost + @minimum_atom_headroom <=
      :erlang.system_info(:atom_limit)
  end

  # Extension source is trusted code, but generation isolation only supports
  # literal top-level module definitions. Content-addressed namespaces reuse a
  # generation for identical source instead of creating fresh module atoms on
  # every scan. Arbitrary compile-time side effects remain the responsibility
  # of the trusted author.
  def compile(ext) do
    with :ok <- Handbean.Security.PathValidator.validate_under_root(ext.entry, ext.root),
         {:ok, root} <- Handbean.Security.PathValidator.canonicalize(ext.root),
         {:ok, source} <- read_source(ext.entry),
         digest = :crypto.hash(:sha256, root <> source) |> Base.encode16(),
         {:ok, atom_cost} <- validate_static_atom_budget(source, ext.entry),
         :ok <- reserve_generation(root, digest, atom_cost),
         {:ok, ast} <- Code.string_to_quoted(source, file: ext.entry),
         {:ok, declarations} <- module_declarations(ast) do
      compile_generation(ext, digest, declarations)
    else
      {:error, :generation_limit} -> generation_limit_error(ext)
      {:error, :global_atom_budget} -> global_generation_limit_error()
      {:error, :source_too_large} -> source_limit_error(ext)
      {:error, :static_atom_limit} -> static_atom_limit_error(ext)
      {:error, :too_many_modules} -> module_limit_error(ext)
      {:error, reason} -> error("Cannot compile extension capabilities: #{inspect(reason)}")
    end
  rescue
    exception -> error(Exception.message(exception))
  catch
    kind, _reason -> error("Extension compilation failed: #{kind}")
  end

  defp read_source(path) do
    with {:ok, %{type: :regular, size: size}} when size <= @max_source_bytes <- File.stat(path),
         {:ok, source} <- File.read(path) do
      {:ok, source}
    else
      {:ok, %{type: :regular}} -> {:error, :source_too_large}
      {:ok, _other} -> {:error, :invalid_source_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_static_atom_budget(source, file) do
    key = {__MODULE__, :static_atoms, make_ref()}

    encoder = fn name, _meta ->
      try do
        {:ok, String.to_existing_atom(name)}
      rescue
        ArgumentError ->
          Process.put(key, MapSet.put(Process.get(key, MapSet.new()), name))
          {:ok, :__handbean_extension_static_atom__}
      end
    end

    try do
      case Code.string_to_quoted(source, file: file, static_atoms_encoder: encoder) do
        {:ok, ast} ->
          static_atoms = MapSet.size(Process.get(key, MapSet.new()))
          module_atoms = count_module_declarations(ast)

          cond do
            static_atoms > @max_static_atoms_per_generation ->
              {:error, :static_atom_limit}

            module_atoms > @max_modules_per_generation ->
              {:error, :too_many_modules}

            true ->
              case validate_safe_module_shape(ast) do
                :ok -> {:ok, static_atoms + module_atoms + 1}
                {:error, _reason} = error -> error
              end
          end

        {:error, reason} ->
          {:error, reason}
      end
    after
      Process.delete(key)
    end
  end

  defp count_module_declarations(ast) do
    {_ast, count} =
      Macro.prewalk(ast, 0, fn
        {:defmodule, _meta, _args} = node, count -> {node, count + 1}
        node, count -> {node, count}
      end)

    count
  end

  defp validate_safe_module_shape(ast) do
    declarations =
      case ast do
        {:__block__, _, expressions} -> expressions
        expression -> [expression]
      end

    valid? =
      declarations != [] and
        Enum.all?(declarations, fn
          {:defmodule, _, [{:__aliases__, _, [first_segment | _]}, [do: body]]}
          when first_segment != Elixir ->
            not contains_module_declaration?(body)

          _other ->
            false
        end)

    if valid?, do: :ok, else: {:error, :expected_literal_top_level_modules}
  end

  defp contains_module_declaration?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:defmodule, _, _} = node, _found? -> {node, true}
        node, found? -> {node, found?}
      end)

    found?
  end

  defp compile_generation(ext, digest, declarations) do
    namespace = Module.concat(Handbean.Extension.Generated, "V" <> digest)

    if Code.ensure_loaded?(namespace) do
      {:ok, namespace.__extension_modules__(), []}
    else
      names = Enum.map(declarations, fn {:defmodule, _, [name, _]} -> name end)

      wrapped =
        quote do
          defmodule unquote(namespace) do
            unquote_splicing(declarations)
            def __extension_modules__, do: unquote(names)
          end
        end

      compiled = Code.compile_quoted(wrapped, ext.entry)
      modules = namespace.__extension_modules__()
      actual = MapSet.new(compiled, &elem(&1, 0))

      if actual == MapSet.new([namespace | modules]) do
        {:ok, modules, []}
      else
        :code.delete(namespace)
        error("Unexpected modules emitted by extension entry")
      end
    end
  end

  defp generation_limit_error(ext) do
    error(
      "Extension generation limit of #{@max_generations_per_root} source revisions reached for " <>
        "#{ext.name}; restart Handbean before loading another source revision"
    )
  end

  defp global_generation_limit_error do
    error(
      "Global extension atom budget of #{@max_generation_atoms_total} reached; " <>
        "restart Handbean before loading another source revision"
    )
  end

  defp source_limit_error(ext) do
    error("Extension #{ext.name} source exceeds #{@max_source_bytes} bytes")
  end

  defp static_atom_limit_error(ext) do
    error(
      "Extension #{ext.name} declares more than #{@max_static_atoms_per_generation} static identifiers"
    )
  end

  defp module_limit_error(ext) do
    error("Extension #{ext.name} declares more than #{@max_modules_per_generation} modules")
  end

  defp module_declarations({:__block__, _, declarations}), do: validate_modules(declarations)
  defp module_declarations(declaration), do: validate_modules([declaration])

  defp validate_modules(declarations) do
    valid? =
      Enum.all?(declarations, fn
        {:defmodule, _, [{:__aliases__, _, [first | _]}, _]} when first != Elixir -> true
        _ -> false
      end)

    top_level? =
      valid? and
        Enum.all?(declarations, fn {:defmodule, _, [_name, body]} ->
          {_ast, nested?} =
            Macro.prewalk(body, false, fn
              {:defmodule, _, _} = node, _ -> {node, true}
              node, found? -> {node, found?}
            end)

          not nested?
        end)

    names = for {:defmodule, _, [{:__aliases__, _, parts}, _]} <- declarations, do: parts
    unique? = length(Enum.uniq(names)) == length(declarations)

    cond do
      length(declarations) > @max_modules_per_generation ->
        {:error, :too_many_modules}

      valid? and declarations != [] and top_level? and unique? ->
        {:ok, declarations}

      true ->
        {:error, :expected_literal_top_level_modules}
    end
  end

  defp declarations(ext, declarations, modules, behaviour, kind) do
    Enum.reduce_while(declarations, {:ok, []}, fn declaration, {:ok, acc} ->
      with {:ok, metadata} <- metadata(ext.name, declaration, kind),
           :ok <- validate_description(declaration["description"]),
           full_name = metadata.name,
           false <- Enum.any?(acc, &(&1.name == full_name)),
           [module] <- Enum.filter(modules, &implements?(&1, behaviour, full_name)),
           :ok <- validate_provider_models(declaration, kind) do
        spec = %{
          name: full_name,
          module: module,
          revision:
            :crypto.hash(:sha256, :erlang.term_to_binary({module, declaration}))
            |> Base.encode16(),
          declaration: declaration,
          description: declaration["description"] || "",
          extension: ext.name,
          scope: ext.scope
        }

        {:cont, {:ok, [spec | acc]}}
      else
        _ ->
          {:halt, error("Invalid, duplicate, or missing #{kind} implementation in #{ext.name}")}
      end
    end)
  end

  defp metadata(extension, %{"name" => name} = declaration, :commands),
    do: Handbean.Extension.CommandSpec.new(extension, name, declaration)

  defp metadata(extension, %{"name" => name} = declaration, :providers),
    do: Handbean.Extension.ProviderSpec.new(extension, name, declaration)

  defp metadata(_, _, _), do: :error

  defp implements?(module, behaviour, name) do
    behaviours =
      module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    callbacks = if behaviour == Command, do: [name: 0, execute: 2], else: [name: 0, complete: 3]

    behaviour in behaviours and
      Enum.all?(callbacks, fn {fun, arity} -> function_exported?(module, fun, arity) end) and
      module.name() == name
  end

  defp validate_description(value) when is_binary(value) or is_nil(value), do: :ok
  defp validate_description(_), do: :error

  defp validate_provider_models(_declaration, :commands), do: :ok

  defp validate_provider_models(%{"models" => models}, :providers) when is_list(models) do
    ids = Enum.map(models, fn model -> if is_map(model), do: model["id"] end)
    valid? = Enum.all?(models, &valid_model?/1)
    if valid? and length(Enum.uniq(ids)) == length(ids), do: :ok, else: :error
  end

  defp validate_provider_models(_, :providers), do: :error

  defp valid_model?(%{"id" => id} = model) when is_binary(id) and id != "" do
    String.valid?(id) and is_boolean(Map.get(model, "enabled", true)) and
      Enum.all?(["name", "defaultReasoning"], &(is_nil(model[&1]) or is_binary(model[&1]))) and
      Enum.all?(["contextWindow", "maxTokens"], fn key ->
        is_nil(model[key]) or (is_integer(model[key]) and model[key] > 0)
      end) and
      Enum.all?(["input", "reasoningLevels"], fn key ->
        is_nil(model[key]) or (is_list(model[key]) and Enum.all?(model[key], &is_binary/1))
      end) and
      Enum.all?(["cost", "thinkingLevelMap"], &(is_nil(model[&1]) or is_map(model[&1])))
  end

  defp valid_model?(_), do: false

  defp error(message), do: {:error, [%Diagnostic{type: :validation_error, message: message}]}
end
