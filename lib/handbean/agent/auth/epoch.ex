defmodule Handbean.Agent.Auth.Epoch do
  @moduledoc """
  Persistent owner of OAuth refresh generations.

  The ETS table must outlive any one refresh caller. Only login replacement
  and explicit invalidation bump the generation.
  """

  use GenServer

  @table :handbean_oauth_refresh_epochs

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def bump(provider_id) when is_binary(provider_id) do
    ensure_table()
    :ets.update_counter(@table, provider_id, {2, 1}, {provider_id, 0})
  end

  def current(provider_id) when is_binary(provider_id) do
    ensure_table()

    case :ets.lookup(@table, provider_id) do
      [{^provider_id, epoch}] -> epoch
      [] -> 0
    end
  end

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _tid ->
        :ok
    end
  end
end
