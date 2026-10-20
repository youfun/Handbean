defmodule Handbean.Agent.Turn do
  @moduledoc """
  The core agent loop.

  Sends messages to a provider, executes tool calls, and loops until
  the provider signals completion or the turn limit is reached.

  This is a pure function — no GenServer, no process overhead.
  """

  alias Handbean.Agent.{Compactor, Message, ModelContext, State}
  alias Handbean.Agent.Middleware
  alias Handbean.Agent.Middleware.ToolGuard
  alias Handbean.Agent.Tool.{Catalog, Executor}

  alias Handbean.Agent.Turn.{
    CandidateMessages,
    Completion,
    Events,
    Hooks,
    ProviderInvocation,
    StreamTracker,
    ToolExecution
  }

  require Logger

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
    Events.emit_denied_tool_ends(denied_blocks, opts, state.turn)
    emit_resumed_turn_end(state, opts)
    result_msg = Message.tool_results(denied_blocks)

    state
    |> ToolExecution.append_results([result_msg])
    |> mw_run(:after_tool_execution)
    |> CandidateMessages.inject(opts, :steer)
    |> do_turn(opts)
  end

  defp continue_after_approval(state, executable, batch_calls, denied_blocks, opts) do
    Events.emit_tool_starts(executable, opts, state.turn)

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
      ToolExecution.order_guarded_blocks(
        execution.batch_calls,
        execution.ui_blocks ++ execution.denied_blocks
      )

    merged_msg = %{
      execution.result_msg
      | content: Enum.map(all_ui_blocks, &Executor.strip_details/1)
    }

    Events.emit_tool_ends(
      execution.executable,
      execution.ui_blocks,
      execution.opts,
      execution.state.turn
    )

    Events.emit_denied_tool_ends(
      execution.denied_blocks,
      execution.opts,
      execution.state.turn
    )

    emit_resumed_turn_end(execution.state, execution.opts)

    execution.state
    |> ToolExecution.append_results([merged_msg])
    |> Map.update!(:messages, &Handbean.Tool.Images.bound_history/1)
    |> mw_run(:after_tool_execution)
    |> CandidateMessages.inject(execution.opts, :steer)
    |> do_turn(execution.opts)
  end

  defp emit_resumed_turn_end(state, opts) do
    Events.emit_turn_end(opts, %{
      turn: state.turn,
      stop_reason: "tool_use_resumed",
      status: :completed
    })
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
    Events.reset_turn_end_counter()

    Logger.info(
      "[Turn] run_loop start model=#{state.config.model} " <>
        "max_turns=#{state.config.max_turns} streaming=#{Keyword.get(opts, :streaming, false)} " <>
        "messages=#{length(state.messages)}"
    )

    # session_start middleware
    state = mw_run(state, :session_start)

    # before_agent_start hook (blockable — call HookPipeline directly)
    state = Hooks.before_agent_start(state, opts)

    if state.status == :halted do
      Logger.warning("[Turn] before_agent_start blocked: #{state.error}")

      Events.emit(opts, :run_end, %{
        status: state.status,
        error: state.error,
        turns: 0,
        duration_ms: 0,
        model: state.config.model,
        loop_owner: :handbean,
        run_id: state.config.run_id
      })

      Events.emit(opts, :agent_end, %{
        status: state.status,
        error: state.error,
        turns: 0,
        run_id: state.config.run_id
      })

      # session_end middleware
      mw_run(state, :session_end)
    else
      Events.emit(opts, :run_start, %{model: state.config.model, loop_owner: :handbean})

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
    public_result =
      case result.error do
        {%Handbean.Agent.ErrorReporter.AgentRunError{} = exception, stacktrace}
        when is_list(stacktrace) ->
          %{result | error: Exception.message(exception)}

        _ ->
          result
      end

    payload = Events.run_end_payload(public_result, duration_ms)
    Events.emit(opts, :run_end, payload)
    Events.emit(opts, :agent_end, payload)
    mw_run(result, :session_end)
  end

  defp mw_run(%State{} = state, hook) do
    middleware = state.config.middleware || []

    case Middleware.run(hook, state, middleware) do
      {:halted, _reason} -> %{state | status: :halted}
      {:interrupted, %State{} = s, _data} -> s
      {:tool_guard_denied, %State{} = s} -> s
      %State{} = s -> s
    end
  end

  # ── Event and completion helpers ──

  defp turn_end_count, do: Events.turn_end_count()
  defp emit(opts, kind, payload), do: Events.emit(opts, kind, payload)
  defp emit_provider_items(opts, messages), do: Events.emit_provider_items(opts, messages)
  defp emit_assistant_messages(opts, messages), do: Events.emit_assistant_messages(opts, messages)
  defp missing_final_answer?(messages), do: Completion.missing_final_answer?(messages)

  defp tool_approval_interrupted?(%State{
         status: :interrupted,
         interrupt_data: %{type: :tool_approval}
       }),
       do: true

  defp tool_approval_interrupted?(_state), do: false

  defp continue_to_next_turn(state, opts, stop_reason) do
    Events.emit_turn_end(opts, %{
      turn: state.turn,
      stop_reason: stop_reason,
      status: if(state.status == :running, do: :completed, else: state.status)
    })

    do_turn(state, opts)
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
      |> CandidateMessages.inject(opts, :steer)
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
      Events.emit_turn_end(opts, %{
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
        Events.emit_turn_end(opts, %{
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
      |> ProviderInvocation.build_config()
      |> Map.put(:run_deadline, Keyword.get(opts, :run_deadline))

    case Hooks.apply_context(state, provider_config, opts) do
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

    provider_config =
      ProviderInvocation.prepare_config(provider_config, opts, streaming?, on_chunk)

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

    {provider_result, streamed_text} = ProviderInvocation.invoke(completion)

    dispatch_provider_result(provider_result, completion, streamed_text, provider_t0)
  end

  defp compaction_call_opts(state, opts) do
    provider_config =
      state
      |> ProviderInvocation.build_config()
      |> Map.delete(:provider_state)

    [tool_defs: Catalog.active_defs(state, opts), provider_config: provider_config]
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

  defp missing_final_answer_error(new_msgs),
    do: Completion.missing_final_answer_error(new_msgs)

  defp handle_provider_error(completion, reason, provider_t0) do
    error_msg = ProviderInvocation.format_provider_error(completion.provider_config, reason)

    if not Keyword.get(completion.opts, :prompt_too_long_retried, false) and
         ProviderInvocation.prompt_too_long?(error_msg) do
      retry_prompt_too_long(completion.state, completion.opts, error_msg)
    else
      continue_or_fail_provider_error(
        completion.state,
        completion.opts,
        completion.provider,
        error_msg,
        provider_t0,
        reason
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

  defp continue_or_fail_provider_error(state, opts, provider, error_msg, provider_t0, reason) do
    follow_ups = CandidateMessages.drain(opts, :follow_up)

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
      fail_provider_error(state, provider, error_msg, provider_t0, reason)
    end
  end

  defp fail_provider_error(state, provider, error_msg, provider_t0, reason) do
    Logger.error(
      "[Turn] Provider error provider=#{inspect(provider)} " <>
        "duration_ms=#{System.monotonic_time(:millisecond) - provider_t0} " <>
        "error=#{error_msg}"
    )

    error =
      case reason do
        {%Handbean.Agent.ErrorReporter.AgentRunError{}, stacktrace} when is_list(stacktrace) ->
          reason

        _ ->
          error_msg
      end

    state = %{state | status: :error, error: error}
    mw_run(state, :on_error)
  end

  defp continue_with_follow_up(state, follow_up_messages, opts) do
    Logger.debug("[Turn] draining follow_up messages count=#{length(follow_up_messages)}")
    CandidateMessages.emit_injected(opts, :follow_up, follow_up_messages)

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
    digest = Completion.artifact_digest(state)
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
        CandidateMessages.emit_injected(opts, :steer, steer)
        CandidateMessages.emit_injected(opts, :follow_up, follow_ups)

        state
        |> State.append_messages(steer ++ follow_ups)
        |> continue_to_next_turn(opts, "candidate_message")
    end
  end

  defp inject_pending(state, opts, queue) do
    case Handbean.Agent.CandidateQueue.take_pending_or_seal(queue) do
      {:pending, %{steer: steer, follow_up: follow_ups}} ->
        CandidateMessages.emit_injected(opts, :steer, steer)
        CandidateMessages.emit_injected(opts, :follow_up, follow_ups)

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

  defp finish_halted_tool_review(%State{} = state, new_msgs, opts),
    do: ToolExecution.finish_halted_review(state, new_msgs, opts)

  defp handle_tool_use(%State{} = state, new_msgs, opts) do
    tool_calls = ToolExecution.extract_tool_calls(new_msgs)
    session_id = Keyword.get(opts, :session_id)

    Logger.debug(
      "[Turn] handle_tool_use count=#{length(tool_calls)} tools=#{inspect(Enum.map(tool_calls, & &1[:name]))}"
    )

    active_set = if session_id, do: Handbean.Tool.Registry.active_for_session(session_id)

    {blocked_calls, allowed_calls_w_ctx} =
      ToolExecution.gate_tool_calls(state, tool_calls, session_id, active_set)

    {blocked_calls, allowed_calls_w_ctx} =
      ToolExecution.reject_unauthorized_rewrites(
        state,
        blocked_calls,
        allowed_calls_w_ctx,
        active_set
      )

    ToolExecution.emit_allowed_tool_starts(allowed_calls_w_ctx, opts, state)

    denied_blocks =
      Enum.map(blocked_calls, fn {call, block_source} ->
        ToolExecution.blocked_result_block(call, block_source)
      end)

    allowed_calls = Enum.map(allowed_calls_w_ctx, fn {call, _ctx} -> call end)
    execute_or_skip_blocked_tools(state, allowed_calls, denied_blocks, opts)
  end

  defp execute_or_skip_blocked_tools(state, [], denied_blocks, opts) do
    Events.emit_denied_tool_ends(denied_blocks, opts, state.turn)
    result_msg = Message.tool_results(Enum.reverse(denied_blocks))

    state
    |> ToolExecution.append_results([result_msg])
    |> mw_run(:after_tool_execution)
    |> CandidateMessages.inject(opts, :steer)
    |> continue_to_next_turn(opts, "tool_use")
  end

  defp execute_or_skip_blocked_tools(state, allowed_calls, denied_blocks, opts) do
    t0 = System.monotonic_time(:millisecond)

    case ToolExecution.execute_with_guard_results(allowed_calls, state) do
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

    Events.emit_executed_tool_ends(
      execution.state,
      execution.allowed_calls,
      execution.ui_blocks,
      execution.opts,
      duration_ms
    )

    Events.emit_denied_tool_ends(
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
    |> ToolExecution.append_results([merged_msg])
    |> Map.update!(:messages, &Handbean.Tool.Images.bound_history/1)
    |> mw_run(:after_tool_execution)
    |> CandidateMessages.inject(execution.opts, :steer)
    |> continue_to_next_turn(execution.opts, "tool_use")
  end
end
