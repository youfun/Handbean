defmodule Handbean.Agent.Middleware do
  @moduledoc """
  Behaviour for middleware that wraps the agent loop.

  Middleware runs at defined hook points:
  - `:session_start` - before the first turn
  - `:session_end` - after the final turn
  - `:before_completion` - before calling the provider
  - `:after_compaction` - after context compaction occurs
  - `:after_completion` - after provider response with :end_turn
  - `:after_tool_request` - after provider response with :tool_use
  - `:after_tool_execution` - after tools have been executed
  - `:on_error` - when an error occurs

  These are trusted runtime modules with full State access, not the extension
  notification API. Extensions use HookPipeline's three request gates and
  read-only lifecycle notifications. See docs/runtime-contracts.md for order
  and authority; neither mechanism is a sandbox for arbitrary BEAM code.
  """

  alias Handbean.Agent.State

  @type hook ::
          :session_start
          | :session_end
          | :before_completion
          | :after_compaction
          | :after_completion
          | :after_tool_request
          | :after_tool_execution
          | :on_error

  @doc "Called at the specified hook point."
  @callback call(hook(), State.t()) ::
              State.t()
              | {:halt, String.t()}
              | {:interrupt, State.t(), map()}
              | {:tool_guard_denied, State.t()}

  @doc """
  Run all middleware for a given hook point.

  Returns the final state, or `{:halted, reason}` if any middleware halts.
  """
  @spec run(hook(), State.t(), [module()]) ::
          State.t()
          | {:halted, String.t()}
          | {:interrupted, State.t(), map()}
          | {:tool_guard_denied, State.t()}
  def run(hook, %State{} = state, middleware) when is_list(middleware) do
    Enum.reduce_while(middleware, state, fn mod, acc ->
      case mod.call(hook, acc) do
        {:halt, reason} -> {:halt, {:halted, reason}}
        {:interrupt, %State{} = s, data} -> {:halt, {:interrupted, s, data}}
        {:tool_guard_denied, %State{} = s} -> {:halt, {:tool_guard_denied, s}}
        %State{} = s -> {:cont, s}
      end
    end)
  end
end
