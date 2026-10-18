defmodule Handbean.Agent.Middleware.Security do
  @moduledoc """
  Security middleware — validates paths before tool execution.
  """

  @behaviour Handbean.Agent.Middleware

  alias Handbean.Agent.State

  @impl true
  def call(:before_completion, %State{} = state), do: state
  @impl true
  def call(:after_completion, %State{} = state), do: state
  @impl true
  def call(:after_compaction, %State{} = state), do: state
  @impl true
  def call(:after_tool_request, %State{} = state), do: state

  @impl true
  def call(:after_tool_execution, %State{} = state) do
    # Future: audit tool execution results
    state
  end

  @impl true
  def call(:on_error, %State{} = state) do
    # Future: classify security errors
    state
  end

  @impl true
  def call(:session_start, %State{} = state), do: state

  @impl true
  def call(:session_end, %State{} = state) do
    # Future: audit session
    state
  end
end
