defmodule Handbean.Preview.Store do
  @moduledoc """
  In-memory owner of preview records.

  Closing a record invalidates its URL. Hiding a display must not call
  `close/1`.
  """

  use GenServer

  @name __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  def register(attrs) when is_map(attrs) do
    GenServer.call(@name, {:register, attrs})
  end

  def get(id) when is_binary(id) do
    case lookup(id) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, :not_found}
    end
  end

  def fetch_open(id) when is_binary(id) do
    case get(id) do
      {:ok, %{status: :open} = record} -> {:ok, record}
      {:ok, %{status: :closed}} -> {:error, :closed}
      other -> other
    end
  end

  def list(conversation_id) when is_binary(conversation_id) do
    GenServer.call(@name, {:list, conversation_id})
  end

  def close(id) when is_binary(id) do
    GenServer.call(@name, {:close, id})
  end

  @spec normalize_root(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def normalize_root(root, opts \\ []) do
    expanded = Path.expand(root)

    cond do
      not File.dir?(expanded) ->
        {:error, :not_a_directory}

      workspace = Keyword.get(opts, :workspace_path) ->
        confine_to_workspace(expanded, workspace)

      true ->
        {:ok, expanded}
    end
  end

  @spec validate_loopback_port(integer()) :: :ok | {:error, term()}
  def validate_loopback_port(port) when is_integer(port) and port > 0 and port < 65_536 do
    :ok
  end

  def validate_loopback_port(_), do: {:error, :invalid_port}

  @impl true
  def init(_opts) do
    {:ok, %{records: %{}}}
  end

  @impl true
  def handle_call({:register, attrs}, _from, state) do
    id = next_id()

    record = %{
      id: id,
      conversation_id: Map.fetch!(attrs, :conversation_id),
      workspace_id: Map.get(attrs, :workspace_id),
      kind: Map.fetch!(attrs, :kind),
      title: Map.get(attrs, :title) || id,
      root: Map.get(attrs, :root),
      port: Map.get(attrs, :port),
      status: :open,
      created_at: System.system_time(:millisecond)
    }

    {:reply, {:ok, record}, %{state | records: Map.put(state.records, id, record)}}
  end

  def handle_call({:lookup, id}, _from, state) do
    {:reply, Map.fetch(state.records, id), state}
  end

  def handle_call({:list, conversation_id}, _from, state) do
    records =
      state.records
      |> Map.values()
      |> Enum.filter(&(&1.conversation_id == conversation_id and &1.status == :open))
      |> Enum.sort_by(& &1.created_at, :desc)

    {:reply, records, state}
  end

  def handle_call({:close, id}, _from, state) do
    case Map.fetch(state.records, id) do
      {:ok, record} ->
        closed = %{record | status: :closed}
        {:reply, {:ok, closed}, %{state | records: Map.put(state.records, id, closed)}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  defp lookup(id) do
    if Process.whereis(@name) do
      GenServer.call(@name, {:lookup, id})
    else
      :error
    end
  end

  defp next_id do
    hex = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    "pv_" <> hex
  end

  defp confine_to_workspace(path, workspace) do
    root = Path.expand(workspace)

    if path == root or String.starts_with?(path, root <> "/") do
      {:ok, path}
    else
      {:error, :outside_workspace}
    end
  end
end
