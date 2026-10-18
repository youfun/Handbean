defmodule Handbean.Extension.Mount do
  @moduledoc """
  In-memory extension mount: compile a source string, register `ext__*`
  tools and `child_spec/1` workers, then unmount without writing disk.

  Mounts are serialized by a GenServer. Every successful mount gets a
  generated module namespace, so replacing an id cannot purge the modules
  that were just compiled. Runtime registrations are owned by the mount id
  and are replaced only after the new source has compiled and validated.
  """

  use GenServer

  alias Handbean.Agent.ExtensionBridge
  alias Handbean.Extension.Diagnostic
  alias Handbean.Extension.Supervisor, as: ExtSupervisor

  @type mount :: %{id: String.t(), modules: [module()], tools: [String.t()]}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec mount(String.t(), keyword()) :: {:ok, mount()} | {:error, [Diagnostic.t()]}
  def mount(source, opts \\ []) when is_binary(source) do
    ensure_started()
    id = Keyword.get_lazy(opts, :name, &next_id/0)
    GenServer.call(__MODULE__, {:mount, id, source})
  end

  @spec unmount(String.t()) :: :ok
  def unmount(id) when is_binary(id) do
    ensure_started()
    GenServer.call(__MODULE__, {:unmount, id})
  end

  @impl true
  def init(_opts), do: {:ok, %{seq: 0, mounts: %{}}}

  @impl true
  def handle_call({:mount, id, source}, _from, state) do
    generation = state.seq + 1

    case compile_source(source, id, generation) do
      {:error, diags} ->
        {:reply, {:error, diags}, %{state | seq: generation}}

      {:ok, modules} ->
        tool_modules = tool_modules(modules, id)

        case validate_modules(modules, tool_modules, id) do
          {:error, diags} ->
            purge_modules(modules)
            {:reply, {:error, diags}, %{state | seq: generation}}

          :ok ->
            owner = {:mount, id}

            case Handbean.Tool.Registry.replace_owner(owner, tool_modules) do
              :ok ->
                _ = ExtSupervisor.replace_workers(owner, modules)
                old = Map.get(state.mounts, id)
                purge_modules(Map.get(old || %{}, :modules, []))

                record = %{
                  id: id,
                  modules: modules,
                  tools: Enum.map(tool_modules, & &1.name())
                }

                {:reply, {:ok, record},
                 %{state | seq: generation, mounts: Map.put(state.mounts, id, record)}}

              {:error, reason} ->
                purge_modules(modules)

                {:reply, {:error, [commit_diagnostic(id, reason)]}, %{state | seq: generation}}
            end
        end
    end
  end

  @impl true
  def handle_call({:unmount, id}, _from, state) do
    case Map.pop(state.mounts, id) do
      {nil, _mounts} ->
        {:reply, :ok, state}

      {%{modules: modules}, mounts} ->
        owner = {:mount, id}
        _ = Handbean.Tool.Registry.remove_owner(owner)
        _ = ExtSupervisor.replace_workers(owner, [])
        purge_modules(modules)
        {:reply, :ok, %{state | mounts: mounts}}
    end
  end

  defp compile_source(source, id, generation) do
    with {:ok, quoted} <- Code.string_to_quoted(source, file: "mount:#{id}"),
         {:ok, modules} <- namespace_and_compile(quoted, generation) do
      {:ok, modules}
    else
      {:error, %Diagnostic{} = diagnostic} -> {:error, [diagnostic]}
      {:error, error} -> {:error, [compile_diagnostic(error)]}
    end
  rescue
    e ->
      {:error, [compile_diagnostic(e)]}
  end

  defp namespace_and_compile(quoted, generation) do
    defined_modules = defined_modules(quoted)

    if MapSet.size(defined_modules) == 0 do
      {:error,
       %Diagnostic{
         type: :warning,
         message: "Failed to compile mount source: no defmodule declaration found"
       }}
    else
      namespace = Module.concat(Handbean.Extension.Mount.Generated, "Gen#{generation}")
      mapping = Map.new(defined_modules, &{&1, Module.concat(namespace, &1)})
      rewritten = rewrite_modules(quoted, mapping)

      modules =
        rewritten
        |> Code.compile_quoted("mount:#{generation}")
        |> Enum.map(&elem(&1, 0))

      {:ok, modules}
    end
  rescue
    e -> {:error, compile_diagnostic(e)}
  end

  defp defined_modules(quoted) do
    {_quoted, modules} =
      Macro.prewalk(quoted, MapSet.new(), fn
        {:defmodule, _meta, [name, _body]} = node, acc ->
          case module_from_ast(name) do
            {:ok, module} -> {node, MapSet.put(acc, module)}
            :error -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    modules
  end

  defp rewrite_modules(ast, mapping) do
    Macro.prewalk(ast, fn
      {:__aliases__, meta, parts} = node ->
        case Map.get(mapping, Module.concat(parts)) do
          nil -> node
          module -> {:__aliases__, meta, Module.split(module) |> Enum.map(&String.to_atom/1)}
        end

      node ->
        node
    end)
  end

  defp module_from_ast({:__aliases__, _meta, parts}) when is_list(parts) do
    {:ok, Module.concat(parts)}
  end

  defp module_from_ast(module) when is_atom(module), do: {:ok, module}
  defp module_from_ast(_), do: :error

  defp tool_modules(modules, id) do
    prefix = "ext__#{id}__"

    Enum.filter(modules, fn mod ->
      function_exported?(mod, :name, 0) and
        function_exported?(mod, :execute, 2) and
        String.starts_with?(to_string(mod.name()), prefix)
    end)
  end

  defp validate_modules(modules, tool_modules, id) do
    with :ok <- validate_tool_modules(tool_modules, id) do
      validate_worker_modules(modules)
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
                message: "Invalid mounted worker #{inspect(mod)}: #{Exception.message(exception)}"
              }
            ]}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, diags} -> {:error, diags}
    end
  end

  defp validate_tool_modules(modules, id) do
    prefix = "ext__#{id}__"

    Enum.reduce_while(modules, :ok, fn mod, :ok ->
      case ExtensionBridge.validate_extension_tool(mod) do
        :ok ->
          if String.starts_with?(mod.name(), prefix) do
            {:cont, :ok}
          else
            {:halt, {:error, [invalid_tool_diagnostic(mod, prefix)]}}
          end

        {:error, reason} ->
          {:halt, {:error, [invalid_tool_diagnostic(mod, reason)]}}
      end
    end)
  end

  defp invalid_tool_diagnostic(mod, detail) do
    %Diagnostic{
      type: :warning,
      message: "Invalid mounted tool #{inspect(mod)}: #{detail}"
    }
  end

  defp commit_diagnostic(id, reason) do
    %Diagnostic{
      type: :warning,
      message: "Failed to commit mount #{id}: #{inspect(reason)}"
    }
  end

  defp compile_diagnostic(error) do
    message =
      case error do
        %SyntaxError{} = exception -> Exception.message(exception)
        %CompileError{} = exception -> Exception.message(exception)
        exception when is_exception(exception) -> Exception.message(exception)
        other -> inspect(other)
      end

    %Diagnostic{type: :warning, message: "Failed to compile mount source: #{message}"}
  end

  defp purge_modules(modules) do
    Enum.each(modules, fn module ->
      # soft_purge refuses to remove code still used by an old process.
      if :code.soft_purge(module), do: :code.delete(module)
    end)
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        {:ok, _} = start_link([])
        :ok

      _pid ->
        :ok
    end
  end

  defp next_id do
    case Process.whereis(__MODULE__) do
      nil ->
        "dyn-1"

      _pid ->
        # The actual sequence is assigned in the serialized server call.
        "dyn-#{System.unique_integer([:positive])}"
    end
  end
end
