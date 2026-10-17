defmodule Handbean.Log.Store do
  @moduledoc """
  In-process event store backed by an Agent.

  Provides `append/2`, `list/1`, `filter/2`, `count/1`, and `clear/1`.
  The store is **not** started automatically by the application supervisor —
  call `start_link/1` when you need it (e.g. in tests or per-session).

  ## Example

      {:ok, store} = Handbean.Log.Store.start_link(name: :audit_store)
      {:ok, event} = Handbean.Log.Event.new(kind: :session, level: :info, message: "start")
      Handbean.Log.Store.append(store, event)
      Handbean.Log.Store.list(store)
      # => [%Handbean.Log.Event{...}]

  ## Future integration

  When structured logging is integrated into the agent pipeline:
    * Start a store per session and pass it through `Handbean.Agent.State`
    * Wire `Handbean.Log.Store.append/2` calls into `Handbean.Agent.Middleware.Logger`
    * Use `Handbean.Log.Store.filter/2` for per-session or per-kind audit views
  """

  use Agent

  alias Handbean.Log.Event

  @doc """
  Starts a new store process.

  ## Options
    * `:name` — optional registered name (atom)
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> [] end, opts)
  end

  @doc """
  Stops the store process.
  """
  @spec stop(pid() | atom()) :: :ok
  def stop(store), do: Agent.stop(store)

  @doc """
  Appends an event to the store.

  Returns `:ok`. Does not crash on non-Event input.
  """
  @spec append(pid() | atom(), Event.t()) :: :ok
  def append(store, %Event{} = event) do
    Agent.update(store, fn events -> [event | events] end)
    :ok
  end

  def append(_store, _non_event) do
    :ok
  end

  @doc """
  Returns all events currently in the store, in insertion order.
  """
  @spec list(pid() | atom()) :: [Event.t()]
  def list(store), do: Agent.get(store, &Enum.reverse/1)

  @doc """
  Returns the number of events in the store.
  """
  @spec count(pid() | atom()) :: non_neg_integer()
  def count(store), do: Agent.get(store, &length/1)

  @doc """
  Filters events by one or more criteria.

  Supported filter keys:
    * `:kind` — atom, e.g. `:tool`
    * `:level` — atom, e.g. `:error`
    * `:session_id` — string

  Multiple criteria are combined with AND logic.
  Unknown keys are treated as a no-match (returns empty list).

  ## Examples

      Store.filter(store, kind: :tool)
      Store.filter(store, kind: :provider, level: :error)
      Store.filter(store, session_id: "sess-abc")
  """
  @spec filter(pid() | atom(), keyword()) :: [Event.t()]
  def filter(store, criteria) when is_list(criteria) do
    store
    |> list()
    |> Enum.filter(fn event ->
      Enum.all?(criteria, fn
        {:kind, k} -> event.kind == k
        {:level, l} -> event.level == l
        {:session_id, sid} -> event.session_id == sid
        _ -> false
      end)
    end)
  end

  @doc """
  Removes all events from the store.
  """
  @spec clear(pid() | atom()) :: :ok
  def clear(store) do
    Agent.update(store, fn _events -> [] end)
    :ok
  end
end
