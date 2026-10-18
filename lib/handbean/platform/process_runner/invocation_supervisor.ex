defmodule Handbean.Platform.ProcessRunner.InvocationSupervisor do
  @moduledoc """
  Temporary supervisor for OS invocations.

  Children are temporary. A crash cleans up in `Invocation.terminate/2` and
  does not start the command again.
  """

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_invocation(opts) do
    spec = %{
      id: Handbean.Platform.ProcessRunner.Invocation,
      start: {Handbean.Platform.ProcessRunner.Invocation, :start_link, [opts]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
