defmodule Handbean.Extension.HookRunner do
  @moduledoc """
  Executes extension lifecycle hooks in registration order.

  Returns a unified result map:
    %{
      status: :ok | :halted,
      event: event,
      diagnostics: [...],
      halt_reason: term() | nil
    }
  """

  alias Handbean.Extension.Event
  alias Handbean.Extension.Diagnostic

  defstruct hooks: []

  @type hook_entry :: %{
          extension_name: String.t(),
          module: module(),
          events: [String.t()]
        }

  @type t :: %__MODULE__{hooks: [hook_entry()]}

  @type run_result :: %{
          status: :ok | :halted,
          event: Event.t(),
          diagnostics: [Diagnostic.t()],
          halt_reason: term() | nil,
          final_ctx: map()
        }

  @doc "Creates a new empty HookRunner."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Registers a hook module for an extension.
  """
  @spec register(t(), Handbean.Extension.t(), module()) :: t()
  def register(%__MODULE__{hooks: hooks} = runner, extension, module) do
    if implements_hook?(module) do
      entry = %{
        extension_name: extension.name,
        module: module,
        events: extension.hooks
      }

      %{runner | hooks: hooks ++ [entry]}
    else
      runner
    end
  end

  @doc "Runs all registered hooks for the given event."
  @spec run(t(), Event.t(), keyword()) :: run_result()
  def run(%__MODULE__{hooks: hooks}, %Event{} = event, extra_ctx \\ []) do
    event_name_str = Atom.to_string(event.name)
    matching_hooks = Enum.filter(hooks, fn hook -> event_name_str in hook.events end)

    read_only? = Keyword.get(extra_ctx, :read_only?, false)
    base_ctx = extra_ctx |> Keyword.delete(:read_only?) |> Map.new()

    initial_acc = %{
      status: :ok,
      diagnostics: [],
      halt_reason: nil,
      ctx: base_ctx
    }

    result =
      Enum.reduce_while(matching_hooks, initial_acc, fn hook, acc ->
        ext_ctx =
          base_ctx
          |> Map.put(:ext_name, hook.extension_name)
          |> Map.merge(acc.ctx || %{})

        case call_hook(hook, event, ext_ctx, acc) do
          {:halt, _reason} when read_only? ->
            {:cont, acc}

          {:halt, reason} ->
            {:halt, %{acc | status: :halted, halt_reason: reason}}

          {:error, diagnostic} ->
            {:cont, %{acc | diagnostics: [diagnostic | acc.diagnostics]}}

          {:ok, _new_ctx} when read_only? ->
            {:cont, acc}

          {:ok, new_ctx} ->
            merged_ctx = Map.merge(acc.ctx || %{}, new_ctx)
            {:cont, %{acc | ctx: merged_ctx}}
        end
      end)

    %{
      status: result.status,
      event: event,
      diagnostics: result.diagnostics,
      halt_reason: result.halt_reason,
      final_ctx: Map.drop(result.ctx || %{}, [:ext_name, :test_pid])
    }
  end

  defp call_hook(hook, event, ext_ctx, _acc) do
    try do
      case hook.module.handle_event(event, ext_ctx) do
        :ok ->
          {:ok, %{}}

        {:ok, new_ctx} when is_map(new_ctx) ->
          {:ok, new_ctx}

        {:halt, reason} ->
          {:halt, reason}

        {:error, reason} ->
          diagnostic = %Diagnostic{
            type: :error,
            message:
              "hook #{hook.extension_name} (#{inspect(hook.module)}) returned error: #{inspect(reason)}",
            details: %{extension: hook.extension_name, module: hook.module, reason: reason}
          }

          {:error, diagnostic}

        other ->
          diagnostic = %Diagnostic{
            type: :warning,
            message:
              "hook #{hook.extension_name} (#{inspect(hook.module)}) returned unexpected value: #{inspect(other)}",
            details: %{extension: hook.extension_name, module: hook.module}
          }

          {:error, diagnostic}
      end
    rescue
      e ->
        diagnostic = %Diagnostic{
          type: :error,
          message:
            "hook #{hook.extension_name} (#{inspect(hook.module)}) raised: #{Exception.message(e)}",
          details: %{
            extension: hook.extension_name,
            module: hook.module,
            exception: Exception.message(e),
            stacktrace: __STACKTRACE__
          }
        }

        {:error, diagnostic}
    catch
      :throw, reason ->
        diagnostic = %Diagnostic{
          type: :error,
          message:
            "hook #{hook.extension_name} (#{inspect(hook.module)}) threw: #{inspect(reason)}",
          details: %{extension: hook.extension_name, module: hook.module, reason: inspect(reason)}
        }

        {:error, diagnostic}

      :exit, reason ->
        diagnostic = %Diagnostic{
          type: :error,
          message:
            "hook #{hook.extension_name} (#{inspect(hook.module)}) exited: #{inspect(reason)}",
          details: %{extension: hook.extension_name, module: hook.module, reason: inspect(reason)}
        }

        {:error, diagnostic}
    end
  end

  defp implements_hook?(module) do
    case Code.ensure_compiled(module) do
      {:module, ^module} -> function_exported?(module, :handle_event, 2)
      {:error, _} -> false
    end
  end
end
