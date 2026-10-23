defmodule Handbean.Extension.Capabilities do
  @moduledoc false

  alias Handbean.Extension.{Command, Diagnostic, Provider}

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

  # Capability source is trusted code, but generation isolation only supports
  # literal top-level module definitions. Arbitrary compile-time side effects
  # remain the responsibility of the trusted author.
  def compile(ext) do
    with :ok <- Handbean.Security.PathValidator.validate_under_root(ext.entry, ext.root),
         {:ok, source} <- File.read(ext.entry),
         {:ok, ast} <- Code.string_to_quoted(source, file: ext.entry),
         {:ok, declarations} <- module_declarations(ast) do
      digest = :crypto.hash(:sha256, ext.root <> source) |> Base.encode16()
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
    else
      {:error, reason} -> error("Cannot compile extension capabilities: #{inspect(reason)}")
    end
  rescue
    exception -> error(Exception.message(exception))
  catch
    kind, _reason -> error("Extension compilation failed: #{kind}")
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

    if valid? and declarations != [] and top_level? and unique?,
      do: {:ok, declarations},
      else: {:error, :expected_literal_top_level_modules}
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
