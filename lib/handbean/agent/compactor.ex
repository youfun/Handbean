defmodule Handbean.Agent.Compactor do
  @moduledoc """
  Context compaction — summarizes older conversation history when approaching
  token limits, with fallback truncation.
  """

  alias Handbean.Agent.{Message, State}

  require Logger

  @default_keep_recent 10
  @truncate_length 200
  @summary_tool_result_length 2_000
  @summary_prefix "Previous analysis summary (from earlier in this session):"

  @summary_system_prompt """
  You are performing CONTEXT CHECKPOINT COMPACTION. Create a handoff summary for another LLM that will resume the task.

  Include:
  - Current progress and key decisions made
  - Important context, constraints, or user preferences
  - What remains to be done (clear next steps)
  - Any critical data, examples, or references needed to continue

  Be concise, structured, and focused on helping the next LLM seamlessly continue the work.
  """

  @summary_prompt """
  Create a structured handoff summary for another language model that will resume this task.

  Use this EXACT structure:

  ## Goal
  [What the user is trying to accomplish]

  ## Constraints & Preferences
  - [Important constraints, preferences, or requirements]

  ## Progress
  ### Done
  - [Completed tasks, findings, or verified facts]

  ### In Progress
  - [Current work that is not finished yet]

  ### Blocked
  - [Active blockers or "(none)"]

  ## Key Decisions
  - **[Decision]**: [Brief rationale]

  ## Evidence & References
  - [Evidence chains, exact file paths, tool names, function names, or error messages]

  ## Next Steps
  1. [Ordered next action]

  ## Critical Context
  - [Anything the next model must preserve exactly]
  """

  @spec summary_prefix() :: String.t()
  def summary_prefix, do: @summary_prefix

  @doc """
  Compact context if message tokens exceed threshold.
  Returns `{:compacted, state}` or `{:unchanged, state}`.
  """
  @spec force_compact(State.t()) :: State.t()
  def force_compact(%State{} = state, opts \\ []) do
    compact_messages_in_state(state, state.messages, opts)
  end

  @spec maybe_compact(State.t(), keyword()) :: {:compacted | :unchanged, State.t()}
  def maybe_compact(%State{config: config, messages: messages} = state, opts \\ []) do
    reserve_tokens = compaction_limit(:reserve_tokens, config, 16_384)
    max_tokens = compaction_limit(:max_tokens, config, 200_000)

    if request_tokens(messages, Keyword.get(opts, :usage_anchor)) <= max_tokens - reserve_tokens do
      {:unchanged, state}
    else
      {:compacted, compact_messages_in_state(state, messages, opts)}
    end
  end

  @doc """
  Tokens the next provider request will carry.

  The anchor's `input_tokens` is the full provider input, including cache
  reads and writes, plus the system prompt and tool schemas. Messages added
  after that call are estimated from their text. Without a measurement yet,
  the message-text estimate is the whole request.
  """
  @spec request_tokens([Message.t()], map() | nil) :: non_neg_integer()
  def request_tokens(messages, %{input_tokens: input, sent_count: sent})
      when is_integer(input) and input > 0 and is_integer(sent) and sent >= 0 do
    input + estimate_messages_tokens(Enum.drop(messages, sent))
  end

  def request_tokens(messages, _anchor), do: estimate_messages_tokens(messages)

  @doc "Estimate a complete provider request, including uncached system and tool payloads."
  @spec request_tokens([Message.t()], map() | nil, keyword()) :: non_neg_integer()
  def request_tokens(messages, anchor, opts) when is_list(opts) do
    message_tokens = request_tokens(messages, anchor)

    if is_map(anchor) do
      message_tokens
    else
      message_tokens +
        estimate_payload_tokens(Keyword.get(opts, :system_prompt)) +
        estimate_payload_tokens(Keyword.get(opts, :tool_defs, []))
    end
  end

  defp compact_messages_in_state(%State{} = state, messages, opts) do
    keep_recent_tokens = compaction_limit(:keep_recent_tokens, state.config, 20_000)

    case prepare_summary_compaction(messages, keep_recent_tokens) do
      {:ok, prepared} ->
        fire_on_compaction(prepared.messages_to_summarize, state)

        case summarize_compaction(prepared, state, messages, opts) do
          {:ok, summary_text} ->
            checkpoint_id =
              fire_on_compaction_complete(
                %{
                  first: prepared.first,
                  previous_summary: prepared.previous_summary,
                  messages_to_summarize: prepared.messages_to_summarize,
                  summary: summary_text
                },
                state
              )

            compacted =
              [
                prepared.first,
                build_summary_message(summary_text, checkpoint_id) | prepared.recent
              ]

            %{state | messages: compacted}

          {:error, reason} ->
            Logger.warning(fn ->
              "summary compaction failed, falling back to truncation: #{inspect(reason)}"
            end)

            fallback_compact_state(state, messages)
        end

      :noop ->
        fallback_compact_state(state, messages)
    end
  end

  defp fallback_compact_state(%State{} = state, messages) do
    keep_recent = min(@default_keep_recent, max(1, length(messages) - 2))
    %{state | messages: compact_messages(messages, keep_recent: keep_recent)}
  end

  defp prepare_summary_compaction([first | rest], keep_recent_tokens) do
    {previous_summary, tail} = pop_existing_summary(rest)

    if tail == [] do
      :noop
    else
      cut_index = find_cut_point(tail, keep_recent_tokens)
      messages_to_summarize = Enum.take(tail, cut_index)
      recent = Enum.drop(tail, cut_index)
      {messages_to_summarize, recent} = align_entry_boundary(messages_to_summarize, recent)

      if messages_to_summarize == [] do
        :noop
      else
        {:ok,
         %{
           first: first,
           previous_summary: previous_summary,
           messages_to_summarize: messages_to_summarize,
           recent: recent
         }}
      end
    end
  end

  defp prepare_summary_compaction(_, _keep_recent_tokens), do: :noop

  defp align_entry_boundary(messages_to_summarize, [%Message{id: id} | _] = recent)
       when is_binary(id) and id != "" do
    case List.last(messages_to_summarize) do
      %Message{id: ^id} ->
        {same_entry, rest} = Enum.split_while(recent, &(&1.id == id))
        {messages_to_summarize ++ same_entry, rest}

      _ ->
        {messages_to_summarize, recent}
    end
  end

  defp align_entry_boundary(messages_to_summarize, recent),
    do: {messages_to_summarize, recent}

  defp summarize_compaction(prepared, %State{} = state, _messages, opts) do
    provider = state.config.provider

    messages_to_summarize =
      prepared.messages_to_summarize
      |> Enum.map(&sanitize_summary_message/1)

    previous_summary =
      if prepared.previous_summary,
        do: sanitize_summary_message(prepared.previous_summary),
        else: nil

    request_messages = [
      Message.user(build_summary_prompt(messages_to_summarize, previous_summary))
    ]

    config =
      opts
      |> Keyword.get(:provider_config, state.config.provider_config)
      |> Map.delete(:provider_state)
      |> Map.delete("provider_state")
      |> Map.delete(:previous_response_id)
      |> Map.delete("previous_response_id")
      |> Map.put(:use_previous_response_id, false)
      |> Map.delete(:cache_fork)
      |> Map.delete(:cache_fork_suffix)
      |> Map.delete("cache_fork")
      |> Map.delete("cache_fork_suffix")
      |> Map.put(:system_prompt, @summary_system_prompt)

    Logger.warning(
      "[Compactor] summary_request system_prompt=isolated tools=0 " <>
        "messages=#{length(request_messages)}"
    )

    with {:ok, response} <- provider.complete(request_messages, [], config),
         :ok <- log_summary_usage(response),
         :ok <- reject_tool_calls(response),
         {:ok, summary_text} <- extract_summary_text(response) do
      {:ok, summary_text}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp build_summary_prompt(messages_to_summarize, previous_summary) do
    previous_summary_section =
      case previous_summary do
        %Message{} = message ->
          "<previous-summary>\n#{summary_body(message)}\n</previous-summary>\n\n"

        nil ->
          ""
      end

    """
    #{previous_summary_section}<conversation>
    #{serialize_messages(messages_to_summarize)}
    </conversation>

    #{@summary_prompt}
    """
  end

  defp summary_body(%Message{content: content}) when is_binary(content) do
    content
    |> String.replace_prefix(@summary_prefix, "")
    |> String.trim()
  end

  defp sanitize_summary_message(%Message{content: blocks} = message) when is_list(blocks) do
    blocks =
      blocks
      |> Enum.reject(&reasoning_or_image_block?/1)
      |> Enum.map(&sanitize_summary_block/1)

    %{message | content: blocks}
  end

  defp sanitize_summary_message(message), do: message

  defp reasoning_or_image_block?(block) when is_map(block) do
    block_type(block) in ["responses_reasoning", "thinking", "image"]
  end

  defp reasoning_or_image_block?(_block), do: false

  defp sanitize_summary_block(block) when is_map(block) do
    block
    |> truncate_tool_result(@summary_tool_result_length)
    |> Map.delete(:images)
    |> Map.delete("images")
  end

  defp sanitize_summary_block(block), do: block

  defp serialize_messages(messages) do
    messages
    |> Enum.map(&serialize_message/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp serialize_message(%Message{role: role, content: content}) when is_binary(content) do
    "[#{role_label(role)}]\n#{content}"
  end

  defp serialize_message(%Message{role: role, content: blocks}) when is_list(blocks) do
    blocks
    |> Enum.map(&serialize_block(role, &1))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp serialize_block(role, block) when is_map(block) do
    type = block_type(block)
    text = Map.get(block, :text) || Map.get(block, "text")
    name = Map.get(block, :name) || Map.get(block, "name")
    input = Map.get(block, :input) || Map.get(block, "input") || %{}
    content = Map.get(block, :content) || Map.get(block, "content")

    cond do
      type == "text" and is_binary(text) ->
        "[#{role_label(role)}]\n#{text}"

      role == :assistant and type in ["tool_use", "server_tool_use"] ->
        "[Assistant tool call] #{name}(#{inspect_summary_term(input)})"

      type in ["tool_result", "server_tool_result"] and is_binary(content) ->
        "[Tool result]\n#{content}"

      true ->
        "[#{role_label(role)} block #{type || "unknown"}]\n#{inspect_summary_term(block)}"
    end
  end

  defp serialize_block(_role, _block), do: ""

  defp inspect_summary_term(term) do
    term
    |> inspect(limit: 50, printable_limit: @summary_tool_result_length)
    |> truncate_summary_text(@summary_tool_result_length)
  end

  defp truncate_summary_text(text, limit) do
    if String.length(text) > limit do
      String.slice(text, 0, limit) <> "\n[truncated for compaction]"
    else
      text
    end
  end

  defp role_label(:user), do: "User"
  defp role_label(:assistant), do: "Assistant"
  defp role_label(other), do: to_string(other)

  defp reject_tool_calls(%{messages: messages}) when is_list(messages) do
    if Enum.any?(messages, &tool_call_message?/1),
      do: {:error, :summary_tool_call},
      else: :ok
  end

  defp reject_tool_calls(_response), do: :ok

  defp tool_call_message?(%Message{content: blocks}) when is_list(blocks) do
    Enum.any?(blocks, fn
      %{type: type} when type in ["tool_use", "server_tool_use"] -> true
      _ -> false
    end)
  end

  defp tool_call_message?(_message), do: false

  defp compaction_limit(:max_tokens, config, default) do
    env_positive("HANDBEAN_COMPACTION_MAX_TOKENS") || config.max_tokens || default
  end

  defp compaction_limit(:reserve_tokens, config, default) do
    env_positive("HANDBEAN_COMPACTION_RESERVE_TOKENS") ||
      (config.compaction && config.compaction.reserve_tokens) || default
  end

  defp compaction_limit(:keep_recent_tokens, config, default) do
    env_positive("HANDBEAN_COMPACTION_KEEP_RECENT_TOKENS") ||
      (config.compaction && config.compaction.keep_recent_tokens) || default
  end

  defp env_positive(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" ->
        case Integer.parse(value) do
          {number, ""} when number > 0 -> number
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp log_summary_usage(%{usage: usage}) when is_map(usage) do
    Logger.warning(
      "[Compactor] summary_usage input=#{usage_num(usage, :input_tokens)} " <>
        "total_input=#{usage_num(usage, :total_input_tokens)} " <>
        "cache_read=#{usage_num(usage, :cache_read_input_tokens)} " <>
        "cache_write=#{usage_num(usage, :cache_creation_input_tokens)} " <>
        "output=#{usage_num(usage, :output_tokens)}"
    )

    :ok
  end

  defp log_summary_usage(_response), do: :ok

  defp usage_num(usage, key) do
    Map.get(usage, key) || Map.get(usage, Atom.to_string(key)) || 0
  end

  defp extract_summary_text(%{messages: messages}) when is_list(messages) do
    summary_text =
      messages
      |> Enum.reverse()
      |> Enum.find_value(fn
        %Message{role: :assistant} = message ->
          case Message.text(message) |> String.trim() do
            "" -> nil
            text -> text
          end

        _ ->
          nil
      end)

    if summary_text, do: {:ok, summary_text}, else: {:error, :empty_summary}
  end

  defp extract_summary_text(_response), do: {:error, :invalid_summary_response}

  defp build_summary_message(summary_text, checkpoint_id) do
    %Message{
      role: :user,
      content: "#{@summary_prefix}\n#{String.trim(summary_text)}",
      id: checkpoint_id
    }
  end

  defp pop_existing_summary([message | rest]) do
    if summary_message?(message), do: {message, rest}, else: {nil, [message | rest]}
  end

  defp pop_existing_summary([]), do: {nil, []}

  defp summary_message?(%Message{role: :user, content: content}) when is_binary(content) do
    String.starts_with?(content, @summary_prefix)
  end

  defp summary_message?(_message), do: false

  @spec compact_messages([Message.t()], keyword()) :: [Message.t()]
  def compact_messages(messages, opts \\ []) do
    keep_recent = Keyword.get(opts, :keep_recent, @default_keep_recent)
    count = length(messages)

    if count <= keep_recent + 1 do
      messages
    else
      [first | rest] = messages
      {middle, recent} = Enum.split(rest, max(length(rest) - keep_recent, 0))
      compacted_middle = Enum.map(middle, &compact_message/1)
      [first | compacted_middle] ++ recent
    end
  end

  defp compact_message(%Message{content: blocks} = msg) when is_list(blocks) do
    compacted_blocks =
      blocks
      |> Enum.reject(&reasoning_or_image_block?/1)
      |> Enum.map(fn
        block when is_map(block) ->
          block
          |> truncate_tool_result(@summary_tool_result_length)
          |> truncate_thinking()
          |> Map.delete(:images)
          |> Map.delete("images")

        block ->
          block
      end)

    %{msg | content: compacted_blocks}
  end

  defp compact_message(%Message{role: :assistant, content: text} = msg) when is_binary(text) do
    if String.length(text) > @truncate_length do
      %{msg | content: String.slice(text, 0, @truncate_length) <> "..."}
    else
      msg
    end
  end

  defp compact_message(msg), do: msg

  defp truncate_tool_result(block, limit) when is_map(block) do
    type = block_type(block)
    content = Map.get(block, :content) || Map.get(block, "content")

    if type in ["tool_result", "server_tool_result"] and is_binary(content) and
         String.length(content) > limit do
      put_block_content(block, String.slice(content, 0, limit) <> "\n[truncated for compaction]")
    else
      block
    end
  end

  defp truncate_thinking(%{type: "thinking", thinking: text} = block)
       when is_binary(text) and byte_size(text) > @truncate_length do
    %{block | thinking: String.slice(text, 0, @truncate_length) <> "..."}
  end

  defp truncate_thinking(%{"type" => "thinking", "thinking" => text} = block)
       when is_binary(text) and byte_size(text) > @truncate_length do
    %{block | "thinking" => String.slice(text, 0, @truncate_length) <> "..."}
  end

  defp truncate_thinking(block), do: block

  defp block_type(block), do: Map.get(block, :type) || Map.get(block, "type")

  defp put_block_content(block, content) do
    if Map.has_key?(block, :content),
      do: Map.put(block, :content, content),
      else: Map.put(block, "content", content)
  end

  defp find_cut_point(messages, keep_recent_tokens) when is_list(messages) and messages != [] do
    threshold_index = find_threshold_index(messages, keep_recent_tokens)

    # Pre-index to avoid O(n) Enum.at/2 calls in find loops
    indexed = Enum.with_index(messages)

    user_cut =
      indexed
      |> Enum.drop(threshold_index)
      |> Enum.find_value(fn {msg, idx} -> real_user_message?(msg) && idx end)

    assistant_cut =
      indexed
      |> Enum.drop(threshold_index)
      |> Enum.find_value(fn {msg, idx} -> assistant_message?(msg) && idx end)

    fallback_cut =
      indexed
      |> Enum.take(threshold_index + 1)
      |> Enum.reverse()
      |> Enum.find_value(fn {msg, idx} -> valid_cut_message?(msg) && idx end)

    # 0 is a real cut. `||` would keep it, then a `> 0` check would treat
    # "boundary is the first tail message" as "no boundary".
    chosen = first_cut([user_cut, assistant_cut, fallback_cut])

    cond do
      is_integer(chosen) and chosen > 0 ->
        chosen

      # The current user message is the tail boundary. Keep it verbatim.
      chosen == 0 and real_user_message?(hd(messages)) ->
        0

      # No protected user boundary. A tail that itself exceeds the recent
      # window — typically one assistant call plus an oversized tool result —
      # is summarized whole. The original task stays outside this tail.
      estimate_messages_tokens(messages) >= keep_recent_tokens ->
        length(messages)

      true ->
        0
    end
  end

  defp find_cut_point(_messages, _keep_recent_tokens), do: 0

  defp first_cut(cuts) do
    Enum.find(cuts, &is_integer/1)
  end

  defp find_threshold_index(messages, keep_recent_tokens) do
    max_index = length(messages) - 1

    messages
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce_while({0, 0}, fn {msg, rev_idx}, {_threshold_index, acc_tokens} ->
      new_acc_tokens = acc_tokens + estimate_message_tokens(msg)
      index = max_index - rev_idx

      if new_acc_tokens >= keep_recent_tokens do
        {:halt, {index, new_acc_tokens}}
      else
        {:cont, {0, new_acc_tokens}}
      end
    end)
    |> elem(0)
  end

  defp real_user_message?(%Message{role: :user} = message) do
    not tool_result_message?(message) and not summary_message?(message)
  end

  defp real_user_message?(_message), do: false

  defp assistant_message?(%Message{role: :assistant}), do: true
  defp assistant_message?(_message), do: false

  defp valid_cut_message?(message), do: real_user_message?(message) or assistant_message?(message)

  defp tool_result_message?(%Message{role: :user, content: blocks}) when is_list(blocks) do
    Enum.any?(blocks, fn
      %{type: type} when type in ["tool_result", "server_tool_result"] -> true
      _ -> false
    end)
  end

  defp tool_result_message?(_message), do: false

  defp estimate_messages_tokens(messages),
    do: Enum.reduce(messages, 0, &(&2 + estimate_message_tokens(&1)))

  defp estimate_message_tokens(%Message{content: content}) when is_binary(content) do
    max(1, div(String.length(content), 4))
  end

  defp estimate_message_tokens(%Message{content: blocks}) when is_list(blocks) do
    text_cost =
      blocks
      |> Handbean.JSON.encode!()
      |> byte_size()
      |> then(&max(1, div(&1, 4)))

    # Two recent images are retained on the wire. Charge their visual cost,
    # not just a few tokens of opaque reference text.
    text_cost +
      Enum.reduce(blocks, 0, fn block, cost ->
        images = Map.get(block, :images) || Map.get(block, "images") || []
        cost + 6_000 * length(images)
      end)
  end

  defp estimate_message_tokens(_), do: 1

  defp estimate_payload_tokens(nil), do: 0

  defp estimate_payload_tokens(payload) when is_binary(payload),
    do: max(1, div(byte_size(payload), 4))

  defp estimate_payload_tokens(payload) do
    payload
    |> Handbean.JSON.encode!()
    |> byte_size()
    |> then(&max(1, div(&1, 4)))
  end

  defp fire_on_compaction(_middle, %State{config: %{on_compaction: nil}}), do: :ok

  defp fire_on_compaction(middle, %State{config: %{on_compaction: callback}} = state)
       when is_function(callback, 2) do
    callback.(middle, state)
  rescue
    e ->
      Logger.warning(fn ->
        "on_compaction callback crashed: #{Exception.message(e)}\n" <>
          "Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}"
      end)

      :ok
  catch
    kind, payload ->
      Logger.warning(fn ->
        "on_compaction callback error (#{kind}): #{inspect(payload)}\n" <>
          "Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}"
      end)

      :ok
  end

  defp fire_on_compaction(_, _), do: :ok

  defp fire_on_compaction_complete(
         _event,
         %State{config: %{on_compaction_complete: nil}}
       ),
       do: nil

  defp fire_on_compaction_complete(
         event,
         %State{config: %{on_compaction_complete: callback}} = state
       )
       when is_function(callback, 2) do
    case callback.(event, state) do
      {:ok, %{"id" => id}} when is_binary(id) -> id
      {:ok, %{id: id}} when is_binary(id) -> id
      _ -> nil
    end
  rescue
    e ->
      Logger.warning(fn ->
        "on_compaction_complete callback crashed: #{Exception.message(e)}\n" <>
          "Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}"
      end)

      nil
  catch
    kind, payload ->
      Logger.warning(fn ->
        "on_compaction_complete callback error (#{kind}): #{inspect(payload)}\n" <>
          "Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}"
      end)

      nil
  end

  defp fire_on_compaction_complete(_, _), do: nil
end
