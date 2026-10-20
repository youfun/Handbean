defmodule Handbean.Agent.Provider.Cursor.Session do
  @moduledoc """
  Supervised Cursor Run stream owner.

  Live HTTP/2 connections live here, not in `provider_state`. Tool results
  are written back on the same open stream. A disconnect after an in-flight
  tool request is treated as uncertain for that batch and is never retried.
  A later new run on a closed session is allowed.

  Checkpoints/blobs are protocol recovery data only. They are not a second
  conversation history and are not replayed as user transcript.

  Historical Handbean `tool_use` / `tool_result` blocks are encoded as MCP
  `McpToolCall` steps. Transcript does not carry Cursor-native tool oneofs,
  so history is not reconstructed as Shell/Read/etc.; live native requests
  still go through `Native` + ToolGuard.
  """

  use GenServer

  alias Handbean.Agent.Message

  alias Handbean.Agent.Provider.Cursor.{
    Blobs,
    CheckpointStore,
    Connect,
    Native,
    Proto,
    RequestEncoder,
    ToolResultEncoder,
    Transport
  }

  require Logger

  @heartbeat_ms 5_000
  @default_timeout 180_000

  defstruct [
    :id,
    :conversation_id,
    :cursor_conversation_id,
    :identity,
    :transport_mod,
    :transport,
    :blobs,
    :checkpoint,
    :phase,
    :caller,
    :caller_mon,
    :timeout_ref,
    :pending_execs,
    :held_execs,
    :acc,
    :tool_defs,
    :system_prompt,
    :on_chunk,
    :on_event,
    :generation,
    :heartbeat_ref,
    :receive_timeout,
    :timeout_ticket,
    :consumed_user_ids,
    :consumed_nil_users,
    :uncertain_run_id
  ]

  def via(id), do: {:via, Registry, {Handbean.CursorSessionRegistry, id}}

  def child_spec(opts) do
    id = Keyword.fetch!(opts, :id)

    %{
      id: {:cursor_session, id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def ensure(id, config) when is_binary(id) do
    case Registry.lookup(Handbean.CursorSessionRegistry, id) do
      [{pid, _}] -> {:ok, pid}
      [] -> Handbean.Agent.Provider.Cursor.Supervisor.start_session(id, config)
    end
  end

  def complete(id, messages, tool_defs, config, on_chunk) do
    timeout = Map.get(config, :receive_timeout, @default_timeout)

    with {:ok, _pid} <- ensure(id, config) do
      GenServer.call(via(id), {:complete, messages, tool_defs, config, on_chunk}, timeout + 5_000)
    end
  end

  def close(id) when is_binary(id) do
    case Registry.lookup(Handbean.CursorSessionRegistry, id) do
      [{pid, _}] -> GenServer.call(pid, :close, 5_000)
      [] -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  def stop_for_conversation(conversation_id) when is_binary(conversation_id) do
    close(conversation_id)
  end

  def stop_for_conversation(_), do: :ok

  def alive?(id) do
    match?([{_pid, _}], Registry.lookup(Handbean.CursorSessionRegistry, id))
  end

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    config = Keyword.get(opts, :config, %{})

    persisted =
      case CheckpointStore.load(id) do
        {:ok, data} -> data
        :error -> %{}
      end

    Process.flag(:trap_exit, true)

    {:ok,
     %__MODULE__{
       id: id,
       conversation_id: config[:conversation_id] || id,
       cursor_conversation_id: persisted[:cursor_conversation_id] || cursor_conversation_id(id),
       identity: identity(config, id),
       transport_mod: config[:cursor_transport] || Transport,
       transport: nil,
       blobs: persisted[:blobs] || Blobs.new(),
       checkpoint: persisted[:checkpoint],
       phase: :idle,
       caller: nil,
       caller_mon: nil,
       timeout_ref: nil,
       pending_execs: [],
       held_execs: [],
       acc: empty_acc(),
       tool_defs: [],
       system_prompt: config[:system_prompt],
       on_chunk: nil,
       on_event: nil,
       generation: 0,
       heartbeat_ref: nil,
       consumed_user_ids: MapSet.new(),
       consumed_nil_users: 0,
       uncertain_run_id: nil
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       phase: state.phase,
       identity: state.identity,
       pending: length(state.pending_execs),
       held: length(state.held_execs),
       uncertain_run_id: state.uncertain_run_id
     }, state}
  end

  def handle_call(:close, _from, state) do
    state = fail_running(state, "Cursor session closed")
    {:stop, :normal, :ok, state}
  end

  def handle_call({:complete, messages, tool_defs, config, on_chunk}, from, state) do
    incoming = identity(config, state.id)

    cond do
      same_uncertain_run?(state, incoming) ->
        {:reply, {:error, uncertain_error()}, state}

      incompatible?(state, config) or new_run_after_uncertain?(state, incoming) ->
        state = shutdown(%{state | uncertain_run_id: nil})

        start_new_run(messages, tool_defs, config, on_chunk, from, %{
          state
          | phase: :idle,
            pending_execs: [],
            held_execs: [],
            uncertain_run_id: nil,
            identity: incoming
        })

      state.phase == :awaiting_tools ->
        continue_with_results(messages, tool_defs, config, on_chunk, from, state)

      state.phase == :running and state.caller != nil ->
        {:reply, {:error, "Cursor session is already running"}, state}

      true ->
        start_new_run(messages, tool_defs, config, on_chunk, from, %{
          state
          | uncertain_run_id: nil
        })
    end
  end

  @impl true
  def handle_info({:DOWN, mon, :process, _pid, _reason}, %{caller_mon: mon} = state) do
    {:noreply, fail_running(%{state | caller: nil, caller_mon: nil}, "Cursor caller exited")}
  end

  def handle_info({:run_timeout, ticket}, %{timeout_ticket: ticket} = state) do
    {:noreply, fail_running(state, "Cursor run timed out")}
  end

  def handle_info({:run_timeout, _ticket}, state), do: {:noreply, state}

  def handle_info(:heartbeat, %{transport: nil} = state) do
    {:noreply, %{state | heartbeat_ref: nil}}
  end

  def handle_info(:heartbeat, %{phase: phase} = state)
      when phase not in [:running, :awaiting_tools] do
    {:noreply, %{state | heartbeat_ref: nil}}
  end

  def handle_info(:heartbeat, state) do
    state = schedule_heartbeat(state)

    case send_proto(state, Proto.encode_client(:heartbeat)) do
      {:ok, state} -> {:noreply, state}
      {:error, state, reason} -> {:noreply, fail_running(state, reason)}
    end
  end

  def handle_info(message, %{transport: transport, transport_mod: mod} = state)
      when not is_nil(transport) do
    case mod.handle_mint(transport, message) do
      {:ok, transport, frames} ->
        state =
          frames
          |> Enum.reduce(%{state | transport: transport}, &handle_frame/2)
          |> maybe_deliver_tools()

        {:noreply, state}

      {:error, transport, reason} ->
        {:noreply, fail_running(%{state | transport: transport}, reason)}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: shutdown(state)

  defp start_new_run(messages, tool_defs, config, on_chunk, from, state) do
    token = config[:api_key]
    model = config[:model]
    transport_mod = config[:cursor_transport] || state.transport_mod
    timeout = Map.get(config, :receive_timeout, @default_timeout)

    with :ok <- require_token(token),
         :ok <- require_model(model),
         {:ok, transport} <- connect_transport(transport_mod, config),
         {:ok, transport} <- open_run_transport(transport_mod, transport, token, config) do
      encoded =
        RequestEncoder.encode(
          messages,
          model,
          config,
          state.blobs,
          state.cursor_conversation_id
        )

      case transport_mod.send_message(transport, encoded.payload) do
        {:ok, transport} ->
          generation = state.generation + 1
          {pid, _} = from

          state = %{
            state
            | transport_mod: transport_mod,
              transport: transport,
              blobs: encoded.blobs,
              phase: :running,
              caller: from,
              caller_mon: Process.monitor(pid),
              pending_execs: [],
              held_execs: [],
              acc: empty_acc(),
              tool_defs: tool_defs,
              system_prompt: config[:system_prompt],
              on_chunk: on_chunk,
              on_event: Map.get(config, :on_event),
              identity: identity(config, state.id),
              generation: generation,
              consumed_user_ids: encoded.consumed_user_ids,
              consumed_nil_users: encoded.consumed_nil_users,
              uncertain_run_id: nil
          }

          state = send_user_actions(state, encoded.extra_users)

          {:noreply, schedule_heartbeat(arm_timeout(state, timeout))}

        {:error, transport, reason} ->
          transport_mod.close(transport)
          {:reply, {:error, reason}, %{state | transport: nil, phase: :idle}}
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:error, transport, reason} ->
        transport_mod.close(transport)
        {:reply, {:error, reason}, %{state | transport: nil, phase: :idle}}
    end
  end

  defp connect_transport(mod, config) do
    case mod.connect(transport_opts(config)) do
      {:ok, transport} -> {:ok, transport}
      {:error, reason} -> {:error, reason}
      {:error, _transport, reason} -> {:error, reason}
    end
  end

  defp open_run_transport(mod, transport, token, config) do
    case mod.open_run(transport, token, request_opts(config)) do
      {:ok, transport} -> {:ok, transport}
      {:error, reason} -> {:error, reason}
      {:error, transport, reason} -> {:error, transport, reason}
    end
  end

  defp continue_with_results(messages, tool_defs, config, on_chunk, from, state) do
    results = ToolResultEncoder.from_messages(messages)

    missing =
      Enum.reject(state.pending_execs, fn exec ->
        Map.has_key?(results, exec.tool_use_id)
      end)

    if missing != [] do
      {:reply, {:error, "Cursor tool results missing for open stream; not retrying"}, state}
    else
      Enum.reduce_while(state.pending_execs, {:ok, state}, fn exec, {:ok, state} ->
        {output, is_error?} = Map.fetch!(results, exec.tool_use_id)

        case send_exec_result(state, exec, output, is_error?) do
          {:ok, state} -> {:cont, {:ok, state}}
          {:error, _, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, state} ->
          generation = state.generation + 1

          state = %{
            state
            | phase: :running,
              caller: from,
              caller_mon: monitor_from(from),
              pending_execs: [],
              tool_defs: tool_defs,
              on_chunk: on_chunk,
              on_event: Map.get(config, :on_event),
              acc: %{state.acc | tool_calls: []},
              generation: generation
          }

          timeout = Map.get(config, :receive_timeout, @default_timeout)

          state =
            state
            |> send_new_user_actions(messages)
            |> arm_timeout(timeout)

          {:noreply, maybe_deliver_held(state)}

        {:error, reason} ->
          {:reply, {:error, reason}, fail_running(state, reason)}
      end
    end
  end

  defp send_exec_result(state, exec, output, is_error?) do
    exec
    |> ToolResultEncoder.client_payloads(output, is_error?)
    |> Enum.reduce_while({:ok, state}, fn payload, {:ok, state} ->
      case send_proto(state, payload) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, state, reason} -> {:halt, {:error, state, reason}}
      end
    end)
  end

  defp send_new_user_actions(state, messages) when is_list(messages) do
    send_user_actions(state, unconsumed_users(messages, state))
  end

  defp send_user_actions(state, users) when is_list(users) do
    Enum.reduce_while(users, state, fn msg, state ->
      action = RequestEncoder.user_action(msg)

      case send_proto(state, Proto.encode_client(%{conversation_action: action})) do
        {:ok, state} ->
          {:cont, mark_consumed(state, msg)}

        {:error, state, reason} ->
          {:halt, fail_running(state, reason)}
      end
    end)
  end

  defp maybe_deliver_held(%{held_execs: []} = state), do: state

  defp maybe_deliver_held(state) do
    acc = %{state.acc | tool_calls: state.held_execs}

    maybe_deliver_tools(%{
      state
      | acc: acc,
        pending_execs: state.pending_execs ++ state.held_execs,
        held_execs: []
    })
  end

  defp handle_frame(:done, %{acc: %{text: text}} = state) when text != "", do: maybe_finish(state)
  defp handle_frame(:done, state), do: fail_or_finish(state, "Cursor stream closed")

  defp handle_frame({:end_stream, payload}, state) do
    case Connect.end_stream_error(payload) do
      :ok -> maybe_finish(state)
      {:error, message} -> fail_running(state, message)
    end
  end

  defp handle_frame({:message, payload}, state) do
    state =
      case Proto.decode_server(payload) do
        {:interaction, event} ->
          handle_interaction(event, state)

        {:exec, exec} ->
          handle_exec(exec, state)

        {:checkpoint, bin} ->
          handle_checkpoint(bin, state)

        {:kv, kv} ->
          handle_kv(kv, state)

        {:interaction_query, query} ->
          handle_interaction_query(query, state)

        {:unknown, fields} ->
          fail_running(
            state,
            "Cursor sent unsupported server fields: #{inspect(Enum.map(fields, &elem(&1, 0)))}"
          )
      end

    slide_timeout(state)
  end

  defp handle_interaction({:text_delta, text}, state) do
    if is_function(state.on_chunk, 1) and text != "", do: state.on_chunk.(text)
    %{state | acc: Map.update!(state.acc, :text, &(&1 <> text))}
  end

  defp handle_interaction({:thinking_delta, text}, state) do
    if is_function(state.on_event, 1), do: state.on_event.({:thinking_delta, text})
    %{state | acc: Map.update!(state.acc, :thinking, &(&1 <> text))}
  end

  defp handle_interaction({:token_delta, n}, state) do
    %{state | acc: Map.update!(state.acc, :tokens, &(&1 + n))}
  end

  defp handle_interaction(:turn_ended, state), do: maybe_finish(state)
  defp handle_interaction(:heartbeat, state), do: state
  defp handle_interaction(:other, state), do: state

  defp handle_interaction_query(
         %{kind: kind, response_field: field} = query,
         state
       )
       when kind in [:web_search, :exa_search, :exa_fetch] do
    response = Proto.encode_interaction_approval(query.id, field)

    case send_proto(state, Proto.encode_client(%{interaction_response: response})) do
      {:ok, state} -> state
      {:error, state, reason} -> fail_running(state, reason)
    end
  end

  defp handle_interaction_query(%{kind: kind}, state) do
    fail_running(state, "Cursor sent an unsupported interaction query: #{kind}")
  end

  defp handle_exec(%{kind: :request_context} = exec, state) do
    tools = Enum.map(state.tool_defs, &tool_def/1)
    payload = Proto.encode_request_context(tools, state.system_prompt)
    msg = Proto.encode_exec_client(exec.id, exec.exec_id, 10, payload)

    case send_proto(state, Proto.encode_client(%{exec_client: msg})) do
      {:ok, state} -> state
      {:error, state, reason} -> fail_running(state, reason)
    end
  end

  defp handle_exec(%{kind: :start_grind_planning} = exec, state) do
    payload = Proto.encode_start_grind_planning_success()
    msg = Proto.encode_exec_client(exec.id, exec.exec_id, 36, payload)

    case send_proto(state, Proto.encode_client(%{exec_client: msg})) do
      {:ok, state} -> state
      {:error, state, reason} -> fail_running(state, reason)
    end
  end

  defp handle_exec(%{kind: :unknown}, state) do
    fail_running(state, "Cursor sent an unsupported exec request")
  end

  defp handle_exec(exec, state) do
    names = Enum.map(state.tool_defs, &tool_name/1)

    case Native.map(exec.kind, exec.payload, names) do
      :context ->
        handle_exec(%{exec | kind: :request_context}, state)

      {:mcp, payload} ->
        enqueue_tool(state, exec, payload[:tool_name] || payload[:name], payload[:args] || %{})

      {:tool, name, input} ->
        enqueue_tool(state, exec, name, input)

      {:reject, message} ->
        reject_exec(state, exec, message)
    end
  end

  defp reject_exec(state, exec, message) do
    payload =
      if exec.kind == :shell_stream do
        Proto.encode_shell_stream_rejected(message)
      else
        Proto.encode_native_rejected(exec.result_field, message)
      end

    msg = Proto.encode_exec_client(exec.id, exec.exec_id, exec.result_field, payload)

    case send_proto(state, Proto.encode_client(%{exec_client: msg})) do
      {:ok, state} -> state
      {:error, state, reason} -> fail_running(state, reason)
    end
  end

  defp enqueue_tool(state, exec, name, input) do
    tool_use_id = exec.payload[:tool_call_id] || "cursor-#{exec.id}-#{exec.exec_id}"

    pending = %{
      id: exec.id,
      exec_id: exec.exec_id,
      kind: exec.kind,
      result_field: exec.result_field,
      tool_use_id: tool_use_id,
      name: name,
      input: input
    }

    if state.phase == :awaiting_tools and state.caller == nil do
      %{state | held_execs: state.held_execs ++ [pending]}
    else
      acc = Map.update!(state.acc, :tool_calls, &(&1 ++ [pending]))
      %{state | acc: acc, pending_execs: state.pending_execs ++ [pending]}
    end
  end

  defp maybe_deliver_tools(%{caller: nil} = state), do: state
  defp maybe_deliver_tools(%{acc: %{tool_calls: []}} = state), do: state

  defp maybe_deliver_tools(%{phase: :running} = state) do
    # Deliver only after the current socket batch was drained. Additional
    # execs already in `acc.tool_calls` are included together.
    reply_tool_use(state)
  end

  defp maybe_deliver_tools(state), do: state

  defp handle_checkpoint(bin, state) do
    _ =
      CheckpointStore.save(state.id, %{
        checkpoint: bin,
        blobs: state.blobs,
        cursor_conversation_id: state.cursor_conversation_id
      })

    %{state | checkpoint: bin}
  end

  defp handle_kv({:get, id, blob_id}, state) do
    data = Blobs.fetch(state.blobs, blob_id || <<>>)
    msg = Proto.encode_kv_get_result(id, data)

    case send_proto(state, Proto.encode_client(%{kv_client: msg})) do
      {:ok, state} -> state
      {:error, state, reason} -> fail_running(state, reason)
    end
  end

  defp handle_kv({:set, id, blob_id, data}, state) do
    blobs =
      if is_binary(blob_id) and is_binary(data) do
        Blobs.put_id(state.blobs, blob_id, data)
      else
        state.blobs
      end

    msg = Proto.encode_kv_set_result(id)

    case send_proto(%{state | blobs: blobs}, Proto.encode_client(%{kv_client: msg})) do
      {:ok, state} -> state
      {:error, state, reason} -> fail_running(state, reason)
    end
  end

  defp handle_kv(_, state), do: state

  defp reply_tool_use(state) do
    calls =
      Enum.map(state.acc.tool_calls, fn exec ->
        %{type: "tool_use", id: exec.tool_use_id, name: exec.name, input: exec.input}
      end)

    text = state.acc.text

    content =
      if text == "" do
        calls
      else
        [%{type: "text", text: text} | calls]
      end

    response = %{
      stop_reason: :tool_use,
      messages: [Message.assistant_blocks(content)],
      usage: usage(state.acc),
      provider_state: %{cursor_session_id: state.id}
    }

    if state.caller, do: GenServer.reply(state.caller, {:ok, response})
    state = state |> drop_caller() |> clear_timeout()

    %{
      state
      | phase: :awaiting_tools,
        acc: %{state.acc | text: "", thinking: "", tokens: 0, tool_calls: []}
    }
  end

  defp finish_turn(state) do
    response = %{
      stop_reason: :end_turn,
      messages: [Message.assistant(state.acc.text)],
      usage: usage(state.acc),
      provider_state: %{cursor_session_id: state.id}
    }

    if state.caller, do: GenServer.reply(state.caller, {:ok, response})
    state = drop_caller(state)

    close_stream(%{
      state
      | phase: :idle,
        pending_execs: [],
        held_execs: [],
        uncertain_run_id: nil,
        acc: empty_acc()
    })
  end

  defp maybe_finish(%{acc: %{tool_calls: [_ | _]}} = state), do: reply_tool_use(state)

  defp maybe_finish(%{phase: :awaiting_tools, pending_execs: [_ | _]} = state) do
    fail_running(state, "Cursor ended the turn while tool results were still pending")
  end

  defp maybe_finish(%{phase: phase} = state) when phase in [:running, :awaiting_tools],
    do: finish_turn(state)

  defp maybe_finish(state), do: state

  defp fail_or_finish(%{acc: %{tool_calls: [_ | _]}} = state, _reason), do: reply_tool_use(state)
  defp fail_or_finish(state, reason), do: fail_running(state, reason)

  defp fail_running(state, reason) do
    uncertain? =
      state.pending_execs != [] or state.held_execs != [] or
        state.phase == :awaiting_tools or is_binary(state.uncertain_run_id)

    reason =
      if uncertain? do
        uncertain_error()
      else
        to_string(reason)
      end

    if state.caller, do: GenServer.reply(state.caller, {:error, reason})
    state = drop_caller(state)

    shutdown(%{
      state
      | phase: :idle,
        pending_execs: [],
        held_execs: [],
        uncertain_run_id:
          state.uncertain_run_id ||
            if(uncertain?, do: state.identity[:run_id] || state.id, else: nil)
    })
  end

  defp shutdown(state) do
    cancel_heartbeat(state)
    cancel_timeout(state)
    demonitor_caller(state)

    %{
      state
      | transport: cancel_transport(state),
        phase: :idle,
        heartbeat_ref: nil,
        timeout_ref: nil
    }
  end

  defp cancel_transport(%{transport: nil}), do: nil

  defp cancel_transport(state) do
    state.transport_mod.cancel(state.transport)
  rescue
    error ->
      Logger.warning("cursor transport cancel failed: #{Exception.message(error)}")
      nil
  end

  defp close_stream(state) do
    cancel_heartbeat(state)
    cancel_timeout(state)
    demonitor_caller(state)

    transport =
      if state.transport do
        state.transport_mod.cancel(state.transport)
      end

    %{state | transport: transport, heartbeat_ref: nil, timeout_ref: nil}
  end

  defp send_proto(%{transport: nil} = state, _payload),
    do: {:error, state, "Cursor stream is closed"}

  defp send_proto(state, payload) do
    case state.transport_mod.send_message(state.transport, payload) do
      {:ok, transport} -> {:ok, %{state | transport: transport}}
      {:error, transport, reason} -> {:error, %{state | transport: transport}, reason}
    end
  end

  defp unconsumed_users(messages, state) do
    {users, _} =
      Enum.reduce(messages, {[], 0}, fn
        %Message{role: :user} = msg, {acc, nil_seen} ->
          {consumed?, nil_seen} = consumed_user?(msg, nil_seen, state)

          if consumed? do
            {acc, nil_seen}
          else
            {acc ++ [msg], nil_seen}
          end

        _other, {acc, nil_seen} ->
          {acc, nil_seen}
      end)

    users
  end

  defp consumed_user?(%Message{id: id}, nil_seen, %{consumed_user_ids: ids}) when is_binary(id) do
    {MapSet.member?(ids, id), nil_seen}
  end

  defp consumed_user?(%Message{id: nil}, nil_seen, %{consumed_nil_users: consumed_nils}) do
    consumed? = nil_seen < consumed_nils
    {consumed?, nil_seen + 1}
  end

  defp mark_consumed(state, %Message{id: id}) when is_binary(id) do
    %{state | consumed_user_ids: MapSet.put(state.consumed_user_ids, id)}
  end

  defp mark_consumed(state, %Message{id: nil}) do
    %{state | consumed_nil_users: state.consumed_nil_users + 1}
  end

  defp same_uncertain_run?(%{uncertain_run_id: nil}, _incoming), do: false

  defp same_uncertain_run?(state, incoming) do
    case incoming[:run_id] do
      id when is_binary(id) -> id == state.uncertain_run_id
      _ -> not identity_changed?(state.identity, incoming)
    end
  end

  defp new_run_after_uncertain?(%{uncertain_run_id: nil}, _incoming), do: false

  defp new_run_after_uncertain?(state, incoming) do
    not same_uncertain_run?(state, incoming)
  end

  defp identity_changed?(current, incoming) do
    current.model != incoming.model or
      current.provider_key != incoming.provider_key or
      current.workspace != incoming.workspace or
      current.conversation_id != incoming.conversation_id or
      current.auth_generation != incoming.auth_generation
  end

  defp tool_def(def) do
    %{
      name: Handbean.Utils.SafeMap.get_any(def, :name, "name"),
      description: Handbean.Utils.SafeMap.get_any(def, :description, "description") || "",
      schema: Handbean.Utils.SafeMap.get_any(def, :input_schema, "input_schema") || %{}
    }
  end

  defp tool_name(def), do: Handbean.Utils.SafeMap.get_any(def, :name, "name")

  defp usage(acc) do
    %{
      input_tokens: 0,
      output_tokens: acc.tokens,
      unknown?: true
    }
  end

  defp empty_acc, do: %{text: "", thinking: "", tokens: 0, tool_calls: []}

  defp identity(config, fallback_id) do
    %{
      model: config[:model],
      provider_key: config[:provider_key] || config[:provider] || "cursor",
      workspace: config[:working_directory],
      conversation_id: config[:conversation_id] || fallback_id,
      run_id: config[:run_id],
      auth_generation: config[:auth_generation]
    }
  end

  defp incompatible?(%{identity: nil}, _config), do: false

  defp incompatible?(state, config) do
    incoming = identity(config, state.id)
    current = state.identity || incoming
    identity_changed?(current, incoming)
  end

  defp require_token(token) when is_binary(token) and token != "", do: :ok
  defp require_token(_), do: {:error, "Sign in with a Cursor subscription to connect."}

  defp require_model(model) when is_binary(model) and model != "", do: :ok

  defp require_model(_),
    do: {:error, "Cursor model is required; refusing to fall back to another provider."}

  defp transport_opts(config) do
    List.wrap(config[:transport_opts])
  end

  defp request_opts(config) do
    Keyword.new()
    |> maybe_kw(:transport_opts, config[:transport_opts])
  end

  defp maybe_kw(kw, _key, nil), do: kw
  defp maybe_kw(kw, key, value), do: Keyword.put(kw, key, value)

  # `receive_timeout` is silence, not a cap on a live stream. Each inbound
  # server frame starts the window again. A timer that already fired carries
  # the old ticket and does not close the run.
  defp arm_timeout(state, timeout) do
    cancel_timeout(state)
    ticket = System.unique_integer([:positive])
    ref = Process.send_after(self(), {:run_timeout, ticket}, timeout)
    %{state | timeout_ref: ref, receive_timeout: timeout, timeout_ticket: ticket}
  end

  defp slide_timeout(%{phase: :running, receive_timeout: timeout} = state)
       when is_integer(timeout) and timeout > 0 do
    arm_timeout(state, timeout)
  end

  defp slide_timeout(state), do: state

  defp schedule_heartbeat(state) do
    cancel_heartbeat(state)
    ref = Process.send_after(self(), :heartbeat, @heartbeat_ms)
    %{state | heartbeat_ref: ref}
  end

  defp cancel_heartbeat(%{heartbeat_ref: ref}) when is_reference(ref),
    do: Process.cancel_timer(ref)

  defp cancel_heartbeat(_), do: false

  defp cancel_timeout(%{timeout_ref: ref}) when is_reference(ref), do: Process.cancel_timer(ref)
  defp cancel_timeout(_), do: false

  defp clear_timeout(state) do
    cancel_timeout(state)
    %{state | timeout_ref: nil}
  end

  defp monitor_from({pid, _}), do: Process.monitor(pid)

  defp drop_caller(state) do
    demonitor_caller(state)
    %{state | caller: nil, caller_mon: nil}
  end

  defp demonitor_caller(%{caller_mon: mon}) when is_reference(mon) do
    Process.demonitor(mon, [:flush])
  end

  defp demonitor_caller(_), do: :ok

  defp cursor_conversation_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> Ecto.UUID.generate()
    end
  end

  defp uncertain_error do
    "Cursor stream disconnected after a tool request; not retrying because execution may have started."
  end
end
