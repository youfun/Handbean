defmodule Handbean.Extension.HookPipeline do
  @moduledoc """
  Extension hook execution pipeline.

  Called from Runner's `on_event` chain and Turn's `handle_tool_use/3`.
  Executes all matching extension hooks in registration order.

  Extensions can:
  - Return `:ok` to pass through
  - Return `{:halt, reason}` to block the event
  - Return `{:ok, new_ctx}` to transform the event payload

  ## Blockable event types

  Only certain events can be blocked:
  - `before_agent_start` — can block run, inject system_prompt
  - `tool_call` — can block tool execution, mutate args
  - `context` — can stop the provider request or filter its messages/prompt

  All other events are read-only notifications. A halt or transformation on a
  notification is ignored without suppressing later observers. Tool argument
  rewrites cannot widen workspace permissions or the active tool set.

  ## High-frequency events

  `message_delta` and `thinking_delta` are never dispatched through
  the pipeline to avoid blocking the streaming path.
  """

  alias Handbean.Extension.{Event, HookRunner, Registry}

  @high_freq_events [:message_delta, :thinking_delta]

  @doc """
  Run all matching extension hooks for the given event.

  Returns:
  - `:ok` — all hooks passed
  - `{:block, reason}` — a hook halted execution
  - `{:transform, payload}` — a hook modified the payload
  """
  @spec run(session_id :: String.t(), event :: {atom(), map()}) ::
          :ok | {:block, String.t()} | {:transform, map()}
  def run(_session_id, {kind, _payload}) when kind in @high_freq_events do
    :ok
  end

  def run(session_id, {kind, payload}, opts \\ []) do
    runner = build_runner(opts)

    event_name = normalize_event_name(kind)

    # If event name is not known, skip the pipeline (no hooks can match)
    if Event.known_event?(event_name) do
      {:ok, event} = Event.new(event_name, session_id, payload)

      result =
        HookRunner.run(runner, event,
          session_id: session_id,
          read_only?: not Event.blockable?(kind)
        )

      case result do
        %{status: :halted, halt_reason: reason} ->
          {:block, to_string(reason)}

        %{status: :ok, final_ctx: ctx} when ctx == %{} ->
          :ok

        %{status: :ok, final_ctx: ctx} ->
          # Strip internal keys injected by HookRunner (session_id, ext_name)
          clean_ctx = Map.drop(ctx, [:session_id, :ext_name])

          if Event.blockable?(kind) and map_size(clean_ctx) > 0 do
            {:transform, clean_ctx}
          else
            :ok
          end

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Register a hook module for an extension in the global extension registry.

  The extension must already be registered. The hook module must implement
  `Handbean.Extension.Hook` behaviour.
  """
  @spec register_hook_module(atom(), String.t(), module()) :: :ok | {:error, :not_found}
  def register_hook_module(registry, extension_name, hook_module) do
    case Registry.get(registry, extension_name) do
      {:ok, _ext} ->
        # Update the extension's hook module mapping in the registry
        Registry.register_hook_module(registry, extension_name, hook_module)
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # Build a HookRunner from the given extension registry (or the global one).
  # Hooks are collected from all active extensions that have registered hook modules.
  defp build_runner(opts) do
    registry = Keyword.get(opts, :registry, Handbean.Extension.Registry)

    case Process.whereis(registry) do
      nil ->
        HookRunner.new()

      _pid ->
        extensions = Registry.list_active(registry)
        hook_modules = Registry.list_hook_modules(registry)

        Enum.reduce(extensions, HookRunner.new(), fn ext, runner ->
          case Map.get(hook_modules, ext.name) do
            nil -> runner
            mod -> HookRunner.register(runner, ext, mod)
          end
        end)
    end
  end

  defp normalize_event_name(kind) when is_atom(kind), do: kind
end
