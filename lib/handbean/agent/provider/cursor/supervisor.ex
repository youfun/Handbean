defmodule Handbean.Agent.Provider.Cursor.Supervisor do
  @moduledoc """
  Dynamic supervisor for Cursor HTTP/2 session processes.
  """

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_session(id, config) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {Handbean.Agent.Provider.Cursor.Session, id: id, config: config}
    )
  end
end
