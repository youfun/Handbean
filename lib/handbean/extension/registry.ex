defmodule Handbean.Extension.Registry do
  @moduledoc """
  Extension Registry — manages registered extensions.

  Not connected to Handbean.Tool.Registry. Standalone Agent-based registry.
  """

  use Agent

  alias Handbean.Extension.Diagnostic

  def start_link(opts \\ []) do
    name = Keyword.fetch!(opts, :name)
    Agent.start_link(fn -> %{extensions: %{}, hook_modules: %{}} end, name: name)
  end

  @spec register(atom() | pid(), Handbean.Extension.t(), keyword()) ::
          :ok | {:error, Diagnostic.t()}
  def register(registry, extension, opts \\ []) do
    override = Keyword.get(opts, :override, false)

    Agent.get_and_update(registry, fn state ->
      case Map.get(state.extensions, extension.name) do
        nil ->
          {:ok, %{state | extensions: Map.put(state.extensions, extension.name, extension)}}

        _existing when override ->
          {:ok, %{state | extensions: Map.put(state.extensions, extension.name, extension)}}

        _existing ->
          {{:error,
            %Diagnostic{
              type: :collision,
              message: "extension name collision: #{extension.name} is already registered",
              details: %{name: extension.name}
            }}, state}
      end
    end)
  end

  @spec list(atom() | pid()) :: [Handbean.Extension.t()]
  def list(registry) do
    Agent.get(registry, fn state -> state.extensions |> Map.values() end)
  end

  @spec list_active(atom() | pid()) :: [Handbean.Extension.t()]
  def list_active(registry) do
    registry |> list() |> Enum.filter(& &1.enabled)
  end

  @spec get(atom() | pid(), String.t()) :: {:ok, Handbean.Extension.t()} | {:error, :not_found}
  def get(registry, name) do
    Agent.get(registry, fn state ->
      case Map.get(state.extensions, name) do
        nil -> {:error, :not_found}
        ext -> {:ok, ext}
      end
    end)
  end

  @doc "Commit an extension manifest and its current hook module together."
  @spec commit(atom() | pid(), Handbean.Extension.t(), module() | nil) :: :ok
  def commit(registry, extension, hook_module) do
    Agent.update(registry, fn state ->
      hook_modules =
        case hook_module do
          nil -> Map.delete(state.hook_modules, extension.name)
          module -> Map.put(state.hook_modules, extension.name, module)
        end

      %{
        state
        | extensions: Map.put(state.extensions, extension.name, extension),
          hook_modules: hook_modules
      }
    end)

    :ok
  end

  @spec unregister(atom() | pid(), String.t()) :: :ok
  def unregister(registry, name) do
    Agent.update(registry, fn state ->
      %{
        state
        | extensions: Map.delete(state.extensions, name),
          hook_modules: Map.delete(state.hook_modules, name)
      }
    end)

    :ok
  end

  @spec register_hook_module(atom() | pid(), String.t(), module()) :: :ok
  def register_hook_module(registry, extension_name, hook_module) do
    Agent.update(registry, fn state ->
      %{state | hook_modules: Map.put(state.hook_modules, extension_name, hook_module)}
    end)

    :ok
  end

  @spec list_hook_modules(atom() | pid()) :: %{String.t() => module()}
  def list_hook_modules(registry) do
    Agent.get(registry, fn state -> state.hook_modules end)
  end

  @spec reset(atom() | pid()) :: :ok
  def reset(registry) do
    Agent.update(registry, fn _state -> %{extensions: %{}, hook_modules: %{}} end)
    :ok
  end

  @spec list_hooks_by_event(atom() | pid(), String.t()) :: [Handbean.Extension.t()]
  def list_hooks_by_event(registry, event_name) do
    registry
    |> list_active()
    |> Enum.filter(fn ext -> event_name in ext.hooks end)
  end

  @spec list_declared_tools(atom() | pid()) :: [map()]
  def list_declared_tools(registry) do
    registry
    |> list_active()
    |> Enum.flat_map(fn ext ->
      Enum.map(ext.tools, fn tool -> Map.put(tool, :extension_name, ext.name) end)
    end)
  end

  @spec list_declared_commands(atom() | pid()) :: [map()]
  def list_declared_commands(registry) do
    registry
    |> list_active()
    |> Enum.flat_map(fn ext ->
      Enum.map(ext.commands, fn cmd -> Map.put(cmd, :extension_name, ext.name) end)
    end)
  end

  @spec list_declared_providers(atom() | pid()) :: [map()]
  def list_declared_providers(registry) do
    registry
    |> list_active()
    |> Enum.flat_map(fn ext ->
      Enum.map(ext.providers, fn prov -> Map.put(prov, :extension_name, ext.name) end)
    end)
  end

  @spec size(atom() | pid()) :: non_neg_integer()
  def size(registry) do
    Agent.get(registry, fn state -> map_size(state.extensions) end)
  end
end
