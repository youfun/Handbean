defmodule Handbean.Storage.Health do
  @moduledoc "Tracks fatal SQLite health failures for the running Repo."

  use GenServer

  alias Handbean.Storage.ErrorClassifier

  @handler_id {__MODULE__, :repo_query}
  @query_event [:handbean, :repo, :query]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec status() :: :healthy | {:open, ErrorClassifier.category()}
  def status do
    GenServer.call(__MODULE__, :status)
  catch
    :exit, _ -> :healthy
  end

  @spec writable?() :: boolean()
  def writable?, do: status() == :healthy

  @spec check_write() :: :ok | {:error, :storage_unavailable}
  def check_write do
    if writable?(), do: :ok, else: {:error, :storage_unavailable}
  end

  @spec report(term()) :: ErrorClassifier.category()
  def report(error) do
    category = ErrorClassifier.classify(error)
    if category == :corrupt, do: GenServer.cast(__MODULE__, {:open, category})
    category
  end

  @doc false
  def handle_repo_event(_event, _measurements, metadata, _config) do
    case Map.get(metadata, :result) do
      {:error, error} -> report(error)
      _ -> :ok
    end
  end

  @impl true
  def init(_opts) do
    :telemetry.detach(@handler_id)
    :ok = :telemetry.attach(@handler_id, @query_event, &__MODULE__.handle_repo_event/4, nil)
    {:ok, :healthy}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast({:open, category}, _state), do: {:noreply, {:open, category}}

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end
end
