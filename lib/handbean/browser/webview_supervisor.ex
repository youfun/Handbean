defmodule Handbean.Browser.WebViewSupervisor do
  @moduledoc """
  Dynamic supervisor for independent WebView browser sessions.

  One session per conversation by default. `fresh` destroys the instance
  and bumps generation; it does not clear the shared Android WebView profile.
  """

  use DynamicSupervisor

  alias Handbean.Browser.WebViewSession

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec ensure(String.t(), String.t() | atom(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def ensure(conversation_id, session_mode, opts \\ [])
      when is_binary(conversation_id) do
    mode = if session_mode in ["fresh", :fresh], do: "fresh", else: "auto"

    case lookup(conversation_id) do
      {:ok, meta} when mode == "auto" ->
        {:ok, meta}

      {:ok, meta} when mode == "fresh" ->
        generation = Map.get(meta, :generation, 1) + 1
        _ = DynamicSupervisor.terminate_child(__MODULE__, meta.pid)
        start_session(conversation_id, generation, opts)

      :error ->
        start_session(conversation_id, 1, opts)
    end
  end

  @spec lookup(String.t()) :: {:ok, map()} | :error
  def lookup(conversation_id) when is_binary(conversation_id) do
    case Registry.lookup(Handbean.Browser.WebViewRegistry, {:conversation, conversation_id}) do
      [{pid, meta}] -> {:ok, Map.merge(meta, %{pid: pid})}
      [] -> :error
    end
  end

  @spec stop(String.t()) :: :ok
  def stop(conversation_id) when is_binary(conversation_id) do
    case lookup(conversation_id) do
      {:ok, %{pid: pid}} ->
        _ = DynamicSupervisor.terminate_child(__MODULE__, pid)
        :ok

      :error ->
        :ok
    end
  end

  @spec running?() :: boolean()
  def running?, do: is_pid(Process.whereis(__MODULE__))

  defp start_session(conversation_id, generation, opts) do
    session_id = "bws_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    spec = %{
      id: session_id,
      start:
        {WebViewSession, :start_link,
         [
           [
             session_id: session_id,
             conversation_id: conversation_id,
             generation: generation
           ] ++ opts
         ]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} ->
        {:ok,
         %{
           session_id: session_id,
           generation: generation,
           pid: pid,
           outcome: if(generation == 1, do: :created, else: :replaced)
         }}

      other ->
        other
    end
  end
end
