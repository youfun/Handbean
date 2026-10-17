defmodule Handbean.Agent.CliAgent.Run do
  @moduledoc """
  One user turn whose loop owner is a CLI agent.

  Handbean opens the session, sends the message, and projects normalized
  events into the existing transcript path. It does not call Provider, attach
  Handbean tool definitions, or pass CLI tool events to
  `Handbean.Agent.Tool.Executor`.

  A supervised `Handbean.Agent.CliAgent.Runner` passes an `:event_sink`, so the
  task only talks to the CLI and the Runner remains the sole persistence and
  broadcast owner. Direct callers without a sink retain the standalone
  persistence behavior.
  """

  alias Handbean.Agent.CliAgent.{Binding, Event, Registry}
  alias Handbean.Agent.TranscriptPersistence
  alias Handbean.Host
  alias Handbean.PubSub.Session, as: PubSubSession

  @doc """
  Run one CLI-owned turn.

  Options:

    * `:backend` — registry id, such as `"droid"`
    * `:cwd` — workspace directory
    * `:model` — the CLI's own model id
    * `:reasoning_effort` — a level that CLI accepts
    * `:session_id` — resume a backend session
    * `:auto` — `:low`, `:medium`, or `:high`; omitted means the backend default
    * `:conversation_id` — when set, standalone events are persisted and broadcast
    * `:decision` — explicit permission or ask-user answer; never invented here
    * `:event_sink` — Runner-owned normalized event sink
    * `:session_observer` — asynchronous session lifecycle observer
  """
  @spec turn(Handbean.Agent.CliAgent.input(), keyword()) ::
          {:ok, String.t(), map()}
          | {:awaiting, :permission | :ask_user, map()}
          | {:error, term()}
  def turn(input, opts)
      when (is_binary(input) or is_struct(input, Handbean.Agent.Message)) and is_list(opts) do
    conversation_id = Keyword.get(opts, :conversation_id)
    opts = resolve_session_id(conversation_id, opts)

    result =
      with {:ok, module} <- validate_input(input, opts),
           {:ok, session} <- module.start_session(start_opts(opts)),
           session <- maybe_decision(module, session, opts) do
        run_session(module, session, input, conversation_id, opts)
      else
        {:error, reason} -> {:error, reason}
      end

    persist_standalone_result(conversation_id, result, opts)
    result
  end

  @doc "Validate host, backend, and input capability before a run is admitted."
  @spec validate_input(Handbean.Agent.CliAgent.input(), keyword()) ::
          {:ok, module()} | {:error, term()}
  def validate_input(input, opts)
      when (is_binary(input) or is_struct(input, Handbean.Agent.Message)) and is_list(opts) do
    backend = Keyword.get(opts, :backend)

    with :ok <- host_available(),
         {:ok, module} <- Registry.fetch(backend),
         :ok <- validate_attachments(backend, input, opts) do
      {:ok, module}
    end
  end

  @doc """
  Project one normalized event into the transcript and session bus.

  The caller of this function owns event ordering. Runner calls it from its
  GenServer loop, ensuring run start, deltas, tools, and run end all use the
  same TranscriptPersistence process dictionary.
  """
  @spec project(String.t() | nil, Event.t(), keyword()) :: :ok
  def project(nil, event, _opts) when is_tuple(event) do
    if Event.normalized?(event), do: :ok, else: :ok
  end

  def project(conversation_id, event, opts) when is_binary(conversation_id) do
    if Event.normalized?(event) do
      persist(conversation_id, event, opts)
      projected = projected_event(conversation_id, event)
      broadcast(conversation_id, projected, opts)
    end

    :ok
  end

  defp run_session(module, session, input, conversation_id, opts) do
    # The try begins immediately after start_session succeeds. Observer bugs or
    # cancellation can therefore never bypass backend cleanup.
    try do
      observe_session(opts, {:started, module, session})
      persist_standalone_run_start(conversation_id, opts)
      on_event = fn event -> dispatch_event(conversation_id, event, opts) end

      case module.send_message(session, input, on_event) do
        {:ok, session, events} -> finish_turn(session, events)
        {:error, reason} -> {:error, reason}
      end
    after
      safe_stop_session(module, session)
      observe_session(opts, {:stopped, module, session})
    end
  end

  defp dispatch_event(conversation_id, event, opts) do
    case Keyword.get(opts, :event_sink) do
      sink when is_function(sink, 1) -> safe_notify(sink, event)
      _ -> project(conversation_id, event, opts)
    end
  end

  defp finish_turn(session, events) do
    meta = %{session_id: session.session_id, backend: session.backend}

    case awaiting(events) do
      nil -> {:ok, final_text(events), meta}
      request -> {:awaiting, request.kind, Map.merge(meta, request)}
    end
  end

  defp awaiting(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      {:permission_request, request} ->
        if is_nil(request[:selected]),
          do: %{kind: :permission, request: request, options: request[:options] || []}

      {:ask_user, request} ->
        if is_nil(request[:answers]), do: %{kind: :ask_user, request: request, options: []}

      _ ->
        nil
    end)
  end

  defp host_available do
    if Host.shell?(), do: :ok, else: {:error, :not_available}
  end

  defp validate_attachments(backend, input, opts) do
    attachments? = Keyword.get(opts, :attachments, []) != [] or attachment_blocks?(input)

    if attachments? and not Registry.attachments?(backend),
      do: {:error, :attachments_not_supported},
      else: :ok
  end

  defp attachment_blocks?(%Handbean.Agent.Message{content: blocks}) when is_list(blocks) do
    Enum.any?(blocks, fn block ->
      type = Handbean.Utils.SafeMap.get_any(block, :type, "type")
      type in ["image", "audio", "video", "document"]
    end)
  end

  defp attachment_blocks?(_input), do: false

  defp start_opts(opts) do
    Keyword.take(opts, [
      :cwd,
      :model,
      :reasoning_effort,
      :session_id,
      :auto,
      :executable,
      :timeout
    ])
  end

  defp maybe_decision(module, session, opts) do
    case Keyword.get(opts, :decision) do
      nil ->
        session

      decision ->
        session =
          if function_exported?(module, :put_decision, 2),
            do: module.put_decision(session, decision),
            else: session

        private = Map.put(session.private || %{}, :decision, decision)
        %{session | private: private}
    end
  end

  defp persist(conversation_id, {:text_delta, text}, opts) do
    TranscriptPersistence.handle_event(conversation_id, {:message_delta, %{chunk: text}}, opts)
  end

  defp persist(conversation_id, {:tool_start, tool}, opts) do
    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_start,
       %{
         tool: tool.name,
         tool_use_id: tool.id,
         input: Map.get(tool, :input, %{}),
         projected: true
       }},
      opts
    )
  end

  defp persist(conversation_id, {:tool_end, tool}, opts) do
    TranscriptPersistence.handle_event(
      conversation_id,
      {:tool_end,
       %{
         tool_use_id: tool.id,
         output: Map.get(tool, :output, ""),
         error: if(tool[:is_error], do: "cli tool error"),
         projected: true
       }},
      opts
    )
  end

  defp persist(conversation_id, {:usage, usage}, opts) do
    TranscriptPersistence.handle_event(conversation_id, {:delegation_usage, usage}, opts)
  end

  defp persist(conversation_id, {:status, %{state: state}}, opts) do
    Binding.record_status(conversation_id, opts[:run_id], state)
    :ok
  end

  defp persist(_conversation_id, {:turn_end, _done}, _opts), do: :ok
  defp persist(_conversation_id, {:error, _reason}, _opts), do: :ok
  defp persist(_conversation_id, _event, _opts), do: :ok

  defp projected_event(conversation_id, {:text_delta, text}) do
    TranscriptPersistence.project_event(conversation_id, {:message_delta, %{chunk: text}})
  end

  defp projected_event(_conversation_id, {:status, %{state: state}}) do
    {:session_state, %{state: state}}
  end

  defp projected_event(_conversation_id, {:tool_start, tool}) when is_map(tool) do
    {:tool_start,
     tool
     |> Map.put_new(:tool, tool[:name])
     |> Map.put_new(:tool_use_id, tool[:id])}
  end

  defp projected_event(_conversation_id, {:tool_end, tool}) when is_map(tool) do
    {:tool_end,
     tool
     |> Map.put_new(:tool, tool[:name])
     |> Map.put_new(:tool_use_id, tool[:id])
     |> Map.put_new(:error, if(tool[:is_error], do: "cli tool error"))}
  end

  defp projected_event(_conversation_id, event), do: event

  defp resolve_session_id(conversation_id, opts) when is_binary(conversation_id) do
    if Keyword.has_key?(opts, :session_id) do
      case Keyword.get(opts, :session_id) do
        session_id when is_binary(session_id) and session_id != "" -> opts
        _ -> Keyword.delete(opts, :session_id)
      end
    else
      backend = Keyword.get(opts, :backend)

      case Binding.resumable_session_id(conversation_id, backend, opts) do
        session_id when is_binary(session_id) -> Keyword.put(opts, :session_id, session_id)
        _ -> opts
      end
    end
  end

  defp resolve_session_id(_conversation_id, opts), do: opts

  defp persist_standalone_run_start(conversation_id, opts) when is_binary(conversation_id) do
    if runner_owned?(opts) do
      :ok
    else
      Binding.record_run_start(conversation_id, opts[:backend], opts[:run_id], opts)

      TranscriptPersistence.handle_event(
        conversation_id,
        {:run_start, lifecycle_payload(opts)},
        opts
      )
    end
  end

  defp persist_standalone_run_start(_conversation_id, _opts), do: :ok

  defp persist_standalone_result(conversation_id, result, opts) when is_binary(conversation_id) do
    if runner_owned?(opts) do
      :ok
    else
      record_standalone_binding(conversation_id, result, opts)
      payload = standalone_terminal_payload(result, opts)

      if payload do
        TranscriptPersistence.handle_event(conversation_id, {:run_end, payload}, opts)
        PubSubSession.broadcast_event(conversation_id, :run_end, payload)
      end
    end
  end

  defp persist_standalone_result(_conversation_id, _result, _opts), do: :ok

  defp record_standalone_binding(conversation_id, {:ok, _text, meta}, opts) do
    if is_binary(meta[:backend]) and is_binary(meta[:session_id]) do
      Binding.put(conversation_id, %{
        backend: meta[:backend],
        session_id: meta[:session_id],
        cwd: opts[:cwd],
        model: opts[:model],
        reasoning_effort: opts[:reasoning_effort]
      })
    end

    Binding.record_run_end(conversation_id, opts[:run_id], :completed)
  end

  defp record_standalone_binding(conversation_id, {:awaiting, kind, meta}, opts) do
    Binding.record_awaiting(conversation_id, opts[:run_id], kind, meta)
  end

  defp record_standalone_binding(conversation_id, {:error, _reason}, opts) do
    Binding.record_run_end(conversation_id, opts[:run_id], :error)
  end

  defp standalone_terminal_payload({:ok, _text, meta}, opts) do
    lifecycle_payload(opts)
    |> Map.merge(%{status: :completed, turns: 1, session_id: meta[:session_id]})
  end

  defp standalone_terminal_payload({:awaiting, _kind, _meta}, _opts), do: nil

  defp standalone_terminal_payload({:error, reason}, opts) do
    lifecycle_payload(opts)
    |> Map.merge(%{status: :error, turns: 0, error: reason_text(reason)})
  end

  defp lifecycle_payload(opts) do
    %{
      run_id: opts[:run_id],
      loop_owner: :cli_agent,
      backend: opts[:backend],
      model: opts[:model]
    }
  end

  defp runner_owned?(opts), do: is_function(Keyword.get(opts, :event_sink), 1)

  defp observe_session(opts, event) do
    case Keyword.get(opts, :session_observer) do
      observer when is_function(observer, 1) -> safe_notify(observer, event)
      _ -> :ok
    end
  end

  defp safe_notify(observer, event) do
    observer.(event)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp safe_stop_session(module, session) do
    module.stop_session(session)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp broadcast(conversation_id, {tag, payload}, opts) do
    PubSubSession.broadcast_event(conversation_id, tag, broadcast_payload(payload, opts))
  end

  defp broadcast_payload(payload, opts) when is_map(payload), do: stamp(payload, opts)
  defp broadcast_payload(payload, opts), do: stamp(%{reason: payload}, opts)

  defp stamp(payload, opts) do
    payload
    |> Map.put(:loop_owner, :cli_agent)
    |> Map.put(:run_id, Keyword.get(opts, :run_id))
    |> Map.put(:projected, true)
  end

  defp final_text(events) do
    events
    |> Enum.filter(&match?({:text_delta, _}, &1))
    |> Enum.map_join("", fn {:text_delta, text} -> text end)
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
