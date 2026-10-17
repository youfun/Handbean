defmodule Handbean.ExportSnapshot.Binding do
  @moduledoc """
  In-process binding from an approval tool call to a fixed export snapshot.

  A supervised owner holds the ETS table. Callers never create it.
  Not a second approval store.
  """

  use GenServer

  @table __MODULE__
  @name __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @spec put(String.t(), String.t(), map()) :: :ok
  def put(conversation_id, tool_call_id, meta)
      when is_binary(conversation_id) and is_binary(tool_call_id) and is_map(meta) do
    true = :ets.insert(table!(), {{conversation_id, tool_call_id}, meta})
    :ok
  end

  @spec fetch(String.t(), String.t()) :: {:ok, map()} | :error
  def fetch(conversation_id, tool_call_id)
      when is_binary(conversation_id) and is_binary(tool_call_id) do
    case :ets.lookup(table!(), {conversation_id, tool_call_id}) do
      [{_, meta}] -> {:ok, meta}
      [] -> :error
    end
  end

  def fetch(_, _), do: :error

  @spec take(String.t(), String.t()) :: {:ok, map()} | :error
  def take(conversation_id, tool_call_id)
      when is_binary(conversation_id) and is_binary(tool_call_id) do
    case :ets.take(table!(), {conversation_id, tool_call_id}) do
      [{_, meta}] -> {:ok, meta}
      [] -> :error
    end
  end

  def take(_, _), do: :error

  @doc """
  Atomically consume a binding. Missing or mismatched expected fields fail
  and the row is not restored.
  """
  @spec consume(String.t(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def consume(conversation_id, tool_call_id, expected)
      when is_binary(conversation_id) and is_binary(tool_call_id) and is_map(expected) do
    case take(conversation_id, tool_call_id) do
      {:ok, meta} ->
        if match_expected?(meta, expected), do: {:ok, meta}, else: {:error, :snapshot_mismatch}

      :error ->
        {:error, :file_unavailable}
    end
  end

  def consume(_, _, _), do: {:error, :file_unavailable}

  @spec delete(String.t(), String.t()) :: :ok
  def delete(conversation_id, tool_call_id)
      when is_binary(conversation_id) and is_binary(tool_call_id) do
    :ets.delete(table!(), {conversation_id, tool_call_id})
    :ok
  end

  def delete(_, _), do: :ok

  @spec clear_conversation(String.t()) :: :ok
  def clear_conversation(conversation_id) when is_binary(conversation_id) do
    @table
    |> :ets.match({{conversation_id, :"$1"}, :"$2"})
    |> Enum.each(fn [tool_call_id, _] ->
      :ets.delete(@table, {conversation_id, tool_call_id})
    end)

    :ok
  end

  def clear_conversation(_), do: :ok

  defp match_expected?(meta, expected) do
    same_path?(field(meta, :relative_path), field(expected, :relative_path)) and
      same_workspace?(field(meta, :workspace_path), field(expected, :workspace_path)) and
      same_action?(field(meta, :action), field(expected, :action))
  end

  defp same_path?(a, b) when is_binary(a) and is_binary(b), do: Path.expand(a) == Path.expand(b)
  defp same_path?(_, _), do: false

  defp same_workspace?(a, b) when is_binary(a) and is_binary(b),
    do: Path.expand(a) == Path.expand(b)

  defp same_workspace?(_, _), do: false

  defp same_action?(a, b),
    do: normalize_action(a) == normalize_action(b) and normalize_action(a) != nil

  defp normalize_action(action) when action in [:open_file, :share_file], do: action
  defp normalize_action("open_file"), do: :open_file
  defp normalize_action("share_file"), do: :share_file
  defp normalize_action(_), do: nil

  defp field(map, key) when is_atom(key) do
    Handbean.Utils.SafeMap.get_any(map, [key, Atom.to_string(key)])
  end

  defp table! do
    case :ets.whereis(@table) do
      :undefined ->
        raise "#{inspect(__MODULE__)} ETS table is missing; start the supervised owner"

      tid ->
        tid
    end
  end
end
