defmodule Handbean.Agent.CliAgent.Grok.Session do
  @moduledoc """
  Owner of one Grok ACP process.

  The process stays up across turns. A permission request stops the turn
  unless the caller already supplied an explicit option id. This module never
  approves by default.
  """

  use GenServer

  alias Handbean.Agent.CliAgent.Grok.{Codec, Transport}

  @init_timeout 20_000
  @turn_timeout 120_000

  defstruct [
    :port,
    :os_pid,
    :cwd,
    :session_id,
    :buffer,
    :pending,
    :listener,
    :events,
    next_id: 1,
    status: :starting
  ]

  @type handle :: %{
          owner: pid(),
          cwd: String.t(),
          session_id: String.t() | nil
        }

  @spec start(keyword()) :: {:ok, handle()} | {:error, term()}
  def start(opts) do
    case GenServer.start_link(__MODULE__, opts) do
      {:ok, pid} ->
        timeout = Keyword.get(opts, :timeout, @init_timeout)

        case GenServer.call(pid, :await_ready, timeout) do
          {:ok, handle} ->
            {:ok, handle}

          {:error, reason} ->
            stop(pid)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec send_message(pid(), String.t(), (term() -> term()), term()) ::
          {:ok, handle(), [term()]} | {:error, term()}
  def send_message(pid, text, on_event, decision) when is_pid(pid) do
    GenServer.call(pid, {:send_message, text, on_event, decision}, @turn_timeout)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec interrupt(pid()) :: :ok | {:error, term()}
  def interrupt(pid) when is_pid(pid) do
    GenServer.call(pid, :interrupt, 5_000)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    case Transport.open(opts) do
      {:ok, port, os_pid} ->
        state = %__MODULE__{
          port: port,
          os_pid: os_pid,
          cwd: Keyword.fetch!(opts, :cwd),
          buffer: "",
          pending: %{session_id: Keyword.get(opts, :session_id)},
          events: []
        }

        {:ok, state, {:continue, :handshake}}

      {:error, reason} ->
        {:ok, %__MODULE__{status: :failed, pending: %{failure: reason}}}
    end
  end

  @impl true
  def handle_continue(:handshake, state) do
    {:noreply, write(state, Codec.initialize(next_id(state)), :initialize)}
  end

  @impl true
  def handle_call(:await_ready, _from, %{status: :ready} = state) do
    {:reply, {:ok, handle(state)}, state}
  end

  def handle_call(:await_ready, _from, %{status: :failed} = state) do
    {:stop, :normal, {:error, state.pending[:failure] || :protocol}, state}
  end

  def handle_call(:await_ready, from, state) do
    {:noreply, put_in(state.pending[:waiter], from)}
  end

  def handle_call({:send_message, text, on_event, decision}, from, %{status: :ready} = state) do
    state = %{
      state
      | status: :in_turn,
        listener: on_event,
        events: [],
        pending: Map.put(state.pending, :decision, decision)
    }

    {:noreply, write(state, Codec.prompt(next_id(state), state.session_id, text), {:turn, from})}
  end

  def handle_call({:send_message, _, _, _}, _from, state), do: {:reply, {:error, :busy}, state}

  def handle_call(:interrupt, _from, %{session_id: id} = state) when is_binary(id) do
    case Transport.write(state.port, Codec.encode_line(Codec.cancel(id))) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:interrupt, _from, state), do: {:reply, {:error, :not_ready}, state}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state),
    do: {:noreply, ingest(state, data)}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:noreply, %{fail(state, {:exit, status}) | port: nil, status: :closed}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Transport.close(state.port, state.os_pid)
    :ok
  end

  defp write(state, request, waiter) do
    id = request["id"]

    case Transport.write(state.port, Codec.encode_line(request)) do
      :ok -> %{state | next_id: state.next_id + 1, pending: Map.put(state.pending, id, waiter)}
      {:error, reason} -> fail(state, reason)
    end
  end

  defp next_id(state), do: state.next_id

  defp ingest(state, {:eol, line}), do: take_line(state, state.buffer <> line)
  defp ingest(state, {:noeol, chunk}), do: %{state | buffer: state.buffer <> chunk}
  defp ingest(state, data) when is_binary(data), do: ingest_binary(state, data)

  defp ingest_binary(state, data) do
    {lines, rest} = split_lines(state.buffer <> data)
    Enum.reduce(lines, %{state | buffer: rest}, &take_line(&2, &1))
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {rest, lines} = List.pop_at(parts, -1)
    {lines, rest}
  end

  defp take_line(state, line) do
    case Codec.decode_line(line) do
      {:ok, message} -> apply_message(state, message)
      :ignore -> state
    end
  end

  defp apply_message(state, message) do
    case Codec.classify(message) do
      {:response, response} -> apply_response(state, response)
      {:server_request, request} -> apply_permission(state, request)
      {:event, event} -> emit(state, event)
      :ignore -> state
    end
  end

  defp apply_response(state, response) do
    waiter = Map.get(state.pending, response["id"])
    pending = Map.delete(state.pending, response["id"])
    state = %{state | pending: pending}

    case waiter do
      :initialize -> continue_handshake(state, response)
      :session -> finish_handshake(state, response)
      {:turn, from} -> finish_turn(state, from, response)
      _ -> state
    end
  end

  defp continue_handshake(state, response) do
    if is_map(response["error"]) do
      fail(state, {:protocol, response["error"]["message"] || :initialize})
    else
      request =
        case state.pending[:session_id] do
          id when is_binary(id) and id != "" -> Codec.load_session(next_id(state), id, state.cwd)
          _ -> Codec.new_session(next_id(state), state.cwd)
        end

      write(%{state | pending: Map.delete(state.pending, :session_id)}, request, :session)
    end
  end

  defp finish_handshake(state, response) do
    case Codec.session_id(response) do
      {:ok, id} -> ready(%{state | session_id: id, status: :ready})
      {:error, reason} -> fail(state, reason)
    end
  end

  defp finish_turn(state, from, response) do
    case Codec.stop_reason(response) do
      {:ok, reason} ->
        event = {:turn_end, %{stop_reason: reason, session_id: state.session_id}}
        state = emit(%{state | status: :ready}, event)
        GenServer.reply(from, {:ok, handle(state), Enum.reverse(state.events)})
        %{state | events: [], listener: nil}

      {:error, reason} ->
        GenServer.reply(from, {:error, reason})
        %{state | status: :ready, listener: nil}

      :pending ->
        GenServer.reply(from, {:error, :protocol})
        %{state | status: :ready, listener: nil}
    end
  end

  defp apply_permission(state, request) do
    event = {:permission_request, request}

    decision =
      cond do
        match?({:permission, selected} when is_binary(selected), state.pending[:decision]) ->
          state.pending[:decision]

        is_function(state.listener, 1) ->
          state.listener.(event)

        true ->
          nil
      end

    state = %{state | events: [event | state.events]}

    case decision do
      {:permission, selected} when is_binary(selected) ->
        reply_permission(state, Codec.permission_response(request.id, selected))

      _ ->
        reply_permission(state, Codec.permission_cancel(request.id))
    end
  end

  defp reply_permission(state, message) do
    case Transport.write(state.port, Codec.encode_line(message)) do
      :ok -> %{state | pending: Map.delete(state.pending, :decision)}
      {:error, reason} -> fail(state, reason)
    end
  end

  defp emit(state, event) do
    if is_function(state.listener, 1), do: state.listener.(event)
    %{state | events: [event | state.events]}
  end

  defp ready(state) do
    case state.pending[:waiter] do
      from when is_tuple(from) or is_pid(from) ->
        GenServer.reply(from, {:ok, handle(state)})
        %{state | pending: Map.delete(state.pending, :waiter)}

      _ ->
        state
    end
  end

  defp fail(state, reason) do
    state = emit(state, {:error, reason})

    case state.pending[:waiter] do
      from when is_tuple(from) or is_pid(from) -> GenServer.reply(from, {:error, reason})
      _ -> :ok
    end

    Enum.each(state.pending, fn
      {_id, {:turn, from}} -> GenServer.reply(from, {:error, reason})
      _ -> :ok
    end)

    %{state | status: :failed, pending: %{failure: reason}}
  end

  defp handle(state) do
    %{owner: self(), cwd: state.cwd, session_id: state.session_id}
  end
end
