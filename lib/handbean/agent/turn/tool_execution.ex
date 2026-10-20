defmodule Handbean.Agent.Turn.ToolExecution do
  @moduledoc false

  alias Handbean.Agent.{Compactor, Message, ModelContext, State}
  alias Handbean.Agent.Tool.Executor
  alias Handbean.Agent.Turn.Events
  alias Handbean.Extension.HookPipeline
  alias Handbean.Utils.SafeMap

  def append_results(%State{} = state, messages) when is_list(messages) do
    if Handbean.Agent.Provider.context_editing?(state.config.provider) do
      State.append_messages(state, Enum.map(messages, &annotate_context_budget(&1, state)))
    else
      State.append_messages(state, messages)
    end
  end

  def blocked_result_block(call, block_source) do
    call_id = SafeMap.get_any(call, [:id, "id"])
    name = SafeMap.get_any(call, :name, "name")

    {content, blocked_by} =
      case block_source do
        {:extension, reason} -> {extension_block_content(name, reason), :extension}
        :active_set -> {"Tool call blocked: #{name} is not available at this stage", :active_set}
      end

    Message.tool_result_block(
      call_id,
      content,
      true,
      %{permission: :denied, blocked_by: blocked_by, tool: name}
    )
  end

  def finish_halted_review(%State{} = state, new_msgs, opts) do
    tool_calls = extract_tool_calls(new_msgs)

    denied_by_id =
      Map.new(state.tool_guard_result_blocks || [], fn block ->
        {SafeMap.get_any(block, [:tool_use_id, "tool_use_id"]), block}
      end)

    blocks =
      Enum.map(tool_calls, fn call ->
        id = SafeMap.get_any(call, [:id, "id"])

        Map.get(denied_by_id, id) ||
          Message.tool_result_block(
            id,
            state.error || Handbean.Permissions.AutoReview.halt_error(),
            true,
            %{
              permission: :denied,
              tool: SafeMap.get_any(call, [:name, "name"]),
              reviewer: :auto_review
            }
          )
      end)

    Events.emit_denied_tool_ends(blocks, opts, state.turn)

    state
    |> State.append_messages([Message.tool_results(blocks)])
    |> Map.put(:status, :halted)
  end

  def gate_tool_calls(_state, tool_calls, nil, _active_set) do
    {[], Enum.map(tool_calls, &{&1, %{}})}
  end

  def gate_tool_calls(state, tool_calls, session_id, active_set) do
    {blocked, allowed} =
      Enum.reduce(tool_calls, {[], []}, fn call, acc ->
        fold_tool_call_gate(state, session_id, active_set, call, acc)
      end)

    {Enum.reverse(blocked), Enum.reverse(allowed)}
  end

  def reject_unauthorized_rewrites(state, blocked_calls, allowed_calls_w_ctx, active_set) do
    {unauthorized, allowed_calls_w_ctx} =
      Enum.split_with(allowed_calls_w_ctx, fn {call, ctx} ->
        unauthorized_rewrite?(state, call, ctx, active_set)
      end)

    {blocked_calls ++ unauthorized_extension_blocks(unauthorized), allowed_calls_w_ctx}
  end

  def emit_allowed_tool_starts(allowed_calls_w_ctx, opts, state) do
    denied_ids =
      state.tool_guard_result_blocks
      |> List.wrap()
      |> Enum.map(&SafeMap.get_any(&1, [:tool_use_id, "tool_use_id"]))
      |> MapSet.new()

    calls =
      allowed_calls_w_ctx
      |> Enum.map(fn {call, _ctx} -> call end)
      |> Enum.reject(&MapSet.member?(denied_ids, SafeMap.get_any(&1, [:id, "id"])))

    Events.emit_tool_starts(calls, opts, state.turn)
  end

  def execute_with_guard_results(tool_calls, %State{tool_guard_result_blocks: []} = state) do
    Executor.execute_all_with_context(tool_calls, state)
  end

  def execute_with_guard_results(
        tool_calls,
        %State{tool_guard_result_blocks: denied_blocks} = state
      )
      when is_list(denied_blocks) do
    denied_ids =
      MapSet.new(Enum.map(denied_blocks, &SafeMap.get_any(&1, [:tool_use_id, "tool_use_id"])))

    executable_calls =
      Enum.reject(tool_calls, &MapSet.member?(denied_ids, SafeMap.get_any(&1, [:id, "id"])))

    with {:ok, result_msg, ui_blocks, state} <-
           Executor.execute_all_with_context(executable_calls, state) do
      all_ui_blocks = order_guarded_blocks(tool_calls, ui_blocks ++ denied_blocks)

      {:ok, %{result_msg | content: Enum.map(all_ui_blocks, &Executor.strip_details/1)},
       all_ui_blocks, state}
    end
  end

  def order_guarded_blocks(tool_calls, blocks) do
    by_id =
      Map.new(blocks, fn block ->
        {SafeMap.get_any(block, [:tool_use_id, "tool_use_id"]), block}
      end)

    Enum.map(tool_calls, &Map.fetch!(by_id, SafeMap.get_any(&1, [:id, "id"])))
  end

  def extract_tool_calls(messages), do: Enum.flat_map(messages, &Message.tool_calls/1)

  defp annotate_context_budget(%Message{} = message, %State{} = state) do
    used =
      Compactor.request_tokens(
        ModelContext.visible(state) ++ [message],
        state.usage_anchor
      )

    annotate_context_blocks(message, "\n[context: ~#{used} of #{state.config.max_tokens} tokens]")
  end

  defp annotate_context_blocks(%Message{content: blocks} = message, trailer)
       when is_list(blocks) do
    %{message | content: Enum.map(blocks, &append_block_budget(&1, trailer))}
  end

  defp annotate_context_blocks(message, _trailer), do: message

  defp append_block_budget(block, trailer) when is_map(block) do
    content = SafeMap.get_any(block, :content, "content")

    cond do
      not is_binary(content) -> block
      String.ends_with?(content, trailer) -> block
      Map.has_key?(block, :content) -> %{block | content: content <> trailer}
      true -> Map.put(block, "content", content <> trailer)
    end
  end

  defp append_block_budget(block, _trailer), do: block

  defp extension_block_content(name, reason) do
    reason = to_string(reason)

    if String.trim(reason) == "",
      do: "Tool call blocked: #{name} is not available at this stage",
      else: "Tool call blocked: #{reason}"
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

  defp run_extension_hook(%State{config: %{delegated?: true}}, _session_id, _event), do: :ok
  defp run_extension_hook(_state, session_id, event), do: HookPipeline.run(session_id, event)

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

    boundary_context =
      (state.config.context || %{})
      |> Map.put(:working_directory, state.config.working_directory)
      |> Map.put(:checkout_path, state.config.working_directory)
      |> Map.put(:workspace_path, state.config.workspace_path)
      |> Map.put(:run_id, state.config.run_id)

    inactive? or
      (rewritten? and
         Handbean.Permissions.ToolPolicy.assess(policy, call, boundary_context).decision != :auto)
  end

  defp unauthorized_extension_blocks(unauthorized) do
    Enum.map(unauthorized, fn {call, _} ->
      {call,
       {:extension, "Transformed call is not authorized by workspace permissions or active tools"}}
    end)
  end
end
