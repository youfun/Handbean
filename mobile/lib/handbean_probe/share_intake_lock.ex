defmodule HandbeanProbe.ShareIntake.Lock do
  @moduledoc """
  Serializes ShareIntake mutations. One process is the lock; nested calls
  from that process reenter. That is the Elixir-side per-intake write protocol.
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        spec = {__MODULE__, []}

        case Process.whereis(Handbean.Supervisor) do
          nil ->
            case start_link([]) do
              {:ok, _} -> :ok
              {:error, {:already_started, _}} -> :ok
              {:error, reason} -> {:error, reason}
            end

          _pid ->
            case Supervisor.start_child(Handbean.Supervisor, spec) do
              {:ok, _} -> :ok
              {:ok, _, _} -> :ok
              {:error, {:already_started, _}} -> :ok
              {:error, :already_present} -> :ok
              {:error, {:already_present, _}} -> :ok
              {:error, reason} -> {:error, reason}
            end
        end

      _pid ->
        :ok
    end
  end

  def run(_intake_id, fun) when is_function(fun, 0) do
    case ensure_started() do
      :ok ->
        if Process.get(:share_intake_lock_held) do
          fun.()
        else
          GenServer.call(__MODULE__, {:run, fun}, 15_000)
        end

      other ->
        other
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:run, fun}, _from, state) do
    Process.put(:share_intake_lock_held, true)

    try do
      {:reply, fun.(), state}
    after
      Process.delete(:share_intake_lock_held)
    end
  end
end
