defmodule Handbean.MCP.RuntimeSupervisor do
  @moduledoc """
  Dynamic supervisor for MCP server runtime processes.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: DynamicSupervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_runtime(keyword()) :: DynamicSupervisor.on_start_child()
  def start_runtime(opts) do
    DynamicSupervisor.start_child(__MODULE__, {Handbean.MCP.ServerRuntime, opts})
  end
end
