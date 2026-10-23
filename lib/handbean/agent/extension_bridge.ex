defmodule Handbean.Agent.ExtensionBridge do
  @moduledoc """
  Bridges the Extension system into the Agent runtime.

  Responsibilities:
  - Loads extensions from filesystem (startup + hot reload)
  - Registers extension tool modules into Tool.Registry (override on reload)
  - Registers hook modules that export `handle_event/2`
  - Starts `child_spec/1` workers under `Handbean.Extension.Supervisor`
  - Validates that declared tools have corresponding compiled modules

  Extension tools must:
  1. Implement `Handbean.Agent.Tool` behaviour
  2. Come from the extension `entry` (`Code.compile_file/1`) or already be on the BEAM
  3. Use the naming convention `ext__<extension_name>__<tool_name>`
     as return value of `name/0`
  """

  use Agent

  require Logger

  alias Handbean.Extension.Capabilities
  alias Handbean.Extension.Registry, as: ExtRegistry
  alias Handbean.Extension.Diagnostic

  # ── Client API ──

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{loaded: []} end, name: name)
  end

  @doc """
  Load extensions from filesystem and integrate them into the runtime.

  Returns `{:ok, diagnostics}` where diagnostics are collected warnings/errors
  that don't prevent normal operation.
  """
  @spec load_and_integrate(keyword()) :: {:ok, [Diagnostic.t()]}
  def load_and_integrate(opts \\ []) do
    Handbean.Extension.HotReloader.reload(opts)
  end

  @doc "Prepare an extension without changing any runtime registry."
  @spec prepare(Handbean.Extension.t()) :: {:ok, map()} | {:error, [Diagnostic.t()]}
  def prepare(ext) do
    if ext.enabled do
      case compile_entry(ext) do
        {:error, diags} ->
          {:error, diags}

        {:ok, compiled_modules, compile_diagnostics} ->
          case declared_tool_modules(ext, compiled_modules) do
            {:ok, tool_modules, tool_diagnostics} ->
              with :ok <- validate_worker_modules(compiled_modules),
                   {:ok, capabilities} <- Capabilities.prepare(ext, compiled_modules) do
                {:ok,
                 %{
                   extension: ext,
                   modules: compiled_modules,
                   tool_modules: tool_modules,
                   hook_module: hook_module(ext, compiled_modules),
                   capabilities: capabilities,
                   diagnostics: compile_diagnostics ++ tool_diagnostics
                 }}
              else
                {:error, diags} ->
                  {:error, compile_diagnostics ++ tool_diagnostics ++ diags}
              end

            {:error, diags} ->
              {:error, compile_diagnostics ++ diags}
          end
      end
    else
      {:ok,
       %{
         extension: ext,
         modules: [],
         tool_modules: [],
         hook_module: nil,
         capabilities: %{commands: [], providers: []},
         diagnostics: []
       }}
    end
  end

  @doc "Commit a prepared extension's manifest and runtime resources."
  @spec commit_prepared(map(), keyword()) :: :ok | {:error, term()}
  def commit_prepared(%{extension: ext} = prepared, opts \\ []) do
    ext_registry = Keyword.get(opts, :ext_registry, ExtRegistry)
    owner = {:extension, ext.name}

    previous_tools = Handbean.Tool.Registry.owner_modules(owner)

    case Handbean.Extension.Supervisor.prepare_workers(owner, prepared.modules) do
      {:ok, worker_change} ->
        result =
          with :ok <- Handbean.Tool.Registry.replace_owner(owner, prepared.tool_modules),
               :ok <- commit_registry(ext_registry, ext, prepared) do
            Handbean.Extension.Supervisor.commit_workers(worker_change)
          end

        case result do
          :ok ->
            :ok

          {:error, _} = error ->
            Handbean.Extension.Supervisor.abort_workers(worker_change)
            rollback_tools(owner, previous_tools)
            error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Integrate a single extension's declared tools into Tool.Registry.

  Compile and validate first; a failed preparation leaves all previously
  committed tools, hooks, workers, and manifest state untouched.
  """
  @spec from_extension(Handbean.Extension.t()) :: {:ok, [Diagnostic.t()]}
  @spec from_extension(Handbean.Extension.t(), keyword()) :: {:ok, [Diagnostic.t()]}
  def from_extension(ext, opts \\ []) do
    case prepare(ext) do
      {:error, diags} ->
        {:ok, diags}

      {:ok, prepared} ->
        ext_registry = Keyword.get(opts, :ext_registry, ExtRegistry)

        case commit_prepared(prepared, ext_registry: ext_registry) do
          :ok -> {:ok, prepared.diagnostics}
          {:error, reason} -> {:ok, prepared.diagnostics ++ [commit_diagnostic(ext, reason)]}
        end
    end
  end

  @doc """
  Register a single extension tool module into Handbean.Tool.Registry.

  The module must implement `Handbean.Agent.Tool` behaviour and its `name/0`
  must return an `ext__...` prefixed name.
  """
  @spec register_extension_tool(module()) :: :ok | {:error, String.t()}
  @spec register_extension_tool(module(), keyword()) :: :ok | {:error, String.t()}
  def register_extension_tool(mod, opts \\ []) when is_atom(mod) do
    with :ok <- validate_extension_tool(mod) do
      Handbean.Tool.Registry.register(mod, opts)
    end
  end

  @doc "Validate an extension tool without registering it."
  @spec validate_extension_tool(module()) :: :ok | {:error, String.t()}
  def validate_extension_tool(mod) when is_atom(mod) do
    with {:ok} <- ensure_compiled(mod),
         :ok <- validate_tool_behaviour(mod) do
      validate_extension_name(mod)
    end
  end

  @doc """
  Register multiple extension tool modules.
  """
  @spec register_extension_tools([module()]) :: :ok | {:error, String.t()}
  def register_extension_tools(mods) when is_list(mods) do
    results = Enum.map(mods, &register_extension_tool/1)
    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      :ok
    else
      {:error, "Failed to register tools: #{inspect(errors)}"}
    end
  end

  # ── Private ──

  defp ensure_compiled(mod) do
    case Code.ensure_compiled(mod) do
      {:module, ^mod} -> {:ok}
      {:error, reason} -> {:error, "Module #{inspect(mod)} is not compiled: #{inspect(reason)}"}
    end
  end

  defp validate_tool_behaviour(mod) do
    # An extension tool must implement all callbacks of Handbean.Agent.Tool
    required_callbacks = [
      {:name, 0},
      {:description, 0},
      {:input_schema, 0},
      {:execute, 2}
    ]

    missing =
      Enum.reject(required_callbacks, fn {func, arity} ->
        function_exported?(mod, func, arity)
      end)

    if missing == [] do
      :ok
    else
      {:error, "Module #{inspect(mod)} missing required callbacks: #{inspect(missing)}"}
    end
  end

  defp validate_extension_name(mod) do
    name = mod.name()

    if String.starts_with?(name, "ext__") do
      :ok
    else
      {:error, "Extension tool name must start with 'ext__', got: #{name}"}
    end
  end

  defp declared_tool_modules(ext, compiled_modules) do
    Enum.reduce_while(ext.tools, {:ok, [], []}, fn tool_decl, {:ok, modules, diags} ->
      tool_name = Handbean.Utils.SafeMap.get_any(tool_decl, ["name", :name])
      expected_name = "ext__#{ext.name}__#{tool_name}"

      case find_tool_module(expected_name, compiled_modules) do
        {:ok, mod} ->
          case validate_extension_tool(mod) do
            :ok ->
              {:cont, {:ok, [mod | modules], diags}}

            {:error, reason} ->
              {:halt,
               {:error,
                [
                  %Diagnostic{
                    type: :warning,
                    message: "Invalid extension tool #{expected_name}: #{reason}"
                  }
                ]}}
          end

        {:error, :not_found} ->
          Logger.debug(
            "[ExtensionBridge] No module found for #{expected_name} (tool may be lazy-loaded)"
          )

          {:cont, {:ok, modules, diags}}
      end
    end)
    |> case do
      {:ok, modules, diags} -> {:ok, Enum.reverse(modules), diags}
      {:error, diags} -> {:error, diags}
    end
  end

  defp validate_worker_modules(modules) do
    modules
    |> Enum.filter(&function_exported?(&1, :child_spec, 1))
    |> Enum.reduce_while(:ok, fn mod, :ok ->
      try do
        _spec = Supervisor.child_spec(mod.child_spec([]), restart: :permanent)
        {:cont, :ok}
      rescue
        exception ->
          {:halt,
           {:error,
            [
              %Diagnostic{
                type: :warning,
                message:
                  "Invalid extension worker #{inspect(mod)}: #{Exception.message(exception)}"
              }
            ]}}
      end
    end)
  end

  defp hook_module(%{hooks: []}, _compiled_modules), do: nil

  defp hook_module(_ext, compiled_modules) do
    Enum.find(compiled_modules, &function_exported?(&1, :handle_event, 2))
  end

  defp commit_diagnostic(ext, reason) do
    %Diagnostic{
      type: :warning,
      message: "Failed to commit extension #{ext.name}: #{inspect(reason)}"
    }
  end

  defp commit_registry(ext_registry, ext, prepared) do
    ExtRegistry.commit(ext_registry, ext, prepared.hook_module, prepared.capabilities)
  catch
    :exit, reason -> {:error, {:registry_commit_failed, reason}}
  end

  defp rollback_tools(owner, previous_tools) do
    case Handbean.Tool.Registry.replace_owner(owner, previous_tools) do
      :ok ->
        :ok

      error ->
        Logger.error(
          "[ExtensionBridge] tool rollback failed owner=#{inspect(owner)} result=#{inspect(error)}"
        )

        :ok
    end
  end

  defp compile_entry(%{commands: commands, providers: providers} = ext)
       when commands != [] or providers != [] do
    Capabilities.compile(ext)
  end

  defp compile_entry(%{entry: entry}) when is_binary(entry) do
    if File.exists?(entry) do
      case Code.compile_file(entry) do
        modules when is_list(modules) ->
          {:ok, Enum.map(modules, &elem(&1, 0)), []}

        _other ->
          {:error,
           [
             %Diagnostic{
               type: :warning,
               message: "Failed to compile extension entry #{entry}"
             }
           ]}
      end
    else
      {:error,
       [
         %Diagnostic{
           type: :warning,
           message: "Extension entry does not exist: #{entry}"
         }
       ]}
    end
  rescue
    e ->
      {:error,
       [
         %Diagnostic{
           type: :warning,
           message: "Failed to compile extension entry #{entry}: #{Exception.message(e)}"
         }
       ]}
  end

  defp compile_entry(_ext), do: {:ok, [], []}

  defp find_tool_module(expected_name, compiled_modules) do
    compiled =
      Enum.find(compiled_modules, fn mod ->
        function_exported?(mod, :name, 0) and mod.name() == expected_name
      end)

    if compiled do
      {:ok, compiled}
    else
      find_compiled_tool_module(expected_name)
    end
  end

  defp find_compiled_tool_module(expected_name) do
    # In Elixir, we can't dynamically discover modules by naming convention.
    # Instead, extension tools must be explicitly provided via:
    # 1. The extension's `entry` pointing to a module that exports `tool_modules/0`
    # 2. Or registered programmatically by the caller
    #
    # For now, try to resolve via Code.ensure_compiled? with underscore-based naming
    # E.g. ext__beam__eval -> Elixir.Ext.Beam.Eval
    module_name = name_to_module(expected_name)

    case Code.ensure_compiled(module_name) do
      {:module, mod} ->
        if function_exported?(mod, :name, 0) and function_exported?(mod, :execute, 2) do
          {:ok, mod}
        else
          {:error, :not_found}
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  defp name_to_module("ext__" <> rest) do
    parts = String.split(rest, "__")
    module_name = Enum.map_join(parts, ".", &Macro.camelize/1)
    Module.concat(["Elixir", module_name])
  end
end
