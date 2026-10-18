defmodule Handbean.SessionSupervisor do
  @moduledoc """
  Dynamic supervisor for `Handbean.PubSub.Session` processes.

  Session startup intentionally relies on Registry's `{:already_started, pid}`
  path instead of a preflight lookup, so duplicate concurrent starts converge on
  the same process without a TOCTOU race.
  """

  use DynamicSupervisor

  @doc false
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a supervised session."
  def start_session(opts) when is_list(opts) do
    DynamicSupervisor.start_child(__MODULE__, {Handbean.PubSub.Session, opts})
  end

  @doc "Stop a supervised session by id."
  def stop_session(session_id) when is_binary(session_id) do
    case Handbean.PubSub.Session.whereis(session_id) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  @doc "List supervised session children."
  def which_sessions do
    DynamicSupervisor.which_children(__MODULE__)
  end
end
