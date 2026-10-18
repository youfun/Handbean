defmodule Handbean.Agent.Turn do
  @moduledoc """
  The core agent loop.

  Sends messages to a provider, executes tool calls, and loops until
  the provider signals completion or the turn limit is reached.

  This is a pure function — no GenServer, no process overhead.
  """

  alias Handbean.Agent.{
    Compactor,
    Message,
    ModelContext,
    Reasoning,
    State
  }

  alias Handbean.Agent.Middleware
  alias Handbean.Agent.Middleware.ToolGuard
  alias Handbean.Agent.Provider.Retry
  alias Handbean.Agent.Tool.{Catalog, Executor}
  alias Handbean.Agent.Turn.StreamTracker
  alias Handbean.Extension.HookPipeline
  alias Handbean.Utils.SafeMap

  require Logger

  @max_tool_event_output 16_000
  @turn_end_counter_key {__MODULE__, :turn_end_counter}

  @doc """
  Resume agent loop from an interrupted tool-approval state.

  Called by `Handbean.Agent.resume_after_tool_approval/3` after the user has
  made approval decisions on pending tool calls. Does NOT re-request the
  provider — instead executes the approved tool batch and continues the
  normal agent loop.

  ## Decisions format

  Each decision is a map:

      %{
        "tool_call_id" => "call_xxx",
        "tool_name" => "bash",
        "action" => "approve" | "deny",
        "remember" => true | false
      }
  """
  @spec resume_after_tool_approval(State.t(), [map()], keyword()) :: State.t()
  def resume_after_tool_approval(%State{status: :interrupted} = state, decisions, opts) do
    resolution = ToolGuard.resolve_approval(state, decisions)

    resolution.state
    |> continue_after_approval(
      resolution.executable_calls,
      resolution.tool_calls,
      resolution.denied_blocks,
      opts
    )
    |> finish_run(opts)
  end

  def resume_after_tool_approval(%State{} = state, _decisions, _opts) do
    Logger.warning(
      "[Turn] resume_after_tool_approval called on non-interrupted state status=#{state.status}"
    )

    state
  end

  # ── Approval execution ──

  defp continue_after_approval(state, [], _batch_calls, denied_blocks, opts) do
    emit_denied_tool_end_events(denied_blocks, opts, state.turn)
    emit_resumed_turn_end(state, opts)
    result_msg = Message.tool_results(denied_blocks)

    state
    |> append_tool_results([result_msg])
    |> mw_run(:after_tool_execution)
    |> inject_candidate_messages(opts, :steer)
    |> do_turn(opts)
  end

  defp continue_after_approval(state, executable, batch_calls, denied_blocks, opts) do
    emit_tool_starts(executable, opts, state.turn)

    case Executor.execute_all_with_context(executable, state) do
      {:ok, result_msg, ui_blocks, state} ->
        merge_approved_execution(%{
          state: state,
          batch_calls: batch_calls,
          executable: executable,
          result_msg: result_msg,
          ui_blocks: ui_blocks,
          denied_blocks: denied_blocks,
          opts: opts
        })
    end
  end

  defp merge_approved_execution(execution) do
    all_ui_blocks =
      order_guarded_blocks(
        execution.batch_calls,
        execution.ui_blocks ++ execution.denied_blocks
      )

    merged_msg = %{
      execution.result_msg
      | content: Enum.map(all_ui_blocks, &Executor.strip_details/1)
    }

    emit_tool_end_events(
      execution.executable,
      execution.ui_blocks,
      execution.opts,
      execution.state.turn
    )

    emit_denied_tool_end_events(
      execution.denied_blocks,
      execution.opts,
      execution.state.turn
    )

    emit_resumed_turn_end(execution.state, execution.opts)

    execution.state
    |> append_tool_results([merged_msg])
    |> Map.update!(:messages, &Handbean.Tool.Images.bound_history/1)
    |> mw_run(:after_tool_execution)
    |> inject_candidate_messages(execution.opts, :steer)
    |> do_turn(execution.opts)
  end

  defp blocked_tool_result_block(call, block_source) do
    call_id = Handbean.Utils.SafeMap.get_any(call, [:id, "id"])
    name = Handbean.Utils.SafeMap.get_any(call, :name, "name")

    {content, blocked_by} =
      case block_source do
        {:extension, reason} ->
          {extension_block_content(name, reason), :extension}

        :active_set ->
          {"Tool call blocked: #{name} is not available at this stage", :active_set}
      end

    Message.tool_result_block(
      call_id,
      content,
      true,
      %{permission: :denied, blocked_by: blocked_by, tool: name}
    )
  end

  defp extension_block_content(name, reason) do
    reason = to_string(reason)

    if String.trim(reason) == "" do
      "Tool call blocked: #{name} is not available at this stage"
    else
      "Tool call blocked: #{reason}"
    end
  end

  defp emit_denied_tool_end_events(blocks, opts, turn_number) do
    Enum.each(blocks, fn block ->
      details = block[:details] || %{}

      emit(opts, :tool_end, %{
        tool_use_id: block[:tool_use_id],
        tool: Handbean.Utils.SafeMap.get_any(details, [:tool, "tool"]) || "unknown",
        turn_number: turn_number,
        duration_ms: 0,
        timing_fidelity: "not_started",
        details: bounded_tool_details(details),
        error: bounded_tool_error(block[:content]),
        output: bounded_tool_output(block[:content])
      })
    end)
  end

  defp emit_resumed_turn_end(state, opts) do
    emit_turn_end(opts, %{
      turn: state.turn,
      stop_reason: "tool_use_resumed",
      status: :completed
    })
  end

  defp emit_tool_end_events(tool_calls, ui_blocks, opts, turn_number) do
    ui_block_by_id =
      Map.new(ui_blocks, fn block ->
        {Handbean.Utils.SafeMap.get_any(block, [:tool_use_id, "tool_use_id"]), block}
      end)

    Enum.each(tool_calls, fn call ->
      call_id = Handbean.Utils.SafeMap.get_any(call, [:id, "id"])
      ui_block = Map.get(ui_block_by_id, call_id)
      details = (ui_block && ui_block[:details]) || %{}

      file_path = tool_end_file_path(details, call)

      payload =
        %{
          tool_use_id: call_id,
          tool: Handbean.Utils.SafeMap.get_any(call, [:name, "name"]),
          parent_tool_call_id: nil,
          turn_number: turn_number,
          details: bounded_tool_details(details),
          file_path: file_path,
          images: Handbean.Tool.Images.project(ui_block && ui_block[:images]),
          published_media: Handbean.Media.project(ui_block && ui_block[:published_media]),
          output: bounded_tool_output(ui_block && block_content(ui_block))
        }
        |> Map.merge(tool_timing_payload(details))

      payload =
        if ui_block && ui_block[:is_error] do
          Map.put(payload, :error, bounded_tool_error(block_content(ui_block)))
        else
          payload
        end

      emit(opts, :tool_end, payload)
    end)
  end

  @doc """
  Run the agent loop until completion, error, or max turns.

  ## Options
    - `:streaming` - boolean, whether to use streaming (default: false)
    - `:on_chunk` - function called for each streamed chunk
    - `:on_event` - function called with `{:event_kind, payload}` tuples
  """
  @spec run_loop(State.t(), keyword()) :: State.t()
  def run_loop(%State{} = state, opts \\ []) do
    Process.delete(@turn_end_counter_key)

    Logger.info(
      "[Turn] run_loop start model=#{state.config.model} " <>
        "max_turns=#{state.config.max_turns} streaming=#{Keyword.get(opts, :streaming, false)} " <>
        "messages=#{length(state.messages)}"
    )

    # session_start middleware
    state = mw_run(state, :session_start)

    # before_agent_start hook (blockable — call HookPipeline directly)
    state = check_before_agent_start(state, opts)

    if state.status == :halted do
      Logger.warning("[Turn] before_agent_start blocked: #{state.error}")

      emit(opts, :run_end, %{
        status: state.status,
        error: state.error,
        turns: 0,
        duration_ms: 0,
        model: state.config.model,
        loop_owner: :handbean,
        run_id: state.config.run_id
      })

      emit(opts, :agent_end, %{
        status: state.status,
        error: state.error,
        turns: 0,
        run_id: state.config.run_id
      })

      # session_end middleware
      mw_run(state, :session_end)
    else
      emit(opts, :run_start, %{model: state.config.model, loop_owner: :handbean})

      run_start = System.monotonic_time(:millisecond)

      :telemetry.execute(
        [:handbean, :run, :start],
        %{system_time: System.system_time()},
        %{model: state.config.model}
      )

      result = do_turn(state, opts)

      duration_ms = System.monotonic_time(:millisecond) - run_start

      :telemetry.execute(
        [:handbean, :run, :stop],
        %{duration_ms: duration_ms},
        %{status: result.status, turns: result.turn, model: state.config.model}
      )

      Logger.info(
        "[Turn] run_loop end status=#{result.status} turns=#{result.turn} " <>
          "duration_ms=#{duration_ms} " <>
          "usage=#{inspect(result.usage)}"
      )

      finish_run(result, opts, duration_ms)
    end
  end

  defp finish_run(result, opts), do: finish_run(result, opts, nil)

  defp finish_run(result, opts, duration_ms) do
    payload = %{
      status: result.status,
      turns: result.turn,
      duration_ms: duration_ms,
      model: result.config.model,
      loop_owner: :handbean,
      usage: result.usage,
      run_id: result.config.run_id
    }

    payload = if result.error, do: Map.put(payload, :error, result.error), else: payload

    payload =
      case result.provider_response_metadata do
        %{finish_reason: reason} when is_nil(result.error) ->
          Map.put(payload, :provider_finish_reason, reason)

        _ ->
          payload
      end

    payload =
      case result.interrupt_data do
        %{signal: signal, evidence: evidence} ->
          payload |> Map.put(:signal, signal) |> Map.put(:evidence, evidence)

        _ ->
          payload
      end

    emit(opts, :run_end, payload)
    emit(opts, :agent_end, payload)
    mw_run(result, :session_end)
  end

  # ── before_agent_start hook ──

  defp check_before_agent_start(state, opts) do
    session_id = Keyword.get(opts, :session_id)

    if session_id do
      payload = %{
        model: state.config.model,
        max_turns: state.config.max_turns
      }

      case run_extension_hook(state, session_id, {:before_agent_start, payload}) do
        {:block, reason} ->
          %{state | status: :halted, error: "Blocked by extension: #{reason}"}

        {:transform, transformed} ->
          # Whitelist: system_prompt, metadata only (per spec S2.1)
          config =
            case Map.fetch(transformed, :system_prompt) do
              {:ok, prompt} when is_binary(prompt) -> %{state.config | system_prompt: prompt}
              _ -> state.config
            end

          state =
            case Map.fetch(transformed, :metadata) do
              {:ok, meta} when is_map(meta) -> State.merge_run_metadata(state, meta)
              _ -> state
            end

          %{state | config: config}

        _ ->
          state
      end
    else
      state
    end
  end

  # ── context hook ──

  defp apply_context_hook(state, provider_config, opts) do
    session_id = Keyword.get(opts, :session_id)
    messages = ModelContext.visible(state)

    if session_id do
      payload = %{
        messages: messages,
        system_prompt: provider_config.system_prompt
      }

      case run_extension_hook(state, session_id, {:context, payload}) do
        {:block, reason} ->
          {:block, reason}

        {:transform, transformed} ->
          # Request-scoped only: outbound messages + system_prompt for this
          # provider call. Durable State / transcript stay untouched.
          outbound_messages =
            case Map.fetch(transformed, :messages) do
              {:ok, msgs} when is_list(msgs) -> msgs
              _ -> messages
            end

          provider_config =
            case Map.fetch(transformed, :system_prompt) do
              {:ok, prompt} when is_binary(prompt) ->
                %{provider_config | system_prompt: prompt}

              _ ->
                provider_config
            end

          {outbound_messages, provider_config}

        _ ->
          {messages, provider_config}
      end
    else
      {messages, provider_config}
    end
  end

  # ── Middleware helper ──

  defp run_extension_hook(%State{config: %{delegated?: true}}, _session_id, _event),
    do: :ok

  defp run_extension_hook(_state, session_id, event), do: HookPipeline.run(session_id, event)

  defp mw_run(%State{} = state, hook) do
    middleware = state.config.middleware || []

    case Middleware.run(hook, state, middleware) do
      {:halted, _reason} -> %{state | status: :halted}
      {:interrupted, %State{} = s, _data} -> s
      {:tool_guard_denied, %State{} = s} -> s
      %State{} = s -> s
    end
  end

  # ── Event helper ──

  defp turn_end_count, do: Process.get(@turn_end_counter_key, 0)

  defp emit_turn_end(opts, payload) do
    Process.put(@turn_end_counter_key, turn_end_count() + 1)
    emit(opts, :turn_end, payload)
  end

  defp tool_approval_interrupted?(%State{
         status: :interrupted,
         interrupt_data: %{type: :tool_approval}
       }),
       do: true

  defp tool_approval_interrupted?(_state), do: false

  defp continue_to_next_turn(state, opts, stop_reason) do
    emit_turn_end(opts, %{
      turn: state.turn,
      stop_reason: stop_reason,
      status: if(state.status == :running, do: :completed, else: state.status)
    })

    do_turn(state, opts)
  end

  defp emit(opts, kind, payload) do
    log_emit(kind, payload)

    case Keyword.get(opts, :on_event) do
      nil ->
        :ok

      fun when is_function(fun, 1) ->
        # Suppress per-chunk logging for message_delta to avoid
        # flooding the console during SSE streaming (50-500+ chunks/turn).
        fun.({kind, payload})
    end
  end

  defp notify_progress(opts, kind) do
    case Keyword.get(opts, :on_progress) do
      fun when is_function(fun, 1) -> fun.(kind)
      _ -> :ok
    end
  end

  defp emit_provider_items(opts, messages) do
    items =
      messages
      |> Enum.flat_map(fn
        %Handbean.Agent.Message{content: blocks} when is_list(blocks) ->
          Enum.filter(blocks, fn
            %{type: "responses_reasoning"} ->
              true

            %{"type" => "responses_reasoning"} ->
              true

            %{type: "text", phase: phase} when phase in ["commentary", "final_answer"] ->
              true

            %{"type" => "text", "phase" => phase} when phase in ["commentary", "final_answer"] ->
              true

            _ ->
              false
          end)

        _ ->
          []
      end)

    if items != [], do: emit(opts, :provider_items, %{items: items})
  end

  defp emit_assistant_messages(opts, messages) do
    Enum.each(messages, fn
      %Message{role: :assistant} = msg ->
        text = Message.text(msg)

        if is_binary(text) and text != "" do
          emit(opts, :message_delta, %{chunk: text})
        end

      _ ->
        :ok
    end)
  end

  # A commentary-only Codex message is visible, but it is not the final answer.
  # Retry once with that commentary in history. A truly blank assistant message
  # is still an empty turn.
  defp missing_final_answer?(messages) do
    assistant_messages = Enum.filter(messages, &match?(%Message{role: :assistant}, &1))

    cond do
      assistant_messages == [] ->
        false

      Enum.any?(assistant_messages, &final_answer?/1) ->
        false

      Enum.any?(assistant_messages, &(Message.tool_calls(&1) != [])) ->
        false

      true ->
        Enum.all?(assistant_messages, fn message ->
          commentary_only?(message) or not visible_assistant_text?(message)
        end)
    end
  end

  defp final_answer?(%Message{content: blocks}) when is_list(blocks) do
    Enum.any?(blocks, fn block ->
      is_map(block) and block[:type] == "text" and block[:phase] == "final_answer" and
        is_binary(block[:text]) and String.trim(block[:text]) != ""
    end)
  end

  defp final_answer?(%Message{content: text}) when is_binary(text), do: String.trim(text) != ""
  defp final_answer?(_), do: false

  defp commentary_only?(%Message{content: blocks}) when is_list(blocks) do
    text_blocks = Enum.filter(blocks, &(is_map(&1) and &1[:type] == "text"))

    text_blocks != [] and
      Enum.all?(text_blocks, fn block ->
        block[:phase] == "commentary" and is_binary(block[:text]) and
          String.trim(block[:text]) != ""
      end)
  end

  defp commentary_only?(_), do: false

  defp commentary_only_turn?(messages) do
    messages != [] and Enum.all?(messages, &commentary_only?/1)
  end

  defp visible_assistant_text?(%Message{} = message) do
    case Message.text(message) do
      text when is_binary(text) -> String.trim(text) != ""
      _ -> false
    end
  end

  # ── Turn loop ──

  defp do_turn(%State{status: :interrupted} = state, opts) do
    if stall_check?(state) do
      emit(opts, :stall_check_requested, state.interrupt_data)
    end

    state
  end

  defp do_turn(%State{status: status} = state, _opts)
       when status in [:stalled, :max_turns, :error, :halted, :budget_exceeded] do
    state
  end

  defp do_turn(%State{turn: turn, config: %{max_turns: max_turns}} = state, _opts)
       when is_integer(max_turns) and turn >= max_turns do
    Logger.warning(fn -> "[Turn] max_turns reached turn=#{turn} max=#{max_turns}" end)
    %{state | status: :max_turns}
  end

  defp do_turn(%State{} = state, opts) do
    turn_number = state.turn + 1

    # turn_start hook (read-only notification)
    emit(opts, :turn_start, %{turn: turn_number})

    :telemetry.execute(
      [:handbean, :turn, :start],
      %{system_time: System.system_time()},
      %{turn: turn_number}
    )

    state =
      state
      |> maybe_compact(opts)
      |> inject_candidate_messages(opts, :steer)
      |> mw_run(:before_completion)

    Logger.debug(
      "[Turn] start turn=#{turn_number} messages=#{length(state.messages)} " <>
        "model=#{state.config.model}"
    )

    if state.status == :halted do
      :telemetry.execute(
        [:handbean, :turn, :stop],
        %{duration_ms: 0},
        %{turn: turn_number, status: :halted}
      )

      # turn_end hook (read-only notification)
      emit_turn_end(opts, %{
        turn: turn_number,
        stop_reason: "halted",
        status: :halted,
        duration_ms: 0
      })

      state
    else
      t0 = System.monotonic_time(:millisecond)
      turn_end_count = turn_end_count()
      result = do_completion(state, opts)
      duration_ms = System.monotonic_time(:millisecond) - t0

      Logger.debug(
        "[Turn] stop turn=#{turn_number} status=#{result.status} duration_ms=#{duration_ms}"
      )

      :telemetry.execute(
        [:handbean, :turn, :stop],
        %{duration_ms: duration_ms},
        %{turn: turn_number, status: result.status}
      )

      if turn_end_count() == turn_end_count and not tool_approval_interrupted?(result) do
        emit_turn_end(opts, %{
          turn: turn_number,
          stop_reason: "completed",
          status: result.status,
          duration_ms: duration_ms
        })
      end

      result
    end
  end

  # Apply Compactor before each provider call so a long-running conversation
  # cannot indefinitely grow the message history and stall the provider with
  # oversized payloads.
  defp maybe_compact(%State{} = state, opts) do
    visible = ModelContext.visible(state)
    probe = %{state | messages: visible}

    call_opts =
      state
      |> compaction_call_opts(opts)
      |> Keyword.put(:usage_anchor, state.usage_anchor)

    case Compactor.maybe_compact(probe, call_opts) do
      {:compacted, compacted} ->
        state = ModelContext.install(state, compacted.messages)

        if ModelContext.visible(state) == visible do
          state
        else
          Logger.info(
            "[Turn] context compacted before=#{length(visible)} " <>
              "after=#{length(ModelContext.visible(state))} max_tokens=#{state.config.max_tokens}"
          )

          :telemetry.execute(
            [:handbean, :compaction, :done],
            %{
              messages_before: length(visible),
              messages_after: length(ModelContext.visible(state))
            },
            %{turn: state.turn + 1}
          )

          case Middleware.run(:after_compaction, state, state.config.middleware || []) do
            {:halted, reason} ->
              %{state | status: :halted, error: "Halted by middleware: #{reason}"}

            %State{} = s ->
              s
          end
        end

      {:unchanged, _state} ->
        state
    end
  end

  defp do_completion(%State{} = state, opts) do
    provider_config =
      state
      |> build_provider_config()
      |> Map.put(:run_deadline, Keyword.get(opts, :run_deadline))

    case apply_context_hook(state, provider_config, opts) do
      {:block, reason} -> %{state | status: :halted, error: "Blocked by extension: #{reason}"}
      {messages, config} -> do_provider_completion(state, opts, messages, config)
    end
  end

  defp do_provider_completion(state, opts, outbound_messages, provider_config) do
    provider = state.config.provider
    {provider_config, tool_defs} = Catalog.for_completion(state, opts, provider_config)

    estimated_tokens =
      Compactor.request_tokens(outbound_messages, state.usage_anchor,
        system_prompt: provider_config[:system_prompt],
        tool_defs: tool_defs
      )

    if estimated_tokens > state.config.max_tokens do
      error =
        "Context remains too large after compaction " <>
          "(estimated #{estimated_tokens} tokens, window #{state.config.max_tokens}); " <>
          "request was not sent"

      Logger.error("[Turn] #{error}")
      mw_run(%{state | status: :error, error: error}, :on_error)
    else
      invoke_configured_provider_completion(
        state,
        opts,
        outbound_messages,
        provider_config,
        provider,
        tool_defs
      )
    end
  end

  defp invoke_configured_provider_completion(
         state,
         opts,
         outbound_messages,
         provider_config,
         provider,
         tool_defs
       ) do
    streaming? = Keyword.get(opts, :streaming, false)
    stream_tracker = StreamTracker.start(streaming?)

    on_chunk =
      StreamTracker.callback(stream_tracker, streaming?, opts, fn payload ->
        emit(opts, :message_delta, payload)
      end)

    provider_config = prepare_completion_config(provider_config, opts, streaming?, on_chunk)

    Logger.debug(
      "[Turn] provider call provider=#{inspect(provider)} streaming=#{streaming?} " <>
        "tool_defs=#{length(tool_defs)} messages=#{length(outbound_messages)}"
    )

    provider_t0 = System.monotonic_time(:millisecond)

    completion = %{
      provider: provider,
      state: state,
      outbound_messages: outbound_messages,
      tool_defs: tool_defs,
      provider_config: provider_config,
      streaming?: streaming?,
      on_chunk: on_chunk,
      stream_tracker: stream_tracker,
      opts: opts
    }

    {provider_result, streamed_text} = invoke_provider_completion(completion)

    dispatch_provider_result(provider_result, completion, streamed_text, provider_t0)
  end

  # Appends a finished tool-result batch, freezing the budget trailer into
  # each result once. Rewriting the trailer on every request would change
  # every earlier tool result and bust the provider prefix cache, so each
  # result keeps the anchor-based estimate of the request that first carried
  # it. Only providers that offer context editing get the marker; its meaning
  # is explained in `ModelContext.prompt_section/0`.
  defp append_tool_results(%State{} = state, messages) when is_list(messages) do
    if Handbean.Agent.Provider.context_editing?(state.config.provider) do
      State.append_messages(state, Enum.map(messages, &annotate_context_budget(&1, state)))
    else
      State.append_messages(state, messages)
    end
  end

  defp annotate_context_budget(%Message{} = message, %State{} = state) do
    used =
      Compactor.request_tokens(
        ModelContext.visible(state) ++ [message],
        state.usage_anchor
      )

    trailer = "\n[context: ~#{used} of #{state.config.max_tokens} tokens]"
    annotate_context_blocks(message, trailer)
  end

  defp annotate_context_blocks(%Message{content: blocks} = message, trailer)
       when is_list(blocks) do
    %{message | content: Enum.map(blocks, &append_block_budget(&1, trailer))}
  end

  defp annotate_context_blocks(message, _trailer), do: message

  defp append_block_budget(block, trailer) when is_map(block) do
    content = SafeMap.get_any(block, :content, "content")

    cond do
      not is_binary(content) ->
        block

      String.ends_with?(content, trailer) ->
        block

      Map.has_key?(block, :content) ->
        %{block | content: content <> trailer}

      true ->
        Map.put(block, "content", content <> trailer)
    end
  end

  defp append_block_budget(block, _trailer), do: block

  defp prepare_completion_config(provider_config, opts, streaming?, on_chunk) do
    provider_config
    |> Map.put(:stream, streaming?)
    |> Map.put(:retry_owner, :turn)
    |> maybe_put_provider_event_callback(opts)
    |> maybe_put_on_chunk(on_chunk)
  end

  defp maybe_put_on_chunk(provider_config, on_chunk) do
    if is_function(on_chunk, 1),
      do: Map.put(provider_config, :on_chunk, on_chunk),
      else: provider_config
  end

  defp compaction_call_opts(state, opts) do
    provider_config =
      state
      |> build_provider_config()
      |> Map.delete(:provider_state)

    [tool_defs: Catalog.active_defs(state, opts), provider_config: provider_config]
  end

  defp invoke_provider_completion(completion) do
    try do
      result =
        call_provider_with_retry(
          completion.provider,
          completion.state,
          completion.outbound_messages,
          completion.tool_defs,
          completion.provider_config,
          completion.streaming?,
          completion.on_chunk,
          completion.stream_tracker,
          0,
          completion.opts
        )

      {result, StreamTracker.snapshot(completion.stream_tracker)}
    after
      StreamTracker.stop(completion.stream_tracker)
    end
  end

  defp dispatch_provider_result(
         {:ok, %{stop_reason: :tool_use, messages: new_msgs, usage: usage} = response},
         completion,
         _streamed_text,
         provider_t0
       ) do
    accept_tool_use_response(completion, new_msgs, usage, response, provider_t0)
  end

  defp dispatch_provider_result(
         {:ok, %{stop_reason: :end_turn, messages: new_msgs, usage: usage} = response},
         completion,
         streamed_text,
         provider_t0
       ) do
    accept_end_turn_response(completion, new_msgs, usage, response, streamed_text, provider_t0)
  end

  defp dispatch_provider_result({:error, reason}, completion, _streamed_text, provider_t0) do
    handle_provider_error(completion, reason, provider_t0)
  end

  defp accept_tool_use_response(completion, new_msgs, usage, response, provider_t0) do
    Logger.debug(
      "[Turn] provider returned tool_use new_msgs=#{length(new_msgs)} " <>
        "duration_ms=#{System.monotonic_time(:millisecond) - provider_t0}"
    )

    state =
      record_provider_response(
        completion.state,
        completion.opts,
        new_msgs,
        usage,
        response,
        :after_tool_request,
        length(completion.outbound_messages)
      )

    continue_after_tool_request(state, new_msgs, completion.opts)
  end

  defp accept_end_turn_response(completion, new_msgs, usage, response, streamed_text, provider_t0) do
    Logger.debug(
      "[Turn] provider returned end_turn new_msgs=#{length(new_msgs)} " <>
        "duration_ms=#{System.monotonic_time(:millisecond) - provider_t0} " <>
        "usage=#{inspect(usage)}"
    )

    state =
      record_provider_response(
        completion.state,
        completion.opts,
        new_msgs,
        usage,
        response,
        :after_completion,
        length(completion.outbound_messages)
      )

    StreamTracker.emit_completion(
      completion.streaming?,
      completion.stream_tracker,
      streamed_text,
      new_msgs,
      fn payload -> emit(completion.opts, :message_delta, payload) end,
      &emit_assistant_messages(completion.opts, &1)
    )

    continue_after_end_turn(state, new_msgs, completion.opts)
  end

  defp record_provider_response(state, opts, new_msgs, usage, response, middleware, sent_count) do
    emit_provider_items(opts, new_msgs)

    state =
      state
      |> State.append_messages(new_msgs)
      |> State.increment_turn()
      |> State.merge_usage(usage)
      |> State.merge_provider_state(Map.get(response, :provider_state, %{}))
      |> State.put_provider_response_metadata(Map.get(response, :response_metadata, %{}))
      |> ModelContext.note_anchor(usage, sent_count)

    emit(opts, :usage_updated, %{usage: state.usage})
    if state.config.delegated?, do: emit(opts, :delegation_usage, state.usage)
    mw_run(state, middleware)
  end

  defp continue_after_tool_request(%State{status: :interrupted} = state, _new_msgs, opts) do
    emit(opts, :tool_approval_requested, state.interrupt_data || %{})
    state
  end

  # Auto-review can latch a stop inside this batch. Do not execute the
  # approved siblings; the turn is already over.
  defp continue_after_tool_request(%State{status: :halted} = state, new_msgs, opts) do
    finish_halted_tool_review(state, new_msgs, opts)
  end

  defp continue_after_tool_request(state, new_msgs, opts) do
    handle_tool_use(state, new_msgs, opts)
  end

  defp continue_after_end_turn(state, new_msgs, opts) do
    cond do
      missing_final_answer?(new_msgs) and not Keyword.get(opts, :empty_end_turn_retried, false) ->
        retry_missing_final_answer(state, opts)

      missing_final_answer?(new_msgs) ->
        fail_missing_final_answer(state, new_msgs)

      true ->
        continue_with_pending_or_complete(state, opts)
    end
  end

  defp retry_missing_final_answer(state, opts) do
    Logger.warning("[Turn] commentary without a final answer — requesting the final answer once")

    continue_to_next_turn(
      state,
      Keyword.put(opts, :empty_end_turn_retried, true),
      "retry_missing_final_answer"
    )
  end

  defp fail_missing_final_answer(state, new_msgs) do
    error_msg = missing_final_answer_error(new_msgs)
    Logger.warning("[Turn] #{error_msg}")

    state
    |> Map.put(:status, :error)
    |> Map.put(:error, error_msg)
    |> mw_run(:on_error)
  end

  defp missing_final_answer_error(new_msgs) do
    if commentary_only_turn?(new_msgs),
      do: "Provider ended the turn without a final answer",
      else: "Provider ended the turn with no visible assistant response or tool call"
  end

  defp handle_provider_error(completion, reason, provider_t0) do
    error_msg = format_provider_error(completion.provider_config, reason)

    if not Keyword.get(completion.opts, :prompt_too_long_retried, false) and
         prompt_too_long?(error_msg) do
      retry_prompt_too_long(completion.state, completion.opts, error_msg)
    else
      continue_or_fail_provider_error(
        completion.state,
        completion.opts,
        completion.provider,
        error_msg,
        provider_t0
      )
    end
  end

  defp retry_prompt_too_long(state, opts, error_msg) do
    Logger.info("[Turn] Prompt too long — forcing compaction and retrying")
    visible = ModelContext.visible(state)
    probe = %{state | messages: visible}
    compacted = Compactor.force_compact(probe, compaction_call_opts(state, opts))

    if compacted.messages == visible do
      state = %{state | status: :error, error: error_msg}
      mw_run(state, :on_error)
    else
      state = ModelContext.install(state, compacted.messages)
      do_completion(state, Keyword.put(opts, :prompt_too_long_retried, true))
    end
  end

  defp continue_or_fail_provider_error(state, opts, provider, error_msg, provider_t0) do
    follow_ups = drain_candidate_messages(opts, :follow_up)

    if follow_ups != [] and not Keyword.get(opts, :error_follow_up_retried, false) do
      Logger.warning(
        "[Turn] provider error, continuing with queued follow_up " <>
          "count=#{length(follow_ups)} error=#{error_msg}"
      )

      continue_with_follow_up(
        state,
        follow_ups,
        Keyword.put(opts, :error_follow_up_retried, true)
      )
    else
      fail_provider_error(state, provider, error_msg, provider_t0)
    end
  end

  defp fail_provider_error(state, provider, error_msg, provider_t0) do
    Logger.error(
      "[Turn] Provider error provider=#{inspect(provider)} " <>
        "duration_ms=#{System.monotonic_time(:millisecond) - provider_t0} " <>
        "error=#{error_msg}"
    )

    state = %{state | status: :error, error: error_msg}
    mw_run(state, :on_error)
  end

  defp continue_with_follow_up(state, follow_up_messages, opts) do
    Logger.debug("[Turn] draining follow_up messages count=#{length(follow_up_messages)}")
    emit_candidate_injected(opts, :follow_up, follow_up_messages)

    state
    |> State.append_messages(follow_up_messages)
    |> do_turn(opts)
  end

  defp continue_with_pending_or_complete(state, opts) do
    case Keyword.get(opts, :candidate_queue) do
      nil ->
        maybe_review_or_complete(state, opts, nil)

      queue ->
        if Handbean.Agent.CandidateQueue.has_pending?(queue) do
          inject_pending(state, opts, queue)
        else
          maybe_review_or_complete(state, opts, queue)
        end
    end
  end

  defp maybe_review_or_complete(state, opts, queue) do
    if Handbean.Agent.Advisor.review?(state.advisor) do
      review_before_seal(state, opts, queue)
    else
      seal_or_complete(state, opts, queue)
    end
  end

  defp review_before_seal(state, opts, queue) do
    digest = artifact_digest(state)
    request_id = "advisor-review-" <> Ecto.UUID.generate()

    state = %{
      state
      | advisor: %{
          state.advisor
          | phase: :reviewing,
            request_id: request_id,
            artifact_digest: digest
        }
    }

    case Handbean.Agent.Advisor.review(state, opts, request_id, digest) do
      {:pass, advisor} ->
        state = %{state | advisor: advisor}
        seal_or_complete(state, opts, queue)

      {:revise, advisor, feedback} ->
        state
        |> Map.put(:advisor, advisor)
        |> State.append_messages([Handbean.Agent.Message.user(feedback)])
        |> continue_to_next_turn(opts, "advisor_revision")

      {:blocked, advisor, reason} ->
        %{state | advisor: advisor, status: :error, error: "尚未通过验收: #{reason}"}

      {:stale, advisor} ->
        state
        |> Map.put(:advisor, advisor)
        |> continue_to_next_turn(opts, "advisor_stale")
    end
  end

  defp seal_or_complete(state, _opts, nil), do: %{state | status: :completed}

  defp seal_or_complete(state, opts, queue) do
    case Handbean.Agent.CandidateQueue.take_pending_or_seal(queue) do
      :sealed ->
        %{state | status: :completed}

      {:pending, %{steer: steer, follow_up: follow_ups}} ->
        emit_candidate_injected(opts, :steer, steer)
        emit_candidate_injected(opts, :follow_up, follow_ups)

        state
        |> State.append_messages(steer ++ follow_ups)
        |> continue_to_next_turn(opts, "candidate_message")
    end
  end

  defp inject_pending(state, opts, queue) do
    case Handbean.Agent.CandidateQueue.take_pending_or_seal(queue) do
      {:pending, %{steer: steer, follow_up: follow_ups}} ->
        emit_candidate_injected(opts, :steer, steer)
        emit_candidate_injected(opts, :follow_up, follow_ups)

        state
        |> State.append_messages(steer ++ follow_ups)
        |> continue_to_next_turn(opts, "candidate_message")

      :sealed ->
        %{state | status: :completed}
    end
  end

  defp stall_check?(%State{interrupt_data: %{type: :stall_check}}), do: true
  defp stall_check?(_state), do: false

  def resume_after_stall_check(%State{status: :interrupted} = state, _decisions, opts) do
    state = %{
      state
      | status: :running,
        interrupt_data: nil,
        progress:
          Handbean.Agent.ProgressGuard.grant(
            state.progress || Handbean.Agent.ProgressGuard.initial()
          )
    }

    state
    |> do_turn(opts)
    |> finish_run(opts)
  end

  def resume_after_stall_check(%State{} = state, _decisions, _opts), do: state

  defp artifact_digest(state) do
    state.messages
    |> Enum.map_join("\n", &Handbean.Agent.Message.text/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp call_provider_with_retry(
         provider,
         %State{} = state,
         outbound_messages,
         tool_defs,
         provider_config,
         streaming?,
         on_chunk,
         chunk_tracker,
         attempt,
         loop_opts
       ) do
    result =
      call_provider(provider, outbound_messages, tool_defs, provider_config, streaming?, on_chunk)

    case result do
      {:error, reason} ->
        if prompt_too_long?(format_error(reason)) do
          result
        else
          retry_config = retry_config(state, provider_config)

          case {Retry.should_retry_error?(reason, attempt, retry_config),
                StreamTracker.emitted?(chunk_tracker)} do
            {{:retry, _delay_ms}, false} ->
              if uncertain_cursor_error?(reason) do
                result
              else
                remaining = remaining_budget_ms(loop_opts)

                case Retry.delay_ms(attempt, retry_config,
                       retry_after_ms: retry_after_ms(reason),
                       remaining_ms: remaining
                     ) do
                  :budget_exceeded ->
                    {:error, {:run_budget_exceeded, reason}}

                  delay_ms ->
                    retry_provider_call(
                      provider,
                      state,
                      outbound_messages,
                      tool_defs,
                      provider_config,
                      streaming?,
                      on_chunk,
                      chunk_tracker,
                      attempt,
                      delay_ms,
                      reason,
                      loop_opts
                    )
                end
              end

            {_retry_result, _chunks_emitted?} ->
              result
          end
        end

      _ ->
        result
    end
  end

  defp retry_provider_call(
         provider,
         %State{} = state,
         outbound_messages,
         tool_defs,
         provider_config,
         streaming?,
         on_chunk,
         chunk_tracker,
         attempt,
         delay_ms,
         reason,
         loop_opts
       ) do
    notify_progress(loop_opts, :provider_retry)

    Logger.warning(fn ->
      "[Turn] provider transient error, retrying attempt=#{attempt + 1} " <>
        "delay_ms=#{delay_ms} error=#{format_error(reason)}"
    end)

    parent = self()

    receive do
      :run_cancelled ->
        {:error, {:run_cancelled, reason}}
    after
      0 ->
        if not interruptible_sleep(delay_ms, loop_opts, parent) do
          {:error, {:run_budget_exceeded, reason}}
        else
          retry_after_sleep(
            provider,
            state,
            outbound_messages,
            tool_defs,
            provider_config,
            streaming?,
            on_chunk,
            chunk_tracker,
            attempt,
            loop_opts
          )
        end
    end
  end

  defp retry_after_sleep(
         provider,
         state,
         outbound_messages,
         tool_defs,
         provider_config,
         streaming?,
         on_chunk,
         chunk_tracker,
         attempt,
         loop_opts
       ) do
    call_provider_with_retry(
      provider,
      state,
      outbound_messages,
      tool_defs,
      provider_config,
      streaming?,
      on_chunk,
      chunk_tracker,
      attempt + 1,
      loop_opts
    )
  end

  defp remaining_budget_ms(opts) do
    case Keyword.get(opts, :run_deadline) do
      deadline when is_integer(deadline) ->
        max(deadline - System.monotonic_time(:millisecond), 0)

      _ ->
        nil
    end
  end

  defp retry_after_ms(%{retry_after_ms: ms}) when is_integer(ms) and ms >= 0, do: ms

  defp retry_after_ms(%{headers: headers}) when is_list(headers) or is_map(headers) do
    header =
      Enum.find_value(headers, fn
        {key, value} -> if String.downcase(to_string(key)) == "retry-after", do: value
        _ -> nil
      end)

    if header, do: Handbean.Agent.Provider.Retry.parse_retry_after(to_string(header)), else: 0
  end

  defp retry_after_ms(_reason), do: 0

  defp interruptible_sleep(delay_ms, opts, parent) do
    deadline = Keyword.get(opts, :run_deadline)

    wait =
      if is_integer(deadline),
        do: min(delay_ms, max(deadline - System.monotonic_time(:millisecond), 0)),
        else: delay_ms

    if wait <= 0 do
      false
    else
      ref = Process.monitor(parent)

      result =
        receive do
          :run_deadline_interrupt -> false
          :run_cancelled -> false
          {:DOWN, ^ref, :process, ^parent, _reason} -> false
        after
          wait -> is_nil(deadline) or System.monotonic_time(:millisecond) < deadline
        end

      Process.demonitor(ref, [:flush])
      result
    end
  end

  defp call_provider(provider, messages, tool_defs, provider_config, true, on_chunk)
       when is_list(messages) and is_function(on_chunk, 1) do
    if Code.ensure_loaded?(provider) and function_exported?(provider, :stream, 4) do
      provider.stream(messages, tool_defs, provider_config, on_chunk)
    else
      provider.complete(messages, tool_defs, provider_config)
    end
  end

  defp call_provider(provider, messages, tool_defs, provider_config, _streaming?, _on_chunk)
       when is_list(messages) do
    provider.complete(messages, tool_defs, provider_config)
  end

  defp retry_config(%State{config: config}, provider_config) do
    provider_config
    |> Map.put_new(:max_retries, Map.get(config.provider_config, :max_retries, 3))
    |> Map.put_new(
      :retry_delay_base_ms,
      Map.get(config.provider_config, :retry_delay_base_ms, 500)
    )
  end

  defp maybe_put_provider_event_callback(provider_config, opts) do
    case Keyword.get(opts, :on_event) do
      fun when is_function(fun, 1) -> Map.put(provider_config, :on_event, fun)
      _ -> provider_config
    end
  end

  defp inject_candidate_messages(%State{} = state, opts, deliver_as) do
    case drain_candidate_messages(opts, deliver_as) do
      [] ->
        state

      messages ->
        emit_candidate_injected(opts, deliver_as, messages)
        State.append_messages(state, messages)
    end
  end

  defp drain_candidate_messages(opts, :steer) do
    case Keyword.get(opts, :candidate_queue) do
      nil -> []
      queue -> Handbean.Agent.CandidateQueue.drain_steer(queue)
    end
  end

  defp drain_candidate_messages(opts, :follow_up) do
    case Keyword.get(opts, :candidate_queue) do
      nil -> []
      queue -> Handbean.Agent.CandidateQueue.drain_follow_up(queue)
    end
  end

  defp emit_candidate_injected(opts, deliver_as, messages) do
    emit(opts, :candidate_message_injected, %{
      deliver_as: deliver_as,
      count: length(messages),
      message_ids: Enum.map(messages, & &1.id)
    })
  end

  defp log_emit(:message_delta, %{chunk: _chunk}), do: :ok

  defp log_emit(kind, payload) do
    Logger.debug("[Turn] emit #{kind} keys=#{inspect(Map.keys(payload || %{}))}")
  end

  defp finish_halted_tool_review(%State{} = state, new_msgs, opts) do
    tool_calls = extract_tool_calls(new_msgs)

    denied_by_id =
      Map.new(state.tool_guard_result_blocks || [], fn block ->
        {Handbean.Utils.SafeMap.get_any(block, [:tool_use_id, "tool_use_id"]), block}
      end)

    blocks =
      Enum.map(tool_calls, fn call ->
        id = Handbean.Utils.SafeMap.get_any(call, [:id, "id"])

        Map.get(denied_by_id, id) ||
          Message.tool_result_block(
            id,
            state.error || Handbean.Permissions.AutoReview.halt_error(),
            true,
            %{
              permission: :denied,
              tool: Handbean.Utils.SafeMap.get_any(call, [:name, "name"]),
              reviewer: :auto_review
            }
          )
      end)

    Enum.each(blocks, fn block ->
      emit(opts, :tool_end, %{
        tool_use_id: block[:tool_use_id],
        tool: get_in(block, [:details, :tool]) || "unknown",
        turn_number: state.turn,
        duration_ms: 0,
        timing_fidelity: "not_started",
        details: bounded_tool_details(block[:details] || %{}),
        error: bounded_tool_error(block[:content]),
        output: bounded_tool_output(block[:content])
      })
    end)

    state
    |> State.append_messages([Message.tool_results(blocks)])
    |> Map.put(:status, :halted)
  end

  defp handle_tool_use(%State{} = state, new_msgs, opts) do
    tool_calls = extract_tool_calls(new_msgs)
    session_id = Keyword.get(opts, :session_id)

    Logger.debug(
      "[Turn] handle_tool_use count=#{length(tool_calls)} tools=#{inspect(Enum.map(tool_calls, & &1[:name]))}"
    )

    active_set = if session_id, do: Handbean.Tool.Registry.active_for_session(session_id)

    {blocked_calls, allowed_calls_w_ctx} =
      gate_tool_calls(state, tool_calls, session_id, active_set)

    {blocked_calls, allowed_calls_w_ctx} =
      reject_unauthorized_rewrites(state, blocked_calls, allowed_calls_w_ctx, active_set)

    emit_allowed_tool_starts(allowed_calls_w_ctx, opts, state)

    denied_blocks =
      Enum.map(blocked_calls, fn {call, block_source} ->
        blocked_tool_result_block(call, block_source)
      end)

    allowed_calls = Enum.map(allowed_calls_w_ctx, fn {call, _ctx} -> call end)
    execute_or_skip_blocked_tools(state, allowed_calls, denied_blocks, opts)
  end

  defp gate_tool_calls(_state, tool_calls, nil, _active_set) do
    {[], Enum.map(tool_calls, &{&1, %{}})}
  end

  defp gate_tool_calls(state, tool_calls, session_id, active_set) do
    {blocked, allowed} =
      Enum.reduce(tool_calls, {[], []}, fn call, acc ->
        fold_tool_call_gate(state, session_id, active_set, call, acc)
      end)

    {Enum.reverse(blocked), Enum.reverse(allowed)}
  end

  defp fold_tool_call_gate(state, session_id, active_set, call, {blocked, allowed}) do
    case run_extension_hook(state, session_id, tool_call_hook_event(call, session_id)) do
      {:block, reason} ->
        {[{call, {:extension, reason}} | blocked], allowed}

      {:transform, %{args: transformed_args} = ctx} when is_map(transformed_args) ->
        mutated = %{call | input: Map.merge(call[:input] || %{}, transformed_args)}
        {blocked, [{mutated, ctx} | allowed]}

      {:transform, _ctx} ->
        {blocked, [{call, %{}} | allowed]}

      _ ->
        classify_active_set(call, active_set, blocked, allowed)
    end
  end

  defp tool_call_hook_event(call, session_id) do
    {:tool_call,
     %{
       tool_use_id: call[:id],
       tool_name: call[:name],
       args: call[:input] || %{},
       session_id: session_id,
       parent_tool_call_id: nil
     }}
  end

  defp classify_active_set(call, active_set, blocked, allowed) do
    if active_set != nil and call[:name] not in active_set do
      {[{call, :active_set} | blocked], allowed}
    else
      {blocked, [{call, %{}} | allowed]}
    end
  end

  # Hooks cannot bypass the active set. An argument rewrite must also be
  # independently authorized: approval of the original call ID is not
  # approval of different arguments under that same ID.
  defp reject_unauthorized_rewrites(state, blocked_calls, allowed_calls_w_ctx, active_set) do
    {unauthorized, allowed_calls_w_ctx} =
      Enum.split_with(allowed_calls_w_ctx, fn {call, ctx} ->
        unauthorized_rewrite?(state, call, ctx, active_set)
      end)

    {blocked_calls ++ unauthorized_extension_blocks(unauthorized), allowed_calls_w_ctx}
  end

  defp unauthorized_rewrite?(state, call, ctx, active_set) do
    inactive? = active_set != nil and call[:name] not in active_set
    rewritten? = Map.has_key?(ctx, :args)

    policy =
      Handbean.Permissions.ToolPolicy.from_workspace(
        state.config.workspace_path || state.config.working_directory,
        state.config.working_directory,
        %{},
        state.tool_guard_session_allow || []
      )

    inactive? or (rewritten? and Handbean.Permissions.ToolPolicy.decision(policy, call) != :auto)
  end

  defp unauthorized_extension_blocks(unauthorized) do
    Enum.map(unauthorized, fn {call, _} ->
      {call,
       {:extension, "Transformed call is not authorized by workspace permissions or active tools"}}
    end)
  end

  defp emit_allowed_tool_starts(allowed_calls_w_ctx, opts, state) do
    denied_ids =
      state.tool_guard_result_blocks
      |> List.wrap()
      |> Enum.map(&Handbean.Utils.SafeMap.get_any(&1, [:tool_use_id, "tool_use_id"]))
      |> MapSet.new()

    calls =
      allowed_calls_w_ctx
      |> Enum.map(fn {call, _ctx} -> call end)
      |> Enum.reject(&MapSet.member?(denied_ids, Handbean.Utils.SafeMap.get_any(&1, [:id, "id"])))

    emit_tool_starts(calls, opts, state.turn)
  end

  defp emit_tool_starts(calls, opts, turn_number) do
    Enum.each(calls, fn call ->
      emit(opts, :tool_start, %{
        tool_use_id: call[:id],
        tool: call[:name],
        input: redact_tool_input(call[:name], call[:input] || %{}),
        parent_tool_call_id: nil,
        turn_number: turn_number
      })
    end)
  end

  defp execute_or_skip_blocked_tools(state, [], denied_blocks, opts) do
    emit_denied_tool_end_events(denied_blocks, opts, state.turn)
    result_msg = Message.tool_results(Enum.reverse(denied_blocks))

    state
    |> append_tool_results([result_msg])
    |> mw_run(:after_tool_execution)
    |> inject_candidate_messages(opts, :steer)
    |> continue_to_next_turn(opts, "tool_use")
  end

  defp execute_or_skip_blocked_tools(state, allowed_calls, denied_blocks, opts) do
    t0 = System.monotonic_time(:millisecond)

    case execute_tool_calls_with_guard_results(allowed_calls, state) do
      {:ok, result_msg, ui_blocks, state} ->
        finish_allowed_tool_execution(%{
          state: state,
          allowed_calls: allowed_calls,
          result_msg: result_msg,
          ui_blocks: ui_blocks,
          denied_blocks: denied_blocks,
          opts: opts,
          t0: t0
        })
    end
  end

  defp finish_allowed_tool_execution(execution) do
    duration_ms = System.monotonic_time(:millisecond) - execution.t0

    Logger.debug(
      "[Turn] tool execution complete count=#{length(execution.allowed_calls)} duration_ms=#{duration_ms}"
    )

    emit_executed_tool_ends(
      execution.state,
      execution.allowed_calls,
      execution.ui_blocks,
      execution.opts,
      duration_ms
    )

    emit_denied_tool_end_events(
      execution.denied_blocks,
      execution.opts,
      execution.state.turn
    )

    merged_msg = %{
      execution.result_msg
      | content:
          Enum.map(execution.ui_blocks ++ execution.denied_blocks, &Executor.strip_details/1)
    }

    execution.state
    |> append_tool_results([merged_msg])
    |> Map.update!(:messages, &Handbean.Tool.Images.bound_history/1)
    |> mw_run(:after_tool_execution)
    |> inject_candidate_messages(execution.opts, :steer)
    |> continue_to_next_turn(execution.opts, "tool_use")
  end

  defp emit_executed_tool_ends(state, allowed_calls, ui_blocks, opts, duration_ms) do
    ui_block_by_id = Map.new(ui_blocks, fn block -> {block[:tool_use_id], block} end)

    Enum.each(allowed_calls, fn call ->
      ui_block = Map.get(ui_block_by_id, call[:id])
      record_tool_receipt(state, call, ui_block)

      emit(
        opts,
        :tool_end,
        executed_tool_end_payload(call, ui_block, duration_ms, state.turn)
      )
    end)
  end

  defp executed_tool_end_payload(call, ui_block, _batch_duration_ms, turn_number) do
    details = (ui_block && ui_block[:details]) || %{}

    payload =
      %{
        tool_use_id: call[:id],
        tool: call[:name],
        parent_tool_call_id: nil,
        turn_number: turn_number,
        details: bounded_tool_details(details),
        file_path: tool_end_file_path(details, call),
        images: Handbean.Tool.Images.project(ui_block && ui_block[:images]),
        published_media: Handbean.Media.project(ui_block && ui_block[:published_media]),
        output: bounded_tool_output(ui_block && ui_block[:content])
      }
      |> Map.merge(tool_timing_payload(details))
      |> maybe_put_not_started_timing(details)

    if ui_block && ui_block[:is_error] do
      Map.put(payload, :error, bounded_tool_error(ui_block[:content]))
    else
      payload
    end
  end

  defp maybe_put_not_started_timing(payload, details) do
    permission = Handbean.Utils.SafeMap.get_any(details, [:permission, "permission"])
    side_effect = Handbean.Utils.SafeMap.get_any(details, [:side_effect, "side_effect"])

    if is_nil(payload[:timing_fidelity]) and
         (permission in [:denied, "denied"] or side_effect in [:not_started, "not_started"]) do
      Map.merge(payload, %{duration_ms: 0, timing_fidelity: "not_started"})
    else
      payload
    end
  end

  defp tool_timing_payload(details) do
    %{
      started_at: Handbean.Utils.SafeMap.get_any(details, [:started_at, "started_at"]),
      completed_at: Handbean.Utils.SafeMap.get_any(details, [:completed_at, "completed_at"]),
      duration_ms: Handbean.Utils.SafeMap.get_any(details, [:duration_ms, "duration_ms"]),
      timing_fidelity:
        Handbean.Utils.SafeMap.get_any(details, [:timing_fidelity, "timing_fidelity"])
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp tool_end_file_path(details, call) do
    input = Handbean.Utils.SafeMap.get_any(call || %{}, [:input, "input"]) || %{}

    Handbean.Utils.SafeMap.get_any(details || %{}, [:file_path, "file_path"]) ||
      Handbean.Utils.SafeMap.get_any(input, [:file_path, "file_path"])
  end

  defp block_content(block) do
    Handbean.Utils.SafeMap.get_any(block, [:content, "content"])
  end

  defp execute_tool_calls_with_guard_results(
         tool_calls,
         %State{tool_guard_result_blocks: []} = state
       ) do
    Executor.execute_all_with_context(tool_calls, state)
  end

  defp execute_tool_calls_with_guard_results(
         tool_calls,
         %State{tool_guard_result_blocks: denied_blocks} = state
       )
       when is_list(denied_blocks) do
    denied_ids =
      MapSet.new(
        Enum.map(
          denied_blocks,
          &Handbean.Utils.SafeMap.get_any(&1, [:tool_use_id, "tool_use_id"])
        )
      )

    executable_calls =
      Enum.reject(
        tool_calls,
        &MapSet.member?(denied_ids, Handbean.Utils.SafeMap.get_any(&1, [:id, "id"]))
      )

    with {:ok, result_msg, ui_blocks, state} <-
           Executor.execute_all_with_context(executable_calls, state) do
      all_ui_blocks = order_guarded_blocks(tool_calls, ui_blocks ++ denied_blocks)

      {:ok, %{result_msg | content: Enum.map(all_ui_blocks, &Executor.strip_details/1)},
       all_ui_blocks, state}
    end
  end

  defp order_guarded_blocks(tool_calls, blocks) do
    by_id =
      Map.new(blocks, fn block ->
        {Handbean.Utils.SafeMap.get_any(block, [:tool_use_id, "tool_use_id"]), block}
      end)

    Enum.map(tool_calls, &Map.fetch!(by_id, Handbean.Utils.SafeMap.get_any(&1, [:id, "id"])))
  end

  defp build_provider_config(%State{config: config, provider_state: provider_state} = state) do
    config.provider_config
    |> Map.put(:model, config.model)
    |> Map.put(:system_prompt, config.system_prompt)
    |> Map.put(:provider_state, provider_state)
    |> Map.put(:context_generation, state.context_generation || 0)
    |> Map.put(:working_directory, config.working_directory)
    |> maybe_put_context(config)
    |> apply_reasoning_level(config)
  end

  defp apply_reasoning_level(provider_config, config) do
    model_entry =
      case Map.get(provider_config, :model_meta) do
        meta when is_map(meta) and map_size(meta) > 0 ->
          meta
          |> Map.put_new("id", config.model)
          |> Map.put_new(:provider, Map.get(provider_config, :provider))
          |> Map.put_new(:provider_id, Map.get(provider_config, :provider_key))
          |> Map.put_new(:api, Map.get(provider_config, :api))

        _ ->
          %{
            id: config.model,
            provider: Map.get(provider_config, :provider),
            provider_id: Map.get(provider_config, :provider_key),
            api: Map.get(provider_config, :api)
          }
      end

    Reasoning.apply_provider_options(provider_config, model_entry, config.reasoning_level)
  end

  defp maybe_put_context(provider_config, config) do
    context = config.context || %{}

    provider_config
    |> maybe_put(:conversation_id, context[:conversation_id])
    |> maybe_put(:run_id, context[:run_id])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp extract_tool_calls(messages) do
    Enum.flat_map(messages, &Message.tool_calls/1)
  end

  defp bounded_tool_output(output) when is_binary(output),
    do: String.slice(output, 0, @max_tool_event_output)

  defp bounded_tool_output(output), do: Handbean.JsonSafe.normalize(output)

  defp bounded_tool_error(error) when is_binary(error),
    do: String.slice(error, 0, @max_tool_event_output)

  defp bounded_tool_error(error), do: error

  defp bounded_tool_details(details) do
    Handbean.Agent.Tool.ResultContract.project_details(details || %{})
  end

  defp record_tool_receipt(state, call, ui_block) do
    conversation_id = state.config.context[:conversation_id]
    call_id = call[:id]

    if is_binary(conversation_id) and is_binary(call_id) do
      details = (ui_block && ui_block[:details]) || %{}

      side_effect =
        Handbean.Utils.SafeMap.get_any(details, [:side_effect, "side_effect"]) || :unknown

      Handbean.Agent.OperationReceipt.reserve(
        {:tool_effect, conversation_id},
        call_id,
        Handbean.Agent.OperationReceipt.fingerprint({call[:name], side_effect})
      )

      Handbean.Agent.OperationReceipt.complete(
        {:tool_effect, conversation_id},
        call_id,
        %{
          "tool" => call[:name],
          "side_effect" => to_string(side_effect),
          "operation_id" =>
            Handbean.Utils.SafeMap.get_any(details, [:operation_id, "operation_id"])
        }
      )
    end

    :ok
  end

  # ── Error formatting ──

  defp uncertain_cursor_error?(reason) when is_binary(reason) do
    String.contains?(reason, "not retrying because execution may have started")
  end

  defp uncertain_cursor_error?(_), do: false

  defp prompt_too_long?(reason) when is_binary(reason) do
    normalized = String.downcase(reason)

    String.contains?(normalized, "context_length_exceeded") or
      String.contains?(normalized, "maximum context length") or
      String.contains?(normalized, "prompt is too long") or
      String.contains?(normalized, "prompt too long") or
      (String.contains?(normalized, "exceeded request buffer limit") and
         (String.contains?(normalized, "507") or String.contains?(normalized, "context") or
            String.contains?(normalized, "prompt")))
  end

  defp prompt_too_long?(_), do: false

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason) when is_exception(reason), do: Exception.message(reason)
  defp format_error(reason), do: inspect(reason)

  # Auth failures otherwise look like the conversation model failed. Name the
  # provider, subscription, and model that actually made the request.
  defp format_provider_error(provider_config, reason) do
    message = format_error(reason)

    if auth_failure?(message) do
      prefix = auth_failure_prefix(provider_config)
      if prefix == "", do: message, else: "#{prefix}: #{message}"
    else
      message
    end
  end

  defp auth_failure?(message) when is_binary(message) do
    downcased = String.downcase(message)

    String.contains?(downcased, "oauth") or
      String.contains?(downcased, "access token") or
      String.contains?(downcased, "authorization") or
      String.contains?(downcased, "unauthor") or
      String.contains?(downcased, "sign in") or
      String.contains?(message, "订阅") or
      String.contains?(message, "授权") or
      String.contains?(message, "重新登录") or
      String.contains?(message, "重新连接")
  end

  defp auth_failure?(_), do: false

  defp auth_failure_prefix(provider_config) when is_map(provider_config) do
    provider_id = provider_config[:provider_key] || provider_config[:provider]
    model = provider_config[:model]

    [subscription_label(provider_id), model_label(provider_id, model)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp auth_failure_prefix(_), do: ""

  defp subscription_label(provider_id) when is_binary(provider_id) do
    case Handbean.Agent.Auth.Subscriptions.get(provider_id) do
      {:ok, %{login_label: label}} when is_binary(label) and label != "" -> label
      _ -> provider_id
    end
  end

  defp subscription_label(provider_id) when is_atom(provider_id) and not is_nil(provider_id) do
    subscription_label(Atom.to_string(provider_id))
  end

  defp subscription_label(_), do: nil

  defp model_label(_provider_id, model) when is_binary(model) and model != "", do: model
  defp model_label(_provider_id, _), do: nil

  defp redact_tool_input("publish_media", input) when is_map(input),
    do: Handbean.Tool.Builtin.PublishMedia.public_input(input)

  defp redact_tool_input("browser", input) when is_map(input) do
    input = Handbean.Log.Redactor.redact(input)
    args = Map.get(input, "args") || Map.get(input, :args)

    if is_list(args) do
      redacted = Handbean.Browser.Redactor.redact_args(args)

      input
      |> Map.put("args", redacted)
      |> Map.delete(:args)
    else
      input
    end
  end

  defp redact_tool_input(_name, input), do: Handbean.Log.Redactor.redact(input)
end
