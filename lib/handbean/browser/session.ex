defmodule Handbean.Browser.Session do
  @moduledoc """
  Per-conversation owner of the managed `agent-browser` session name.

  This process does not hold the Chromium Port. It assigns a short
  session name, rotates it on `session_mode: "fresh"`, and asks an
  injected closer to quit the previous upstream session.
  """

  use GenServer

  alias Handbean.Browser.{Cli, Registry, Supervisor}

  @default_slot "default"

  defstruct [
    :conversation_id,
    :workspace_id,
    :managed_name,
    :closer,
    :updated_at,
    slot: @default_slot
  ]

  @type checkout :: %{name: String.t(), outcome: :created | :reused | :replaced}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)

    case Registry.lookup(conversation_id, @default_slot) do
      {:ok, _pid} -> {:error, :already_exists}
      {:error, :not_found} -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Return the managed session name for this conversation, creating or
  rotating it according to `session_mode`.
  """
  @spec ensure(String.t(), String.t() | atom(), keyword()) ::
          {:ok, checkout()} | {:error, term()}
  def ensure(conversation_id, session_mode, opts \\ [])
      when is_binary(conversation_id) do
    mode = normalize_mode(session_mode)

    with :ok <- require_supervisor(),
         {:ok, pid} <- Supervisor.start_session(conversation_id, opts) do
      GenServer.call(pid, {:checkout, mode, opts})
    end
  end

  @impl true
  def init(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    :ok = Registry.register(conversation_id, @default_slot, self())

    {:ok,
     %__MODULE__{
       conversation_id: conversation_id,
       workspace_id: Keyword.get(opts, :workspace_id),
       closer: Keyword.get(opts, :closer),
       updated_at: System.system_time(:millisecond)
     }}
  end

  @impl true
  def handle_call({:checkout, _mode, opts}, _from, %{managed_name: nil} = state) do
    name = next_name()
    state = state |> remember_closer(opts) |> put_name(name)
    {:reply, {:ok, %{name: name, outcome: :created}}, state}
  end

  def handle_call({:checkout, "auto", opts}, _from, state) do
    state = remember_closer(state, opts)
    {:reply, {:ok, %{name: state.managed_name, outcome: :reused}}, touch(state)}
  end

  def handle_call({:checkout, "fresh", opts}, _from, state) do
    state = remember_closer(state, opts)
    close_managed(state.managed_name, state.closer)
    name = next_name()
    {:reply, {:ok, %{name: name, outcome: :replaced}}, put_name(state, name)}
  end

  @impl true
  def terminate(_reason, state) do
    if is_binary(state.conversation_id) and Process.whereis(Registry) do
      Registry.unregister(state.conversation_id, state.slot)
    end

    if is_binary(state.managed_name) do
      close_managed(state.managed_name, state.closer)
    end

    :ok
  end

  defp require_supervisor do
    if Supervisor.running?() and Process.whereis(Registry) do
      :ok
    else
      {:error, :not_started}
    end
  end

  defp normalize_mode(:auto), do: "auto"
  defp normalize_mode(:fresh), do: "fresh"
  defp normalize_mode("auto"), do: "auto"
  defp normalize_mode("fresh"), do: "fresh"
  defp normalize_mode(_), do: "auto"

  defp next_name do
    hex = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "s" <> hex
  end

  defp remember_closer(state, opts) do
    case Keyword.get(opts, :closer) do
      fun when is_function(fun, 1) -> %{state | closer: fun}
      _ -> state
    end
  end

  defp put_name(state, name) do
    %{state | managed_name: name, updated_at: System.system_time(:millisecond)}
  end

  defp touch(state), do: %{state | updated_at: System.system_time(:millisecond)}

  defp close_managed(name, closer) when is_function(closer, 1) do
    closer.(name)
  rescue
    _ -> :ok
  end

  defp close_managed(name, _closer) when is_binary(name) do
    _ = Cli.run(["close"], session_name: name, timeout_ms: 8_000)
    :ok
  rescue
    _ -> :ok
  end

  defp close_managed(_name, _closer), do: :ok
end
