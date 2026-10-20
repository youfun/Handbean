defmodule Handbean.Agent.Middleware.ToolGuard do
  @moduledoc """
  Workspace permission guard for tool requests.
  """

  @behaviour Handbean.Agent.Middleware

  alias Handbean.Agent.{Message, State}
  alias Handbean.Permissions.{AutoReview, InterruptData, ToolPolicy}
  alias Handbean.Utils.SafeMap

  @impl true
  def call(:after_tool_request, %State{} = state) do
    state = %{
      state
      | tool_guard_denied_calls: [],
        tool_guard_result_blocks: [],
        messages:
          Handbean.Tool.Builtin.Schedule.freeze_messages(
            state.messages,
            config_context(state)
          )
    }

    tool_calls = last_tool_calls(state)

    policy = policy(state)

    {denied, rest} = Enum.split_with(tool_calls, &(ToolPolicy.decision(policy, &1) == :deny))

    {pending, auto_approved} =
      Enum.split_with(rest, &(ToolPolicy.decision(policy, &1) == :prompt))

    state = put_denied(state, denied, policy)

    cond do
      pending != [] ->
        review_or_interrupt(state, pending, auto_approved)

      denied != [] ->
        {:tool_guard_denied, state}

      true ->
        state
    end
  end

  def call(_hook, %State{} = state), do: state

  @doc false
  @spec auto_resume_decisions(State.t()) :: {:ok, [map()]} | :pending
  def auto_resume_decisions(%State{status: :interrupted} = state) do
    interrupt_data = state.interrupt_data || %{}
    type = SafeMap.get_any(interrupt_data, :type, "type")
    hitl_ids = SafeMap.get_any(interrupt_data, :hitl_tool_call_ids, "hitl_tool_call_ids") || []

    auto_ids =
      SafeMap.get_any(
        interrupt_data,
        :auto_approved_tool_call_ids,
        "auto_approved_tool_call_ids"
      ) || []

    calls_by_id = Map.new(last_tool_calls(state), &{&1.id, &1})
    executable_ids = Enum.uniq(hitl_ids ++ auto_ids)
    executable_calls = Enum.map(executable_ids, &Map.get(calls_by_id, &1))
    policy = policy(state)

    cond do
      type not in [:tool_approval, "tool_approval"] ->
        :pending

      executable_ids == [] or Enum.any?(executable_calls, &is_nil/1) ->
        :pending

      Enum.all?(executable_calls, &(ToolPolicy.decision(policy, &1) == :auto)) ->
        {:ok,
         Enum.map(hitl_ids, fn id ->
           call = Map.fetch!(calls_by_id, id)

           %{
             "tool_call_id" => call.id,
             "tool_name" => call.name,
             "action" => "approve",
             "remember" => false
           }
         end)}

      true ->
        :pending
    end
  end

  def auto_resume_decisions(%State{}), do: :pending

  defp policy(%State{} = state) do
    ToolPolicy.from_workspace(
      policy_workspace(state),
      state.config.working_directory,
      state.tool_guard_overrides || %{},
      state.tool_guard_session_allow || []
    )
    |> delegated_policy(state)
  end

  @doc false
  @spec resolve_approval(State.t(), [map()]) :: %{
          state: State.t(),
          tool_calls: [map()],
          executable_calls: [map()],
          denied_blocks: [map()]
        }
  def resolve_approval(%State{status: :interrupted} = state, decisions) when is_list(decisions) do
    interrupt_data = state.interrupt_data || %{}
    hitl_ids = Map.get(interrupt_data, :hitl_tool_call_ids, [])

    auto_ids =
      interrupt_data
      |> Map.get(:auto_approved_tool_call_ids, [])
      |> MapSet.new()

    tool_calls = last_tool_calls(state)
    decision_by_id = decisions |> Enum.map(&normalize_decision/1) |> decision_lookup()

    {decision_blocks, remembered_overrides, approved_hitl_ids} =
      partition_hitl_decisions(hitl_ids, tool_calls, decision_by_id)

    classified_denied_blocks = (state.tool_guard_result_blocks || []) ++ decision_blocks

    denied_ids = MapSet.new(classified_denied_blocks, & &1.tool_use_id)

    permitted_ids =
      auto_ids
      |> MapSet.union(approved_hitl_ids)
      |> MapSet.difference(denied_ids)

    denied_blocks = total_denied_blocks(tool_calls, permitted_ids, classified_denied_blocks)

    executable_calls =
      Enum.filter(tool_calls, &MapSet.member?(permitted_ids, &1.id))

    %{
      state: apply_approval_resume_state(state, denied_blocks, remembered_overrides),
      tool_calls: tool_calls,
      executable_calls: executable_calls,
      denied_blocks: denied_blocks
    }
  end

  defp normalize_decision(decision) do
    %{
      tool_call_id: SafeMap.get(decision, "tool_call_id"),
      tool_name: SafeMap.get(decision, "tool_name"),
      action: SafeMap.get(decision, "action") || "deny",
      remember: SafeMap.get(decision, "remember", false) == true,
      suggested_pattern: SafeMap.get(decision, "suggested_pattern")
    }
  end

  defp decision_lookup(decisions) do
    Map.new(decisions, &{&1.tool_call_id, &1})
  end

  defp partition_hitl_decisions(hitl_ids, tool_calls, decision_by_id) do
    Enum.reduce(hitl_ids, {[], %{}, MapSet.new()}, fn call_id, {blocks, overrides, approved} ->
      call = Enum.find(tool_calls, &(&1.id == call_id))
      decision = Map.get(decision_by_id, call_id, normalize_decision(%{}))
      action = decision.action

      if to_string(action) == "approve" do
        {blocks, remember_session_grant(overrides, decision, call), MapSet.put(approved, call_id)}
      else
        tool_name = (call && call.name) || decision.tool_name || "unknown"

        block = approval_result_block(call_id, tool_name, action)
        overrides = remember_deny_override(overrides, decision, tool_name)
        {[block | blocks], overrides, approved}
      end
    end)
  end

  defp remember_deny_override(overrides, decision, tool_name) do
    if decision.remember do
      Map.put(overrides, tool_name, :deny)
    else
      overrides
    end
  end

  defp total_denied_blocks(tool_calls, permitted_ids, blocks) do
    by_id = Map.new(blocks, &{&1.tool_use_id, &1})

    tool_calls
    |> Enum.reject(&MapSet.member?(permitted_ids, &1.id))
    |> Enum.map(fn call ->
      Map.get(by_id, call.id) || approval_result_block(call.id, call.name || "unknown", "deny")
    end)
  end

  defp apply_approval_resume_state(state, denied_blocks, remembered_overrides) do
    {remembered_overrides, session_allow} = split_session_grants(remembered_overrides)
    merged_overrides = Map.merge(state.tool_guard_overrides || %{}, remembered_overrides)
    session_allow = Enum.uniq((state.tool_guard_session_allow || []) ++ session_allow)

    state
    |> Map.put(:status, :running)
    |> Map.put(:interrupt_data, nil)
    |> Map.put(:tool_guard_result_blocks, denied_blocks)
    |> Map.put(:tool_guard_overrides, merged_overrides)
    |> Map.put(:tool_guard_session_allow, session_allow)
  end

  # "This session" remembers the suggested pattern rather than granting every
  # future call with the same tool name.
  defp remember_session_grant(overrides, decision, call) do
    if decision.remember do
      pattern =
        (call && Handbean.Permissions.Remember.pattern(call)) || decision.suggested_pattern

      if is_binary(pattern) and String.trim(pattern) != "" do
        Map.put(overrides, {:session_allow, pattern}, :auto)
      else
        overrides
      end
    else
      overrides
    end
  end

  defp split_session_grants(overrides) do
    {grants, rest} =
      Enum.split_with(overrides, fn
        {{:session_allow, _pattern}, :auto} -> true
        _other -> false
      end)

    patterns = Enum.map(grants, fn {{:session_allow, pattern}, :auto} -> pattern end)
    {Map.new(rest), patterns}
  end

  defp approval_result_block(tool_call_id, tool_name, action) do
    {content, permission} =
      case to_string(action) do
        "skip" -> {"Not selected this round. Request this action again.", :skipped}
        _ -> {"Tool call denied by user", :denied}
      end

    Message.tool_result_block(
      tool_call_id,
      content,
      true,
      %{permission: permission, tool: tool_name}
    )
  end

  defp put_denied(state, [], _policy), do: state

  defp put_denied(state, denied, policy) do
    %{
      state
      | tool_guard_denied_calls: denied,
        tool_guard_result_blocks: Enum.map(denied, &denied_result_block(&1, policy))
    }
  end

  # Review runs only after ToolPolicy has already returned :prompt. It never
  # rewrites allow rules or session overrides, and a failed review is the
  # existing human interrupt — not a deny.
  defp review_or_interrupt(state, pending, auto_approved) do
    if auto_review?(state) and not Enum.any?(pending, &(&1.name == "computer")) do
      case AutoReview.review(state, pending) do
        {:ok, %State{status: :halted} = reviewed} ->
          {:tool_guard_denied, merge_prior_denials(reviewed, state)}

        {:ok, %State{tool_guard_result_blocks: []} = reviewed} ->
          merge_prior_denials(reviewed, state)

        {:ok, %State{} = reviewed} ->
          {:tool_guard_denied, merge_prior_denials(reviewed, state)}

        {:fallback, %State{} = reviewed, _reason} ->
          interrupt(reviewed, pending, auto_approved)
      end
    else
      interrupt(state, pending, auto_approved)
    end
  end

  defp merge_prior_denials(reviewed, prior) do
    %{
      reviewed
      | tool_guard_denied_calls:
          Enum.uniq_by(
            (prior.tool_guard_denied_calls || []) ++ (reviewed.tool_guard_denied_calls || []),
            & &1.id
          ),
        tool_guard_result_blocks:
          Enum.uniq_by(
            (prior.tool_guard_result_blocks || []) ++ (reviewed.tool_guard_result_blocks || []),
            & &1.tool_use_id
          )
    }
  end

  defp delegated_policy(policy, %State{} = state) do
    if state.config.context[:delegated_approval] == :yolo,
      do: %{policy | default_mode: :yolo},
      else: policy
  end

  defp auto_review?(%State{} = state) do
    AutoReview.enabled?(policy_workspace(state)) or
      state.config.context[:delegated_approval] == :auto_review
  end

  defp policy_workspace(%State{config: config}) do
    config.workspace_path || config.working_directory
  end

  defp interrupt(%{config: %{source: :schedule}} = state, pending, _auto_approved) do
    tool =
      pending
      |> List.first()
      |> then(&(&1 || %{})[:name])
      |> case do
        name when is_binary(name) and name != "" -> name
        _ -> "tool"
      end

    halted = %{state | status: :halted, error: "定时运行不能等待人工批准：#{tool}"}
    {:tool_guard_denied, halted}
  end

  defp interrupt(state, pending, auto_approved) do
    data = InterruptData.build(pending, auto_approved, state.config.working_directory)
    interrupted = %{state | status: :interrupted, interrupt_data: data}
    {:interrupt, interrupted, data}
  end

  defp config_context(%State{config: %{context: context}}) when is_map(context), do: context
  defp config_context(_state), do: %{}

  defp last_tool_calls(%State{messages: messages}) do
    messages
    |> Enum.reverse()
    |> Enum.find_value([], fn
      %Message{role: :assistant} = message ->
        case Message.tool_calls(message) do
          [] -> nil
          calls -> calls
        end

      _ ->
        nil
    end)
  end

  defp denied_result_block(call, policy) do
    reason =
      if ToolPolicy.sensitive_call?(policy, call) do
        Handbean.Security.PathValidator.sensitive_reason()
      else
        "Tool call denied by workspace permissions"
      end

    Message.tool_result_block(
      call.id,
      reason,
      true,
      %{permission: :denied, tool: call.name}
    )
  end
end
