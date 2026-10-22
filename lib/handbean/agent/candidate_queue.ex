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

  def begin_initial(server, opts) do
    request_id = Keyword.get(opts, :request_id)

    if request_id in [nil, ""] do
      :ok
    else
      GenServer.call(server, {
        :begin_initial,
        request_id,
        Keyword.fetch!(opts, :message_id),
        %{action: :started, run_id: Keyword.fetch!(opts, :run_id)}
      })
    end
  end

  def commit_initial(server, opts) do
    initial_transition(server, :commit_initial, opts)
  end

  def abort_initial(server, opts) do
    initial_transition(server, :abort_initial, opts)
  end

  defp initial_transition(server, transition, opts) do
    request_id = Keyword.get(opts, :request_id)

    if request_id in [nil, ""] do
      :ok
    else
      GenServer.call(server, {transition, request_id, Keyword.fetch!(opts, :message_id)})
    end
  end

  def drain_steer(server), do: GenServer.call(server, {:drain, :steer})
  def drain_follow_up(server), do: GenServer.call(server, {:drain, :follow_up})
  def seal(server), do: GenServer.call(server, :seal)
  def take_pending_or_seal(server), do: GenServer.call(server, :take_pending_or_seal)
  def take_next_or_seal(server), do: GenServer.call(server, :take_next_or_seal)
  def has_pending?(server), do: GenServer.call(server, :has_pending?)
  def get_messages(server, timeout \\ 5_000), do: GenServer.call(server, :get_messages, timeout)

  def delete_message(server, message_id),
    do: GenServer.call(server, {:delete_message, message_id})

  def promote_message(server, message_id) do
    GenServer.call(server, {:promote_message, message_id})
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] ->
      {:error, :not_found}
  end

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
       size: 0,
       accepted_requests: %{}
     }}
  end

  @impl true
  def handle_call({:begin_initial, request_id, message_id, receipt}, _from, state) do
    case accepted_request(state, request_id, message_id) do
      :new ->
        initial = %{message_id: message_id, status: :pending, receipt: receipt, waiters: []}
        {:reply, :ok, put_in(state.accepted_requests[request_id], initial)}

      {:duplicate, _initial} ->
        {:reply, :ok, state}

      :conflict ->
        {:reply, {:error, :idempotency_conflict}, state}
    end
  end

  def handle_call({:commit_initial, request_id, message_id}, _from, state) do
    case accepted_request(state, request_id, message_id) do
      {:duplicate, %{status: :pending} = initial} ->
        Enum.each(initial.waiters, &GenServer.reply(&1, :ok))
        initial = %{initial | status: :accepted, waiters: []}
        {:reply, :ok, put_in(state.accepted_requests[request_id], initial)}

      {:duplicate, %{status: :accepted}} ->
        {:reply, :ok, state}

      :new ->
        {:reply, {:error, :not_pending}, state}

      :conflict ->
        {:reply, {:error, :idempotency_conflict}, state}
    end
  end

  def handle_call({:abort_initial, request_id, message_id}, _from, state) do
    case accepted_request(state, request_id, message_id) do
      {:duplicate, %{status: :pending} = initial} ->
        Enum.each(initial.waiters, &GenServer.reply(&1, {:error, :sealed}))
        {:reply, :ok, update_in(state.accepted_requests, &Map.delete(&1, request_id))}

      _other ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:enqueue, _message, deliver_as, _opts}, _from, state)
      when deliver_as not in @deliver_as do
    {:reply, {:error, :invalid_deliver_as}, state}
  end

  def handle_call({:enqueue, message, deliver_as, opts}, from, state) do
    item = normalize_message(message, deliver_as, opts)

    case accepted_request(state, opts[:request_id], item.message.id) do
      {:duplicate, %{status: :pending} = initial} ->
        initial = %{initial | waiters: [from | initial.waiters]}
        {:noreply, put_in(state.accepted_requests[opts[:request_id]], initial)}

      {:duplicate, %{status: :accepted, receipt: receipt}} ->
        case complete_receipt(state.session_id, opts[:request_id], receipt) do
          :ok -> {:reply, :ok, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      :conflict ->
        {:reply, {:error, :idempotency_conflict}, state}

      :new when state.sealed? ->
        {:reply, {:error, :sealed}, state}

      :new when state.size >= state.max_size ->
        {:reply, {:error, :queue_full}, state}

      :new ->
        queue = Map.fetch!(state, deliver_as)
        receipt = %{action: :enqueued, run_id: opts[:run_id]}

        # Seal/capacity checks and persistence share the queue's acceptance gate.
        # A rejected candidate must not appear as an accepted inbound transcript.
        result = persist_candidate(state.session_id, item, receipt, opts)

        case result do
          {:ok, entry} ->
            item = put_persisted_id(item, entry)

            state = %{
              state
              | deliver_as => :queue.in(item, queue),
                size: state.size + 1,
                accepted_requests:
                  remember_request(
                    state.accepted_requests,
                    opts[:request_id],
                    item.message.id,
                    receipt
                  )
            }

            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
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

  def handle_call(:take_next_or_seal, _from, %{size: 0} = state) do
    {:reply, :sealed, %{state | sealed?: true}}
  end

  def handle_call(:take_next_or_seal, _from, state) do
    {deliver_as, item, state} = take_next(state)
    {:reply, {:pending, deliver_as, item.message}, %{state | size: state.size - 1}}
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

  def handle_call({:promote_message, _message_id}, _from, %{sealed?: true} = state) do
    {:reply, {:error, :not_found}, state}
  end

  def handle_call({:promote_message, message_id}, _from, state) do
    steer_list = :queue.to_list(state.steer)
    follow_up_list = :queue.to_list(state.follow_up)

    cond do
      Enum.any?(steer_list, &(&1.message.id == message_id)) ->
        {:reply, {:ok, %{deliver_as: :steer}}, state}

      true ->
        {promoted, remaining} = Enum.split_with(follow_up_list, &(&1.message.id == message_id))

        if promoted == [] do
          {:reply, {:error, :not_found}, state}
        else
          case persist_promotion(state.session_id, promoted) do
            :ok ->
              promoted =
                Enum.map(promoted, fn item ->
                  put_in(item.metadata.deliver_as, :steer)
                end)

              new_state = %{
                state
                | steer: Enum.reduce(promoted, state.steer, &:queue.in/2),
                  follow_up: :queue.from_list(remaining)
              }

              {:reply, {:ok, %{deliver_as: :steer}}, new_state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        end
    end
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

  defp accepted_request(_state, request_id, _message_id) when request_id in [nil, ""], do: :new

  defp accepted_request(state, request_id, message_id) do
    case state.accepted_requests do
      %{^request_id => %{message_id: ^message_id} = accepted} -> {:duplicate, accepted}
      %{^request_id => _other} -> :conflict
      _ -> :new
    end
  end

  defp remember_request(requests, request_id, _message_id, _receipt)
       when request_id in [nil, ""],
       do: requests

  defp remember_request(requests, request_id, message_id, receipt) do
    Map.put(requests, request_id, %{
      message_id: message_id,
      status: :accepted,
      receipt: receipt,
      waiters: []
    })
  end

  defp persist_candidate(session_id, item, receipt, opts) do
    if Keyword.get(opts, :persist_candidate?, false) do
      Handbean.Agent.TranscriptPersistence.accept_inbound(
        session_id,
        item.message,
        receipt,
        opts
      )
    else
      case complete_receipt(session_id, opts[:request_id], receipt) do
        :ok -> {:ok, nil}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp complete_receipt(session_id, request_id, receipt) do
    Handbean.Agent.OperationReceipt.complete({:message, session_id}, request_id, receipt)
  end

  defp take_next(state) do
    case :queue.out(state.steer) do
      {{:value, item}, steer} ->
        {:steer, item, %{state | steer: steer}}

      {:empty, _steer} ->
        {{:value, item}, follow_up} = :queue.out(state.follow_up)
        {:follow_up, item, %{state | follow_up: follow_up}}
    end
  end

  defp persist_promotion(session_id, items) do
    if Enum.any?(items, &Map.get(&1.metadata, :persisted?, false)) do
      case Handbean.ConversationTranscriptStore.update(session_id, hd(items).message.id, %{
             "delivery" => "steer",
             "interrupts_work" => true
           }) do
        {:ok, _entry} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

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
      inserted_at: DateTime.utc_now(),
      persisted?: Keyword.get(opts, :persist_candidate?, false)
    }
  end
end
