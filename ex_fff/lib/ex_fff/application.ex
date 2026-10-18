defmodule ExFff.Application do
  @moduledoc """
  OTP Application for ExFff.

  Supervises `ExFff.Registry` and `ExFff.IndexSupervisor` for multi-workspace
  file indexing.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: ExFff.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: ExFff.IndexSupervisor}
    ]

    opts = [strategy: :one_for_one, name: ExFff.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
