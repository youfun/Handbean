defmodule Handbean.AgentRunSupervisor do
  @moduledoc """
  Dynamic supervisor for per-conversation agent run supervisors.
  """

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_run(conversation_id, content, opts) do
    child_opts = [
      conversation_id: conversation_id,
      content: content,
      run_opts: opts
    ]

    DynamicSupervisor.start_child(__MODULE__, {Handbean.Agent.RunSupervisor, child_opts})
  end

  def stop_run(pid) when is_pid(pid), do: DynamicSupervisor.terminate_child(__MODULE__, pid)

  def stop_run(conversation_id) when is_binary(conversation_id) do
    case Registry.lookup(Handbean.AgentRunSupervisorRegistry, conversation_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_found}
    end
  end

  def which_runs do
    DynamicSupervisor.which_children(__MODULE__)
  end
end
