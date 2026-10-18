defmodule Handbean.Agent.Tool.Executor do
  @moduledoc """
  Executes tool calls and returns result messages.

  Uses `Handbean.Agent.Tool.Result` for dual-channel content/details separation
  and `Handbean.Utils.Truncate` for consistent output truncation.

  Supports parallel execution via Task.async_stream.
  """

  alias Handbean.Agent.{ErrorReporter, Message, ModelContext, State}
  alias Handbean.Agent.Tool.{Result, ResultContract}
  alias Handbean.Extension.HookPipeline
  alias Handbean.Permissions.ToolPolicy
  alias Handbean.Utils.SafeMap

  require Logger

  @default_max_result_chars 50_000
  @spill_head_chars 2_000
  @builtin_memory_tools ~w(mem_associate mem_forget mem_learn mem_recall mem_reflect mem_reinforce mem_update)

  @doc """
  Execute all tool calls and return a result message or halt signal.

  Tool results are wrapped in `ToolResult`, truncated consistently,
  and mapped to provider-compatible `tool_result_block` maps.
  UI details (exit_code, timed_out, file metadata, etc.) are preserved
  in the `"details"` key of each block and are not sent to the LLM.

  A failed call keeps its concrete error and, when the tool defines one,
  appends that tool's bounded recovery hint to the model-facing content.

  This is the main entry point used by the agent Turn loop.
  Internally calls `execute_all_with_context/2` and returns only the
  stripped result message.
  """
  @spec execute_all([map()], State.t()) :: {:ok, Message.t()}
  def execute_all(tool_calls, %State{} = state) do
    {:ok, result_msg, _ui_blocks, _state} = execute_all_with_context(tool_calls, state)
    {:ok, result_msg}
  end

  @doc """
  Execute all tool calls and return both the stripped LLM-facing result
  and the unstripped UI blocks.

  Returns `{:ok, result_msg, ui_blocks}` where:
    - `result_msg` is a `Message.tool_results` with `"details"` stripped
    - `ui_blocks` is the list of pre-strip blocks that still contain
      `"details"` (exit_code, file_path, bytes, lines, etc.)

  The caller (Turn) appends `result_msg` to state history and broadcasts
  `ui_blocks` details to the UI via PubSub tool_end events.
  """
  @spec execute_all_with_details([map()], State.t()) :: {:ok, Message.t(), [map()]}
  def execute_all_with_details(tool_calls, %State{} = state) do
    {:ok, result_msg, ui_blocks, _state} = execute_all_with_context(tool_calls, state)
    {:ok, result_msg, ui_blocks}
  end

  @doc """
  Execute tool calls and install any committed model-context edit.

  `edit_context` proposes a revised transcript. This installs that revision
  once, before the tool result is appended, and threads it into the next
  sequential call. A failed edit stays an error result and does not install.
  """
  @spec execute_all_with_context([map()], State.t()) ::
          {:ok, Message.t(), [map()], State.t()}
  def execute_all_with_context(tool_calls, %State{} = state) do
    execute_all_with_context(tool_calls, state, caller: :model)
  end

  @doc """
  Run one registered tool from the executor, including nested-only tools.

  This is not a model-facing tool. Session active-set, MCP scope, workspace
  access, and run authorization still apply. A nested call carries
  `parent_tool_call_id` on the existing `tool_call`, `tool_start`, and
  `tool_end` events.
  """
  @spec execute_nested(String.t(), map(), State.t(), keyword()) ::
          {:ok, String.t(), map()} | {:error, String.t(), map()}
  def execute_nested(name, input, %State{} = state, opts \\ []) when is_binary(name) do
    parent_tool_call_id = Keyword.get(opts, :parent_tool_call_id)
    id = Keyword.get(opts, :tool_call_id) || nested_call_id(parent_tool_call_id)
    call = %{id: id, name: name, input: input || %{}}
    context = build_context(state, caller: :nested, parent_tool_call_id: parent_tool_call_id)

    tool_fns =
      Handbean.Tool.Registry.tool_fns()
      |> Map.take(authorized_tools(state.config))

    session_id = context[:conversation_id] || context[:session_id] || "nested"

    hook_payload =
      call
      |> tool_hook_payload(session_id, parent_tool_call_id)
      |> Map.put(:turn_number, state.turn)

    case authorize_nested(name, tool_fns, context, state) do
      :ok ->
        case run_tool_hook(state, session_id, {:tool_call, hook_payload}) do
          {:block, reason} ->
            {:error, "Tool call blocked: #{reason}", %{}}

          hook_result ->
            call = apply_hook_args(call, hook_result)

            start_payload =
              call
              |> tool_hook_payload(session_id, parent_tool_call_id)
              |> Map.put(:turn_number, state.turn)
              |> Map.put(:input, public_tool_input(call.name, call.input || %{}))
              |> Map.update!(:args, &public_tool_input(call.name, &1))

            emit_nested(opts, :tool_start, start_payload)

            {block, _revised} =
              execute_one_with_timeout(
                call,
                tool_fns,
                context,
                timeout_for(call, tool_fns, state)
              )

            report_tool_error(call, block, context)

            emit_nested(
              opts,
              :tool_end,
              nested_end_payload(call, block, parent_tool_call_id, state.turn)
              |> Map.update(:details, %{}, &Handbean.Agent.Tool.ResultContract.project_details/1)
              |> Map.update(:output, nil, &String.slice(to_string(&1), 0, 16_000))
              |> Map.update(:error, nil, fn
                nil -> nil
                error -> String.slice(to_string(error), 0, 16_000)
              end)
            )

            nested_outcome(block)
        end

      {:error, reason} ->
        {:error, reason, %{}}
    end
  end

  defp execute_all_with_context(tool_calls, %State{} = state, exec_opts) do
    tool_fns =
      Handbean.Tool.Registry.tool_fns()
      |> Map.take(authorized_tools(state.config))

    {sequential, concurrent} = partition_by_concurrency(tool_calls, tool_fns)

    Logger.debug(
      "[Executor] dispatch sequential=#{length(sequential)} concurrent=#{length(concurrent)}"
    )

    {seq_results, state} =
      Enum.map_reduce(sequential, state, fn call, state ->
        context = build_context(state, exec_opts)

        {block, revised} =
          execute_one_with_timeout(call, tool_fns, context, timeout_for(call, tool_fns, state))

        {block, install_context(state, revised)}
      end)

    context = build_context(state, exec_opts)

    # Phase 2: Concurrent tools
    par_results =
      if concurrent == [] do
        []
      else
        stream =
          Task.Supervisor.async_stream_nolink(
            task_supervisor(context),
            concurrent,
            &execute_one(&1, tool_fns, context),
            timeout: timeout_for(hd(concurrent), tool_fns, state),
            ordered: true,
            on_timeout: :kill_task
          )

        stream
        |> Enum.with_index()
        |> Enum.map(fn
          {{:ok, result}, _idx} ->
            result

          {{:exit, reason}, idx} ->
            tc = Enum.at(concurrent, idx)

            tool_id =
              (tc && SafeMap.get_any(tc, [:id, "id"])) || "unknown"

            tool_name =
              (tc && SafeMap.get_any(tc, [:name, "name"])) || "unknown"

            Logger.warning(fn ->
              "[Executor] concurrent tool timeout/exit tool=#{tool_name} id=#{tool_id} " <>
                "reason=#{inspect(reason)}"
            end)

            result_to_block(
              Result.error(
                failure_content("Tool execution timed out", tool_fns, tool_name),
                %{code: :tool_timeout, side_effect: :unknown}
              ),
              tool_id
            )
        end)
      end

    # Reassemble in original order (pre-strip blocks with details intact)
    ui_blocks =
      reassemble_ordered(tool_calls, sequential, seq_results, concurrent, par_results)

    Enum.zip_with(tool_calls, ui_blocks, &report_tool_error(&1, &2, context))

    # Strip details for LLM-friendly message
    results = Enum.map(ui_blocks, &strip_details/1)

    {:ok, Message.tool_results(results), ui_blocks, state}
  end

  @doc """
  Strip the `:details` key from a tool_result block.

  Details (exit_code, timed_out, file metadata, etc.) are preserved
  for UI via PubSub tool_end events, but must NOT be stored in
  conversation history or sent to the LLM.
  """
  def strip_details(block) when is_map(block) do
    block
    |> Map.delete(:details)
    |> Map.delete(:published_media)
  end

  defp execute_one(call, tool_fns, context) do
    {block, _revised} = execute_one_with_revision(call, tool_fns, context)
    block
  end

  defp execute_one_with_revision(%{name: name, input: input, id: id}, tool_fns, context) do
    name = normalize_tool_name(name)
    started_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    t0 = System.monotonic_time(:millisecond)
    Logger.debug("[Executor] start tool=#{name} id=#{id}")

    authorized = name in authorized_tools(context.delegation_config)
    nested_caller? = context[:tool_caller] == :nested

    result =
      case if(authorized, do: fetch_tool(tool_fns, name), else: :error) do
        {:ok, %{nested_only?: true}} when not nested_caller? ->
          unknown_tool(name, id, input)

        {:ok, %{deferred?: true} = entry} when not nested_caller? ->
          if loaded_deferred?(name, context) do
            invoke_tool(entry, name, id, input, context, tool_fns)
          else
            unknown_tool(name, id, input)
          end

        {:ok, entry} ->
          invoke_tool(entry, name, id, input, context, tool_fns)

        :error ->
          unknown_tool(name, id, input)
      end

    {result, revised} = detach_context_edit(result)
    max_chars = get_max_result_chars(tool_fns, name)
    truncated = bound_result(result, max_chars, context)
    duration_ms = System.monotonic_time(:millisecond) - t0
    completed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Logger.debug(
      "[Executor] end tool=#{name} id=#{id} duration_ms=#{duration_ms} " <>
        "is_error=#{truncated.is_error}"
    )

    block =
      truncated
      |> result_to_block(id)
      |> put_execution_timing(started_at, completed_at, duration_ms)

    {block, revised}
  end

  defp put_execution_timing(block, started_at, completed_at, duration_ms) do
    details =
      Map.merge(block[:details] || %{}, %{
        started_at: DateTime.to_iso8601(started_at),
        completed_at: DateTime.to_iso8601(completed_at),
        duration_ms: duration_ms,
        timing_fidelity: "exact"
      })

    Map.put(block, :details, details)
  end

  defp detach_context_edit(%Result{is_error: true} = result), do: {result, nil}

  defp detach_context_edit(%Result{details: details} = result) when is_map(details) do
    revised = SafeMap.get_any(details, :model_context, "model_context")
    details = Map.drop(details, [:model_context, "model_context"])
    details = if details == %{}, do: nil, else: details
    revised = if is_list(revised), do: revised, else: nil
    {%{result | details: details}, revised}
  end

  defp detach_context_edit(result), do: {result, nil}

  defp install_context(%State{} = state, revised) when is_list(revised) do
    state
    |> ModelContext.install(revised)
    |> Map.put(:context_edited, true)
  end

  defp install_context(%State{} = state, _revised), do: state

  # Run a sequential tool inside a supervised Task and enforce timeout so a
  # hung tool (e.g. a bash subprocess that never EOFs on its port) cannot
  # block the whole Turn forever.
  defp execute_one_with_timeout(call, tool_fns, context, timeout_ms) do
    tool_id = (call && SafeMap.get_any(call, [:id, "id"])) || "unknown"

    tool_name = (call && SafeMap.get_any(call, [:name, "name"])) || "unknown"

    start_task = if context.delegation_config.delegated?, do: :async, else: :async_nolink

    task =
      apply(Task.Supervisor, start_task, [
        task_supervisor(context),
        fn ->
          Process.put(:tool_owner, context[:runner_pid])
          execute_one_with_revision(call, tool_fns, context)
        end
      ])

    # Outer guard: tool-specific timeout + small grace period for kill/cleanup.
    guard_ms = timeout_ms + 5_000

    case Task.yield(task, guard_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        Logger.warning(fn ->
          "[Executor] sequential tool exited tool=#{tool_name} id=#{tool_id} " <>
            "reason=#{inspect(reason)}"
        end)

        {result_to_block(
           Result.error(
             failure_content("Tool execution failed: #{inspect(reason)}", tool_fns, tool_name),
             %{code: :tool_task_exit, side_effect: :unknown}
           ),
           tool_id
         ), nil}

      nil ->
        Logger.warning(fn ->
          "[Executor] sequential tool timeout tool=#{tool_name} id=#{tool_id} " <>
            "timeout_ms=#{guard_ms}"
        end)

        {result_to_block(
           Result.error(
             failure_content(
               "Tool execution timed out after #{div(guard_ms, 1000)}s",
               tool_fns,
               tool_name
             ),
             %{code: :tool_timeout, side_effect: :unknown}
           ),
           tool_id
         ), nil}
    end
  end

  defp fetch_tool(_tool_fns, nil), do: :error
  defp fetch_tool(_tool_fns, ""), do: :error
  defp fetch_tool(tool_fns, name), do: Map.fetch(tool_fns, name)

  defp dev_log(message) do
    if dev_env?(), do: Logger.debug(message)
  end

  defp dev_env? do
    function_exported?(Mix, :env, 0) and Mix.env() == :dev
  end

  defp normalize_tool_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_tool_name(name) when is_binary(name), do: String.trim(name)
  defp normalize_tool_name(name), do: name

  defp get_max_result_chars(tool_fns, name) do
    case Map.fetch(tool_fns, name) do
      {:ok, entry} ->
        case entry.max_result_chars do
          :unlimited -> nil
          max when is_integer(max) -> max
          _ -> @default_max_result_chars
        end

      _ ->
        @default_max_result_chars
    end
  end

  @doc """
  Apply truncation to a ToolResult's content using a unified strategy.

  Oversized bodies are spilled to an artifact. Details never retain the
  original text, including when the spill itself fails. Errors are bounded
  the same way as successes.
  """
  def truncate_result(%Result{} = result, max_chars) do
    bound_result(result, max_chars, %{truncate_only?: true})
  end

  defp bound_result(%Result{} = result, max_chars, context) do
    spilled =
      if is_integer(max_chars) and byte_size(to_string(result.content)) > max_chars do
        spill_body(result, max_chars, context[:working_directory])
      else
        result
      end

    if context[:truncate_only?], do: spilled, else: project_result(spilled, context)
  end

  defp spill_body(%Result{content: content} = result, max_chars, working_directory) do
    head = String.slice(content, 0, min(@spill_head_chars, max_chars))

    case spill_path(working_directory, content) do
      {:ok, relative, absolute} ->
        case persist_spill(absolute, content) do
          :ok ->
            preview =
              head <>
                "\n\n[Full result written to #{relative} (#{byte_size(content)} bytes). " <>
                "Read it with the read tool using offset and limit. " <>
                "Do not assume the omitted tail.]\n"

            %{
              result
              | content: preview,
                details: Map.merge(result.details || %{}, %{spill_path: relative})
            }

          {:error, _reason} ->
            spill_unavailable(result, max_chars)
        end

      :error ->
        spill_unavailable(result, max_chars)
    end
  end

  defp spill_unavailable(%Result{content: content} = result, max_chars) do
    trunc_result = Handbean.Utils.Truncate.truncate_head_tail(content, max_bytes: max_chars)

    %{
      result
      | content:
          trunc_result.content <>
            "\n[artifact unavailable; full body was not retained in the result]",
        details: Map.put(result.details || %{}, :artifact_unavailable, true)
    }
  end

  defp spill_path(working_directory, content)
       when is_binary(working_directory) and working_directory != "" and is_binary(content) do
    hash =
      :crypto.hash(:sha256, content)
      |> Base.encode16(case: :lower)

    relative =
      Path.join([
        ".handbean",
        "tool-results",
        "spill-#{hash}.txt"
      ])

    absolute = Path.expand(relative, working_directory)

    with :ok <- File.mkdir_p(Path.dirname(absolute)),
         :ok <-
           Handbean.Security.PathValidator.validate_within_workspace(absolute, working_directory) do
      {:ok, relative, absolute}
    else
      _ -> :error
    end
  end

  defp spill_path(_working_directory, _content), do: :error

  defp persist_spill(absolute, content) do
    case File.read(absolute) do
      {:ok, ^content} ->
        :ok

      {:ok, _other} ->
        {:error, :hash_collision}

      {:error, :enoent} ->
        publish_spill(absolute, content)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish_spill(absolute, content) do
    nonce =
      :crypto.strong_rand_bytes(8)
      |> Base.encode16(case: :lower)

    temporary = absolute <> ".#{nonce}.tmp"

    case File.write(temporary, content, [:exclusive, :sync]) do
      :ok ->
        result = link_spill(temporary, absolute, content)
        _ = File.rm(temporary)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp link_spill(temporary, absolute, content) do
    case :file.make_link(String.to_charlist(temporary), String.to_charlist(absolute)) do
      :ok ->
        :ok

      {:error, :eexist} ->
        verify_spill(absolute, content)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_spill(absolute, content) do
    case File.read(absolute) do
      {:ok, ^content} -> :ok
      {:ok, _other} -> {:error, :hash_collision}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Convert a ToolResult to a provider-facing tool_result_block map.

  The `"details"` key carries UI metadata (exit_code, timed_out, file_path, etc.)
  and is NOT sent to the LLM — providers only look at `"content"` and `"is_error"`.
  """
  def result_to_block(%Result{} = result, tool_use_id) do
    result = project_result(result, %{})
    details = result_details(result)

    Message.tool_result_block(tool_use_id, result.content, result.is_error, details)
    |> Map.put(:images, result.images)
    |> Map.put(:published_media, result.published_media)
  end

  defp normalize_outcome(%Result{} = result, _tool_fns, _name), do: result
  defp normalize_outcome({:ok, text}, _tool_fns, _name) when is_binary(text), do: Result.new(text)

  defp normalize_outcome({:ok, text, data}, _tool_fns, _name)
       when is_binary(text) and is_map(data),
       do: Result.new(text, data) |> with_contract(data)

  defp normalize_outcome({:error, reason, details}, tool_fns, name) when is_map(details),
    do:
      Result.error(failure_content(reason, tool_fns, name), details)
      |> with_contract(details)

  defp normalize_outcome({:error, reason}, tool_fns, name),
    do: Result.error(failure_content(reason, tool_fns, name))

  defp normalize_outcome(other, tool_fns, name),
    do:
      Result.error(
        failure_content(
          "Tool returned an unexpected result: #{inspect(other, limit: 5)}",
          tool_fns,
          name
        ),
        %{code: :tool_protocol_error, side_effect: :unknown}
      )

  defp project_result(%Result{} = result, context) do
    ResultContract.project(result, artifact: context[:artifact])
  end

  defp with_contract(%Result{} = result, details) do
    %{
      result
      | operation_id: detail_value(details, :operation_id, result.operation_id),
        status: detail_value(details, :status, result.status),
        code: detail_value(details, :code, result.code),
        side_effect: detail_value(details, :side_effect, result.side_effect),
        recovery: detail_value(details, :recovery, result.recovery),
        artifacts: detail_value(details, :artifacts, result.artifacts),
        published_media: detail_value(details, :published_media, result.published_media)
    }
  end

  defp detail_value(details, key, default) do
    Map.get(details, key, Map.get(details, Atom.to_string(key), default))
  end

  defp result_details(%Result{} = result) do
    envelope = ResultContract.envelope(result)
    details = Map.merge(result.details || %{}, envelope)
    if details == %{}, do: nil, else: details
  end

  defp advisor_tool_allowed?("advisor", config) do
    Handbean.Agent.Advisor.tool_visible?(config.advisor)
  end

  defp advisor_tool_allowed?(_name, _config), do: true

  defp timeout_for(call, tool_fns, state) do
    name = SafeMap.get_any(call, :name, "name")

    tool_cap =
      case Map.get(tool_fns, name) do
        %{timeout_ms: timeout} when is_integer(timeout) and timeout > 0 -> timeout
        _ -> state.config.tool_timeout
      end

    remaining = remaining_run_ms(state)

    if is_integer(remaining), do: min(tool_cap, remaining), else: tool_cap
  end

  defp context_run_deadline(%{context: %{run_deadline: deadline}}), do: deadline
  defp context_run_deadline(_config), do: nil

  defp remaining_run_ms(%{config: %{context: %{run_deadline: deadline}}})
       when is_integer(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp remaining_run_ms(_state), do: nil

  defp failure_content(reason, tool_fns, name) do
    error = error_text(reason)

    case tool_hint(tool_fns, name) do
      nil -> error
      hint -> error <> "\n\nTool hint: " <> hint
    end
  end

  defp error_text(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> "Tool execution failed"
      text -> text
    end
  end

  defp error_text(reason) when is_atom(reason) and not is_nil(reason) do
    reason |> Atom.to_string() |> error_text()
  end

  defp error_text(reason), do: inspect(reason)

  defp tool_hint(tool_fns, name) do
    case Map.get(tool_fns, name) do
      %{hint: hint} when is_binary(hint) and hint != "" -> hint
      _ -> nil
    end
  end

  defp partition_by_concurrency(tool_calls, tool_fns) do
    Enum.split_with(tool_calls, fn call ->
      name = SafeMap.get_any(call, :name, "name")

      case Map.fetch(tool_fns, name) do
        {:ok, entry} -> entry.concurrent? == false
        :error -> false
      end
    end)
  end

  defp reassemble_ordered(tool_calls, seq_calls, seq_results, par_calls, par_results) do
    seq_map = Map.new(Enum.zip(seq_calls, seq_results))
    par_map = Map.new(Enum.zip(par_calls, par_results))
    Enum.map(tool_calls, fn call -> Map.get(seq_map, call) || Map.get(par_map, call) end)
  end

  @doc "The run's authorization ceiling, intersected with the live session policy."
  def authorized_tools(config) do
    context = config.context || %{}
    registered = Map.keys(Handbean.Tool.Registry.tool_fns())
    session_id = context[:conversation_id] || context[:session_id]
    active = if session_id, do: Handbean.Tool.Registry.active_for_session(session_id)
    parent = context[:delegation_parent]
    read_only? = Handbean.Threads.Collaboration.read_only?(context)

    parent_active =
      if parent, do: Handbean.Tool.Registry.active_for_session(parent.conversation_id)

    registered
    |> Enum.filter(
      &((is_nil(config.allowed_tools) or &1 in config.allowed_tools) and
          builtin_memory_tool_allowed?(&1, config) and
          advisor_tool_allowed?(&1, config) and
          (is_nil(active) or &1 in active) and
          (is_nil(parent_active) or &1 in parent_active) and
          (is_nil(parent) or
             Handbean.Agent.Delegation.Policy.authorized_child?(parent, config.run_id)) and
          (not read_only? or &1 in Handbean.Threads.Collaboration.read_tools()))
    )
  end

  defp builtin_memory_tool_allowed?(name, %{builtin_memory_enabled: false}),
    do: name not in @builtin_memory_tools

  defp builtin_memory_tool_allowed?(_name, _config), do: true

  defp loaded_deferred?(name, context) do
    Handbean.Tool.Deferred.loaded?(name, context[:conversation_id])
  end

  defp invoke_tool(entry, name, id, input, context, tool_fns) do
    try do
      outcome =
        if Handbean.Threads.Collaboration.tool_allowed?(name, context) do
          entry.executor.(input || %{}, Map.put(context, :tool_call_id, id))
        else
          {:error, "Delegated thread is read-only; tool execution denied",
           %{code: :permission_denied, permission: :denied, side_effect: :not_started}}
        end

      outcome
      |> normalize_outcome(tool_fns, name)
      |> Handbean.Tool.Images.import_result(context)
    rescue
      exception ->
        msg = "Tool #{name} crashed: #{Exception.message(exception)}"

        Logger.warning(fn ->
          msg <> "\n" <> Exception.format(:error, exception, __STACKTRACE__)
        end)

        Result.error(failure_content(msg, tool_fns, name), %{
          code: :tool_exception,
          side_effect: :unknown
        })
    end
  end

  defp unknown_tool(name, id, input) do
    msg = "Unknown tool: #{name}"
    Logger.warning(fn -> msg end)

    dev_log("[Executor] unknown tool call raw=#{inspect(%{id: id, name: name, input: input})}")

    Result.error(msg, %{code: :unknown_tool, side_effect: :not_started})
  end

  defp authorize_nested(name, tool_fns, context, state) do
    cond do
      name not in authorized_tools(context.delegation_config) ->
        {:error, "Unknown tool: #{name}"}

      match?(:error, fetch_tool(tool_fns, name)) ->
        {:error, "Unknown tool: #{name}"}

      not Handbean.Threads.Collaboration.tool_allowed?(name, context) ->
        {:error, "Delegated thread is read-only; tool execution denied"}

      active_set_blocks?(name, state) ->
        {:error, "Unknown tool: #{name}"}

      true ->
        :ok
    end
  end

  defp active_set_blocks?(name, %State{config: config}) do
    session_id = config.context[:conversation_id] || config.context[:session_id]
    active = if session_id, do: Handbean.Tool.Registry.active_for_session(session_id)
    is_list(active) and name not in active
  end

  defp nested_call_id(parent) when is_binary(parent) and parent != "" do
    "nested-" <> parent <> "-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp nested_call_id(_parent) do
    "nested-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp public_tool_input("publish_media", input) when is_map(input),
    do: Handbean.Tool.Builtin.PublishMedia.public_input(input)

  defp public_tool_input(_name, input), do: Handbean.Log.Redactor.redact(input)

  defp tool_hook_payload(call, session_id, parent_tool_call_id) do
    %{
      tool_use_id: call.id,
      tool_name: call.name,
      args: call.input || %{},
      session_id: session_id,
      parent_tool_call_id: parent_tool_call_id
    }
  end

  defp apply_hook_args(call, {:transform, %{args: args}}) when is_map(args) do
    %{call | input: Map.merge(call.input || %{}, args)}
  end

  defp apply_hook_args(call, _hook_result), do: call

  defp run_tool_hook(%State{config: %{delegated?: true}}, _session_id, _event), do: :ok
  defp run_tool_hook(_state, session_id, event), do: HookPipeline.run(session_id, event)

  defp emit_nested(opts, kind, payload) do
    case Keyword.get(opts, :on_event) do
      fun when is_function(fun, 1) -> fun.({kind, payload})
      _ -> :ok
    end
  end

  defp nested_end_payload(call, block, parent_tool_call_id, turn_number) do
    details = block[:details] || %{}

    payload = %{
      tool_use_id: call.id,
      tool: call.name,
      parent_tool_call_id: parent_tool_call_id,
      turn_number: turn_number,
      duration_ms: detail_value(details, :duration_ms, nil),
      started_at: detail_value(details, :started_at, nil),
      completed_at: detail_value(details, :completed_at, nil),
      timing_fidelity: detail_value(details, :timing_fidelity, nil),
      details: Handbean.Agent.Tool.ResultContract.project_details(details) || %{},
      published_media: Handbean.Media.project(block[:published_media]),
      output: String.slice(to_string(block[:content] || ""), 0, 16_000)
    }

    if block[:is_error], do: Map.put(payload, :error, block[:content]), else: payload
  end

  defp nested_outcome(block) do
    details = block[:details] || %{}

    if block[:is_error] do
      {:error, block[:content], details}
    else
      {:ok, block[:content], details}
    end
  end

  defp report_tool_error(call, %{is_error: true, content: reason} = block, context) do
    details = block[:details] || %{}
    run_opts = context[:thread_run_opts] || []
    provider_config = run_opts[:provider_config] || %{}

    case ErrorReporter.tool_failure_disposition(reason, details, provider_config) do
      {:expected, _reason_category} ->
        :ok

      {:report, reason_category} ->
        report_tool_failure(call, reason, reason_category, details, context, run_opts)
    end
  end

  defp report_tool_error(_call, _block, _context), do: :ok

  defp report_tool_failure(call, reason, reason_category, details, context, run_opts) do
    ErrorReporter.report(
      reason,
      %{
        "source" => "agent_tool",
        "conversation_id" => context[:conversation_id],
        "parent_conversation_id" => get_in(context, [:delegation_parent, :conversation_id]),
        "run_id" => context[:run_id],
        "workspace_id" => context[:workspace_id],
        "model" => run_opts[:model],
        "tool" => SafeMap.get_any(call, :name, "name"),
        "tool_call_id" => SafeMap.get_any(call, :id, "id"),
        "parent_tool_call_id" => context[:parent_tool_call_id],
        "tool_error_code" => detail_value(details, :code, nil)
      },
      failure_class: :tool_error,
      reason_category: reason_category,
      provider: run_opts[:provider],
      provider_config: run_opts[:provider_config]
    )
  end

  defp build_context(%State{} = state, opts) do
    state
    |> build_context()
    |> Map.put(:tool_caller, Keyword.get(opts, :caller, :model))
    |> Map.put(:parent_tool_call_id, Keyword.get(opts, :parent_tool_call_id))
  end

  defp build_context(%State{} = state) do
    %State{
      config: config,
      run_metadata: run_metadata,
      usage: usage,
      tool_guard_overrides: overrides,
      tool_guard_session_allow: session_allow
    } = state

    context = config.context || %{}
    metadata = run_metadata || %{}

    context
    |> Map.merge(%{
      working_directory: config.working_directory,
      checkout_path: config.working_directory,
      workspace_path: config.workspace_path,
      approval_mode: effective_approval_mode(config, overrides, session_allow),
      skill_paths: config.skill_paths,
      tool_timeout: config.tool_timeout,
      run_deadline: context_run_deadline(config),
      run_id: config.run_id,
      runner_pid: config.runner_pid,
      run_task_supervisor: config.run_task_supervisor,
      delegation_config: config,
      parent_usage: usage,
      authorized_tools:
        Enum.reject(authorized_tools(config), fn name ->
          mode = Map.get(overrides || %{}, name, :auto)
          mode not in [:auto, "auto"]
        end),
      conversation_id:
        Map.get(context, :conversation_id) || Map.get(metadata, :conversation_id) ||
          Map.get(metadata, :session_id),
      session_id: Map.get(metadata, :session_id) || Map.get(context, :session_id),
      workspace_id: Map.get(context, :workspace_id),
      thread_run_opts: [
        workspace_path: config.workspace_path || config.working_directory,
        working_directory: config.working_directory,
        model: config.model,
        provider: config.provider,
        provider_config: config.provider_config
      ]
    })
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Map.put(:model_messages, ModelContext.visible(state))
  end

  defp task_supervisor(context),
    do: context[:run_task_supervisor] || Handbean.AgentRunTaskSupervisor

  defp effective_approval_mode(config, overrides, session_allow) do
    delegated =
      SafeMap.get_any(config.context || %{}, :delegated_approval, "delegated_approval")

    if delegated in [:yolo, "yolo"] do
      :yolo
    else
      ToolPolicy.from_workspace(
        config.workspace_path || config.working_directory,
        config.working_directory,
        overrides || %{},
        session_allow || []
      )
      |> Map.fetch!(:default_mode)
    end
  end
end
