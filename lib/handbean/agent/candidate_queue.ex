defmodule Handbean.Agent.CandidateQueue do
  @moduledoc """
  Per-run FIFO queue for candidate messages injected while an agent is running.

  Supports two active run queues:
  - `:steer` drained before provider calls
  - `:follow_up` drained when an agent is about to complete

  `:next_turn` is managed by `Handbean.PubSub.Session`, not this run queue.
  """

  use GenServer

  alias Handbean.Agent.Message

  @default_max_size 64
  @deliver_as [:steer, :follow_up]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  def enqueue(server, message, opts \\ []) do
    deliver_as = Keyword.get(opts, :deliver_as, :steer)
    GenServer.call(server, {:enqueue, message, deliver_as, opts})
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] ->
      {:error, :sealed}
  end

  def drain_steer(server), do: GenServer.call(server, {:drain, :steer})
  def drain_follow_up(server), do: GenServer.call(server, {:drain, :follow_up})
  def seal(server), do: GenServer.call(server, :seal)
  def take_pending_or_seal(server), do: GenServer.call(server, :take_pending_or_seal)
  def has_pending?(server), do: GenServer.call(server, :has_pending?)
  def get_messages(server, timeout \\ 5_000), do: GenServer.call(server, :get_messages, timeout)

  def delete_message(server, message_id),
    do: GenServer.call(server, {:delete_message, message_id})

  defp unique_id(prefix) do
    "#{prefix}-#{Ecto.UUID.generate()}"
  end

  @impl true
  def init(opts) do
    owner = Keyword.get(opts, :owner)
    if is_pid(owner), do: Process.monitor(owner)

    {:ok,
     %{
       session_id: Keyword.get(opts, :session_id),
       owner: owner,
       max_size: Keyword.get(opts, :max_size, @default_max_size),
       sealed?: false,
       steer: :queue.new(),
       follow_up: :queue.new(),
       size: 0
     }}
  end

  @impl true
  def handle_call({:enqueue, _message, deliver_as, _opts}, _from, state)
      when deliver_as not in @deliver_as do
    {:reply, {:error, :invalid_deliver_as}, state}
  end

  def handle_call({:enqueue, _message, _deliver_as, _opts}, _from, %{sealed?: true} = state) do
    {:reply, {:error, :sealed}, state}
  end

  def handle_call(
        {:enqueue, _message, _deliver_as, _opts},
        _from,
        %{size: size, max_size: max_value} = state
      )
      when size >= max_value do
    {:reply, {:error, :queue_full}, state}
  end

  def handle_call({:enqueue, message, deliver_as, opts}, _from, state) do
    item = normalize_message(message, deliver_as, opts)
    queue = Map.fetch!(state, deliver_as)
    receipt = %{action: :enqueued, run_id: opts[:run_id]}

    # Seal/capacity checks and persistence share the queue's acceptance gate.
    # A rejected candidate must not appear as an accepted inbound transcript.
    result =
      if Keyword.get(opts, :persist_candidate?, false) do
        Handbean.Agent.TranscriptPersistence.accept_inbound(
          state.session_id,
          item.message,
          receipt,
          opts
        )
      else
        case Handbean.Agent.OperationReceipt.complete(
               {:message, state.session_id},
               opts[:request_id],
               receipt
             ) do
          :ok -> {:ok, nil}
          {:error, reason} -> {:error, reason}
        end
      end

    case result do
      {:ok, entry} ->
        item = put_persisted_id(item, entry)
        {:reply, :ok, %{state | deliver_as => :queue.in(item, queue), size: state.size + 1}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:drain, deliver_as}, _from, state) do
    queue = Map.fetch!(state, deliver_as)
    messages = :queue.to_list(queue) |> Enum.map(& &1.message)
    count = length(messages)

    {:reply, messages, %{state | deliver_as => :queue.new(), size: state.size - count}}
  end

  def handle_call(:seal, _from, state) do
    {:reply, :ok, %{state | sealed?: true}}
  end

  def handle_call(:take_pending_or_seal, _from, %{size: 0} = state) do
    {:reply, :sealed, %{state | sealed?: true}}
  end

  def handle_call(:take_pending_or_seal, _from, state) do
    pending = %{
      steer: Enum.map(:queue.to_list(state.steer), & &1.message),
      follow_up: Enum.map(:queue.to_list(state.follow_up), & &1.message)
    }

    {:reply, {:pending, pending},
     %{state | steer: :queue.new(), follow_up: :queue.new(), size: 0}}
  end

  def handle_call(:has_pending?, _from, state) do
    {:reply, state.size > 0, state}
  end

  def handle_call(:get_messages, _from, state) do
    steer_messages = :queue.to_list(state.steer)
    follow_up_messages = :queue.to_list(state.follow_up)
    messages = steer_messages ++ follow_up_messages
    {:reply, messages, state}
  end

  def handle_call({:delete_message, message_id}, _from, state) do
    steer_list = :queue.to_list(state.steer)
    follow_up_list = :queue.to_list(state.follow_up)

    {deleted_steer, new_steer_list} = Enum.split_with(steer_list, &(&1.message.id == message_id))

    {deleted_follow_up, new_follow_up_list} =
      Enum.split_with(follow_up_list, &(&1.message.id == message_id))

    deleted_count = length(deleted_steer) + length(deleted_follow_up)

    if deleted_count > 0 do
      case Handbean.ConversationTranscriptStore.delete(state.session_id, message_id) do
        :ok ->
          new_state = %{
            state
            | steer: :queue.from_list(new_steer_list),
              follow_up: :queue.from_list(new_follow_up_list),
              size: max(0, state.size - deleted_count)
          }

          {:reply, {:ok, deleted_count}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, owner, _reason}, %{owner: owner} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | sealed?: true}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp put_persisted_id(item, %{"id" => id}) when is_binary(id),
    do: %{item | message: %{item.message | id: id}}

  defp put_persisted_id(item, _entry), do: item

  defp normalize_message(%Message{} = message, deliver_as, opts) do
    id = Keyword.get(opts, :message_id) || message.id || unique_id("msg-user")
    message = %{message | id: id}
    %{message: message, metadata: metadata(deliver_as, opts)}
  end

  defp normalize_message(content, deliver_as, opts) when is_binary(content) do
    id = Keyword.get(opts, :message_id) || unique_id("msg-user")

    %{
      message: %Message{role: :user, content: content, id: id},
      metadata: metadata(deliver_as, opts)
    }
  end

  defp metadata(deliver_as, opts) do
    %{
      source: Keyword.get(opts, :source, :user),
      deliver_as: deliver_as,
      inserted_at: DateTime.utc_now()
    }
  end
end
