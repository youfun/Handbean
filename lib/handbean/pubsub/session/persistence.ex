defmodule Handbean.PubSub.Session.Persistence do
  @moduledoc """
  Persistence boundary for Session snapshots and recorded events.

  Next-turn acceptance and deletion share a transaction with the snapshot when
  using SQLite. The returned boolean tells Session whether that transaction
  already saved the snapshot. Session owns all save timers and throttle state;
  this module performs synchronous IO without changing runtime state.
  """

  alias Handbean.PubSub.AgentEvent
  alias Handbean.PubSub.Session.SnapshotCodec

  @doc false
  @spec options(keyword()) :: {module(), keyword(), keyword()}
  def options(opts) do
    store =
      Keyword.get(opts, :session_store) ||
        Application.get_env(:handbean, :session_store, Handbean.SessionStore.SQLite)

    store_opts =
      opts
      |> Keyword.get(:session_store_opts, [])
      |> Keyword.put_new(:session_store_enabled?, store_enabled?(opts))

    store_opts =
      if store == Handbean.SessionStore.SQLite,
        do: Keyword.put(store_opts, :recovery_projection?, true),
        else: store_opts

    {store, store_opts, Keyword.take(opts, [:event_dir, :event_recorder_enabled?])}
  end

  @doc false
  @spec load(String.t(), module(), keyword()) :: map()
  def load(session_id, store, opts) do
    if store_enabled?(opts) do
      case store.load(session_id, opts) do
        {:ok, snapshot} -> snapshot
        {:error, _reason} -> %{}
      end
    else
      %{}
    end
  end

  @doc false
  @spec save(map()) :: :ok | {:error, term()}
  def save(state) do
    if store_enabled?(state.store_opts) do
      state.session_store.save(state.session_id, SnapshotCodec.encode(state), state.store_opts)
    else
      :ok
    end
  end

  @doc false
  @spec record_event(map(), AgentEvent.t()) :: term()
  def record_event(state, event) do
    if Keyword.get(
         state.recorder_opts,
         :event_recorder_enabled?,
         Application.get_env(:handbean, :event_recorder_enabled?, true)
       ) do
      Handbean.EventRecorder.record(state.session_id, event, state.recorder_opts)
    end
  end

  @doc false
  @spec accept_next_turn(map(), term(), map(), keyword()) ::
          {:ok, boolean()} | {:error, term()}
  def accept_next_turn(state, content, receipt, opts) do
    id = state.session_id

    if sqlite_accept_transaction?(opts, state) do
      result =
        Handbean.Repo.transaction(fn ->
          with :ok <- persist_next_turn_inbound(id, content, receipt, opts),
               :ok <- state.session_store.save(id, SnapshotCodec.encode(state), state.store_opts) do
            :ok
          else
            {:error, reason} -> Handbean.Repo.rollback(reason)
          end
        end)

      case result do
        {:ok, :ok} ->
          Handbean.ConversationStore.broadcast_title_updated(id)
          {:ok, true}

        {:error, reason} ->
          {:error, reason}
      end
    else
      case persist_next_turn_inbound(id, content, receipt, opts) do
        :ok -> {:ok, false}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  @spec delete_next_turn(map(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def delete_next_turn(state, message_id) do
    id = state.session_id

    if state.session_store == Handbean.SessionStore.SQLite and
         store_enabled?(state.store_opts) do
      result =
        Handbean.Repo.transaction(fn ->
          with :ok <- Handbean.ConversationTranscriptStore.delete(id, message_id),
               :ok <- state.session_store.save(id, SnapshotCodec.encode(state), state.store_opts) do
            :ok
          else
            {:error, reason} -> Handbean.Repo.rollback(reason)
          end
        end)

      case result do
        {:ok, :ok} -> {:ok, true}
        {:error, reason} -> {:error, reason}
      end
    else
      case Handbean.ConversationTranscriptStore.delete(id, message_id) do
        :ok -> {:ok, false}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp persist_next_turn_inbound(id, content, receipt, opts) do
    if opts[:persist_candidate?] do
      case Handbean.Agent.TranscriptPersistence.accept_inbound(id, content, receipt, opts) do
        {:ok, _} -> :ok
        error -> error
      end
    else
      Handbean.Agent.OperationReceipt.complete({:message, id}, opts[:request_id], receipt)
    end
  end

  defp sqlite_accept_transaction?(opts, state) do
    opts[:persist_candidate?] == true and store_enabled?(state.store_opts) and
      state.session_store == Handbean.SessionStore.SQLite and
      Handbean.ConversationTranscriptStore.impl(opts) ==
        Handbean.ConversationTranscriptStore.ConversationStore
  end

  defp store_enabled?(opts) do
    Keyword.get(
      opts,
      :session_store_enabled?,
      Application.get_env(:handbean, :session_store_enabled?, true)
    )
  end
end
