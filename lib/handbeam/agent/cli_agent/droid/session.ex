defmodule Handbeam.Agent.CliAgent.Droid.Session do
  @moduledoc """
  Owner of one Droid exec process.

  The process stays up across turns. A turn ends when Droid returns to idle
  after having worked, or when a permission / ask-user request cannot be
  answered without auto-approving. Those requests are written back only when
  the caller supplies an explicit decision.
  """

  use GenServer

  alias Handbeam.Agent.CliAgent.Droid.{Codec, Transport}
  alias Handbeam.Agent.CliAgent.Event

  @init_timeout 15_000

  defstruct [
    :port,
    :os_pid,
    :cwd,
    :session_id,
    :owner,
    :buffer,
    :pending,
    :turn,
    :listener,
    :events,
    :turn_state,
    status: :starting
  ]

  @type handle :: %{
          port: port(),
          os_pid: pos_integer() | nil,
          cwd: String.t(),
          session_id: String.t() | nil,
          owner: pid()
        }

  @doc "Start the process and initialize or load the Droid session."
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

  @doc "Ask Droid for its model catalog. Requires a process started for that purpose."
  @spec list_models(handle(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_models(session, opts \\ [])

  def list_models(%{pid: pid}, opts) when is_pid(pid) do
    list_models(pid, opts)
  end

  def list_models(%{owner: pid}, opts) when is_pid(pid) do
    list_models(pid, opts)
  end

  def list_models(pid, opts) when is_pid(pid) do
    GenServer.call(pid, {:list_models, opts}, Keyword.get(opts, :timeout, @init_timeout))
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc "Send one user turn. `on_event` sees normalized events only."
  @spec send_message(pid(), String.t(), (Event.t() -> term())) ::
          {:ok, map(), [Event.t()]} | {:error, term()}
  def send_message(pid, text, on_event, decision \\ nil)
      when is_pid(pid) and is_function(on_event, 1) do
    GenServer.call(pid, {:send_message, text, on_event, decision}, :infinity)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc "Interrupt the current turn. The process stays open."
  @spec interrupt(pid()) :: :ok | {:error, term()}
  def interrupt(pid) when is_pid(pid) do
    GenServer.call(pid, :interrupt, 5_000)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc "Update model or reasoning on the active session."
  @spec update_model(pid(), keyword()) :: :ok | {:error, term()}
  def update_model(pid, opts) when is_pid(pid) do
    GenServer.call(pid, {:update_model, opts}, @init_timeout)
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
          pending: %{},
          events: [],
          turn_state: %{seen_work: false, done: false, session_id: nil},
          owner: self()
        }

        {:ok, state, {:continue, {:handshake, opts}}}

      {:error, reason} ->
        {:ok, %__MODULE__{status: :failed, pending: %{failure: reason}}}
    end
  end

  @impl true
  def handle_continue({:handshake, opts}, state) do
    if Keyword.get(opts, :purpose) == :list_models do
      {:noreply, %{state | status: :ready}}
    else
      id = next_id()

      request =
        case Keyword.get(opts, :session_id) do
          session_id when is_binary(session_id) and session_id != "" ->
            Codec.load_session(id, session_id)

          _ ->
            Codec.initialize_session(id, state.cwd, opts)
        end

      {:noreply, write_request(state, id, request, :handshake)}
    end
  end

  @impl true
  def handle_call(:await_ready, from, %{status: :ready} = state) do
    GenServer.reply(from, {:ok, handle(state)})
    {:noreply, state}
  end

  def handle_call(:await_ready, _from, %{status: :failed} = state) do
    {:stop, :normal, {:error, state.pending[:failure] || :protocol}, state}
  end

  def handle_call(:await_ready, from, state) do
    {:noreply, put_in(state.pending[:waiter], from)}
  end

  def handle_call({:list_models, opts}, from, %{status: :ready} = state) do
    id = next_id()
    request = Codec.list_models(id, opts)
    {:noreply, write_request(state, id, request, {:list_models, from})}
  end

  def handle_call({:list_models, _opts}, _from, state) do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:send_message, text, on_event, decision}, from, %{status: :ready} = state) do
    id = next_id()
    request = Codec.add_user_message(id, text)

    state = %{
      state
      | status: :in_turn,
        listener: on_event,
        events: [],
        turn_state: %{seen_work: false, done: false, session_id: state.session_id},
        pending: Map.put(state.pending, :decision, decision)
    }

    {:noreply, write_request(state, id, request, {:turn, from})}
  end

  def handle_call({:send_message, _text, _on_event, _decision}, _from, state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(:interrupt, from, state) do
    id = next_id()
    {:noreply, write_request(state, id, Codec.interrupt_session(id), {:interrupt, from})}
  end

  def handle_call({:update_model, opts}, from, %{status: :ready} = state) do
    if Keyword.get(opts, :model) == nil and Keyword.get(opts, :reasoning_effort) == nil do
      {:reply, {:error, :model_required}, state}
    else
      id = next_id()
      request = Codec.update_session_settings(id, opts)
      {:noreply, write_request(state, id, request, {:settings, from})}
    end
  end

  def handle_call({:update_model, _opts}, _from, %{status: :in_turn} = state) do
    {:reply, {:error, :apply_on_next_start}, state}
  end

  def handle_call({:update_model, _opts}, _from, state) do
    {:reply, {:error, :not_ready}, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {:noreply, ingest(state, data)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    state = fail(state, {:exit, status})
    {:noreply, %{state | port: nil, status: :closed}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Transport.close(state.port, state.os_pid)
    :ok
  end

  defp write_request(state, id, request, waiter) do
    case Transport.write(state.port, Codec.encode_line(request)) do
      :ok ->
        pending = Map.put(state.pending, id, waiter)
        %{state | pending: pending}

      {:error, reason} ->
        fail(state, reason)
    end
  end

  defp ingest(state, {:eol, line}) when is_binary(line),
    do: take_line(state, state.buffer <> line)

  defp ingest(state, {:noeol, chunk}) when is_binary(chunk),
    do: %{state | buffer: state.buffer <> chunk}

  defp ingest(state, data) when is_binary(data), do: ingest_binary(state, data)

  defp ingest_binary(state, data) do
    {lines, rest} = split_lines(state.buffer <> data)
    Enum.reduce(lines, %{state | buffer: rest}, &take_line(&2, &1))
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")

    case List.pop_at(parts, -1) do
      {rest, lines} -> {lines, rest}
    end
  end

  defp take_line(state, line) do
    case Codec.decode_line(line) do
      {:ok, message} -> apply_message(state, message)
      :ignore -> state
    end
  end

  defp apply_message(state, message) do
    {kind, payload, turn_state} = Codec.classify(message, state.turn_state)
    state = %{state | turn_state: turn_state}

    case kind do
      :response -> handle_response(state, payload)
      :server_request -> handle_server_request(state, payload)
      {:event, event} -> emit(state, event)
      :ignore -> state
    end
  end

  defp handle_response(state, message) do
    id = to_string(message["id"])

    waiter =
      Map.get(state.pending, id) || Map.get(state.pending, message["id"]) ||
        handshake_waiter(state, message) || list_models_waiter(state, message)

    pending = Map.drop(state.pending, [id, message["id"]])
    state = %{state | pending: pending}

    case waiter do
      :handshake -> finish_handshake(state, message)
      {:list_models, from} -> finish_models(state, from, message)
      {:turn, from} -> ack_turn(state, from, message)
      {:interrupt, from} -> finish_interrupt(state, from, message)
      {:settings, from} -> finish_settings(state, from, message)
      _ -> state
    end
  end

  defp list_models_waiter(state, message) do
    result = message["result"] || %{}

    Enum.find_value(state.pending, fn
      {_id, {:list_models, from}} ->
        if is_list(result["models"]) or result == %{}, do: {:list_models, from}

      _ ->
        nil
    end)
  end

  defp handshake_waiter(state, message) do
    result = message["result"] || %{}

    if Enum.member?(Map.values(state.pending), :handshake) and
         (is_binary(result["sessionId"]) or is_map(message["error"])) do
      :handshake
    end
  end

  defp finish_handshake(state, message) do
    case Codec.session_id(message) do
      {:ok, session_id} ->
        state = %{
          state
          | status: :ready,
            session_id: session_id,
            pending: drop_handshake(state.pending)
        }

        reply_waiter(state, {:ok, handle(state)})

      {:error, reason} ->
        fail(%{state | pending: Map.put(state.pending, :failure, reason)}, reason)
    end
  end

  defp finish_models(state, from, message) do
    GenServer.reply(from, Codec.models(message))
    state
  end

  defp ack_turn(state, from, %{"error" => error}) do
    GenServer.reply(from, {:error, {:protocol, Codec.session_id(%{"error" => error}) |> elem(1)}})
    %{state | status: :ready, listener: nil}
  end

  defp ack_turn(state, _from, _message), do: state

  defp finish_interrupt(state, from, %{"error" => error}) do
    GenServer.reply(from, {:error, {:protocol, error["message"] || "interrupt failed"}})
    state
  end

  defp finish_interrupt(state, from, _message) do
    GenServer.reply(from, :ok)
    state
  end

  defp finish_settings(state, from, %{"error" => error}) do
    GenServer.reply(from, {:error, {:protocol, error["message"] || "settings failed"}})
    state
  end

  defp finish_settings(state, from, _message) do
    GenServer.reply(from, :ok)
    state
  end

  defp handle_server_request(state, {kind, message}) do
    event = server_event(kind, message)
    reply_to = self()
    user_listener = state.listener

    answering = fn delivered ->
      send(reply_to, {:cli_agent_reply, listener_reply(user_listener, delivered)})
    end

    state = emit(%{state | listener: answering}, event)
    reply = await_reply()
    state = %{state | listener: user_listener}

    case reply_decision(kind, message, reply, state.pending[:decision]) do
      {:ok, result} ->
        state = replace_last(state, answered_event(event, kind, result))
        write_request(state, next_id(), Codec.respond(message["id"], result), :server_reply)

      {:error, _reason} ->
        finish_turn(state, :ok)
    end
  end

  defp listener_reply(listener, event) when is_function(listener, 1) do
    try do
      case listener.(event) do
        reply when is_tuple(reply) or reply == :cancel -> reply
        _ -> nil
      end
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  defp listener_reply(_listener, _event), do: nil

  defp await_reply do
    receive do
      {:cli_agent_reply, reply} -> reply
    after
      0 -> nil
    end
  end

  defp reply_decision(kind, message, reply, attached) do
    case reply do
      {:permission, selected} when is_binary(selected) ->
        decision_for(:permission, message, {:permission, selected})

      {:ask_user, answers} when is_list(answers) ->
        decision_for(:ask_user, message, {:ask_user, answers})

      :cancel ->
        {:error, unanswered(kind)}

      _ ->
        decision_for(kind, message, attached)
    end
  end

  defp decision_for(:permission, message, {:permission, selected}) when is_binary(selected) do
    if offered?(message, selected) do
      {:ok, Codec.permission_result(selected)}
    else
      {:error, :permission_unanswered}
    end
  end

  defp decision_for(:permission, _message, _), do: {:error, :permission_unanswered}

  defp decision_for(:ask_user, _message, {:ask_user, answers}) when is_list(answers) do
    {:ok, Codec.ask_user_result(answers, false)}
  end

  defp decision_for(:ask_user, _message, :cancel), do: {:ok, Codec.ask_user_result([], true)}
  defp decision_for(:ask_user, _message, _), do: {:error, :ask_user_unanswered}

  defp unanswered(:permission), do: :permission_unanswered
  defp unanswered(:ask_user), do: :ask_user_unanswered

  defp offered?(message, selected) do
    options = get_in(message, ["params", "options"]) || []
    Enum.any?(options, &(&1["value"] == selected))
  end

  defp server_event(:permission, message) do
    {:permission_request,
     %{
       id: to_string(message["id"]),
       tools: Enum.map(get_in(message, ["params", "toolUses"]) || [], &public_tool/1),
       options: public_options(message)
     }}
  end

  defp server_event(:ask_user, message) do
    {:ask_user,
     %{
       id: to_string(message["id"]),
       questions: get_in(message, ["params", "questions"]) || []
     }}
  end

  defp answered_event({:permission_request, request}, :permission, %{"selectedOption" => selected}) do
    {:permission_request, Map.put(request, :selected, selected)}
  end

  defp answered_event({:ask_user, request}, :ask_user, result) do
    {:ask_user, Map.merge(request, %{answers: result["answers"], cancelled: result["cancelled"]})}
  end

  defp answered_event(event, _kind, _result), do: event

  defp public_options(message) do
    (get_in(message, ["params", "options"]) || [])
    |> Enum.map(fn option ->
      %{"label" => option["label"], "value" => option["value"]}
    end)
    |> Enum.filter(&is_binary(&1["value"]))
  end

  defp replace_last(%{events: []} = state, event), do: %{state | events: [event]}

  defp replace_last(state, event) do
    %{state | events: List.replace_at(state.events, -1, event)}
  end

  defp public_tool(%{"toolUse" => tool}) when is_map(tool) do
    %{
      name: tool["title"] || tool["name"] || "unknown",
      id: tool["id"],
      input: tool["input"] || %{}
    }
  end

  defp public_tool(_), do: %{name: "unknown", id: nil}

  defp emit(state, event) do
    if Event.normalized?(event) and is_function(state.listener, 1) do
      state.listener.(event)
    end

    state = %{state | events: state.events ++ [event]}

    if match?({:turn_end, _}, event) do
      finish_turn(state, :ok)
    else
      state
    end
  end

  defp finish_turn(state, :ok) do
    case pending_turn(state) do
      {from, pending} ->
        GenServer.reply(from, {:ok, public_session(state), state.events})
        %{state | status: :ready, listener: nil, events: [], pending: pending}

      nil ->
        %{state | status: :ready, listener: nil}
    end
  end

  defp pending_turn(state) do
    Enum.find_value(state.pending, fn
      {_id, {:turn, from}} -> {from, drop_turn(state.pending)}
      _ -> nil
    end)
  end

  defp drop_handshake(pending) do
    pending
    |> Enum.reject(fn {_id, waiter} -> waiter == :handshake end)
    |> Map.new()
  end

  defp drop_turn(pending) do
    pending
    |> Enum.reject(fn
      {:decision, _value} -> true
      {_id, {:turn, _from}} -> true
      _ -> false
    end)
    |> Map.new()
  end

  defp reply_waiter(state, reply) do
    case Map.pop(state.pending, :waiter) do
      {from, pending} when is_tuple(from) ->
        GenServer.reply(from, reply)
        %{state | pending: pending}

      {nil, _pending} ->
        state
    end
  end

  defp fail(state, reason) do
    state = %{state | status: :failed, pending: Map.put(state.pending, :failure, reason)}

    state
    |> reply_waiter({:error, reason})
    |> reply_outstanding(reason)
  end

  defp reply_outstanding(state, reason) do
    Enum.each(state.pending, fn
      {_id, {:list_models, from}} -> GenServer.reply(from, {:error, reason})
      {_id, {:turn, from}} -> GenServer.reply(from, {:error, reason})
      {_id, {:interrupt, from}} -> GenServer.reply(from, {:error, reason})
      {_id, {:settings, from}} -> GenServer.reply(from, {:error, reason})
      _ -> :ok
    end)

    state
  end

  defp handle(state), do: public_session(state)

  defp public_session(state) do
    alias Handbeam.Agent.CliAgent.Session, as: CliSession

    %CliSession{
      backend: "droid",
      cwd: state.cwd,
      session_id: state.session_id,
      pid: state.owner,
      port: state.port,
      private: %{owner: state.owner, os_pid: state.os_pid}
    }
  end

  defp next_id, do: Integer.to_string(System.unique_integer([:positive]))
end
