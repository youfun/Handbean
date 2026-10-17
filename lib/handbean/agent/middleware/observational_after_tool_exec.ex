defmodule Handbean.Agent.Middleware.ObservationalAfterToolExec do
  @moduledoc """
  Observational Memory middleware — records an observation each time
  the agent executes tools.

  ## Behavior
    - On `:after_tool_execution`: extracts tool name, input summary,
      success/failure status, and key output details from the last tool
      execution batch. Creates observations and appends them to the
      ObservationStore.
    - On all other hooks: passes through unchanged.

  This is a no-LLM observation — it captures structured metadata about
  tool usage for future context injection and Observer processing.
  """

  @behaviour Handbean.Agent.Middleware

  alias Handbean.Agent.{Message, State}
  alias Handbean.Memory.{Observation, ObservationStore}
  alias Handbean.Memory.ObservationalConfig, as: Config

  @max_input_chars 200

  @impl true
  def call(:after_tool_execution, %State{} = state) do
    cond do
      not Config.for_state(state).enabled ->
        state

      is_nil(session_id(state)) ->
        state

      true ->
        record_tool_executions(state)
        state
    end
  end

  @impl true
  def call(_hook, state), do: state

  # ── Recording ──

  defp record_tool_executions(%State{messages: messages} = state) do
    sid = session_id(state)

    # Find the most recent assistant message with tool_use blocks
    tool_use_msg =
      messages
      |> Enum.reverse()
      |> Enum.find(fn
        %Message{role: :assistant} = msg -> Message.tool_calls(msg) != []
        _ -> false
      end)

    # Find the corresponding tool_result message (usually right after)
    tool_result_msg =
      messages
      |> Enum.reverse()
      |> Enum.find(fn
        %Message{role: :user} = msg -> has_tool_results?(msg)
        _ -> false
      end)

    tool_calls = if tool_use_msg, do: Message.tool_calls(tool_use_msg), else: []
    tool_results = if tool_result_msg, do: extract_tool_results(tool_result_msg), else: %{}

    Enum.each(tool_calls, fn call ->
      call_id = Handbean.Utils.SafeMap.get_any(call, :id, "id")
      tool_name = Handbean.Utils.SafeMap.get_any(call, :name, "name") || "unknown"
      input = Handbean.Utils.SafeMap.get_any(call, :input, "input") || %{}
      result = Map.get(tool_results, call_id)

      obs = build_tool_observation(tool_name, input, result, state)
      ObservationStore.append(sid, obs)
    end)
  end

  defp build_tool_observation(tool_name, input, result, %State{} = state) do
    input_summary = summarize_input(tool_name, input)
    result_summary = summarize_result(result)
    file_path = extract_file_path(tool_name, input, result)

    content =
      [
        "Tool #{tool_name} executed",
        input_summary |> reject_empty(),
        (file_path && "on #{file_path}") |> reject_empty(),
        result_summary |> reject_empty()
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" — ")

    metadata =
      %{
        tool_name: tool_name,
        turn: state.turn
      }
      |> Map.merge(scope_metadata(state))
      |> maybe_put(:file_path, file_path)
      |> maybe_put(:is_error, result && result[:is_error])
      |> maybe_put(:duration_ms, result && result[:duration_ms])

    priority = if result && result[:is_error], do: :high, else: :low

    Observation.new(content,
      priority: priority,
      source: :tool_execution,
      metadata: metadata
    )
  end

  defp summarize_input(tool_name, input) when is_map(input) do
    # Extract the most relevant arg for each tool type
    case tool_name do
      "read" ->
        path = Handbean.Utils.SafeMap.get_any(input, :file_path, "file_path")
        "read(#{path || "?"})"

      "edit" ->
        path = Handbean.Utils.SafeMap.get_any(input, :file_path, "file_path")
        edits = Handbean.Utils.SafeMap.get_any(input, :edits, "edits")
        edit_count = if is_list(edits), do: length(edits), else: 0
        "edit(#{path || "?"}, #{edit_count} edits)"

      "write" ->
        path = Handbean.Utils.SafeMap.get_any(input, :file_path, "file_path")
        "write(#{path || "?"})"

      "bash" ->
        command = Handbean.Utils.SafeMap.get_any(input, :command, "command") || ""
        preview = String.slice(to_string(command), 0, @max_input_chars)
        "bash(#{preview})"

      _ ->
        input_str = Handbean.JSON.encode!(input)
        String.slice(input_str, 0, @max_input_chars)
    end
  end

  defp summarize_input(_tool_name, _input), do: ""

  defp summarize_result(nil), do: nil

  defp summarize_result(%{is_error: true} = result),
    do: "FAILED: #{truncate(result[:content], 100)}"

  defp summarize_result(%{content: content}) when is_binary(content) do
    "OK (#{byte_size(content)} bytes)"
  end

  defp summarize_result(%{content: blocks}) when is_list(blocks) do
    text_blocks = Enum.count(blocks, &(&1[:type] == "text" || &1["type"] == "text"))
    "OK (#{text_blocks} blocks)"
  end

  defp summarize_result(_), do: nil

  defp extract_file_path(tool_name, input, _result) do
    case tool_name do
      t when t in ["read", "edit", "write"] ->
        Handbean.Utils.SafeMap.get_any(input, :file_path, "file_path")

      "bash" ->
        # Try to extract a meaningful path from command or working dir
        nil

      _ ->
        nil
    end
  end

  # ── Tool result extraction ──

  defp has_tool_results?(%Message{content: blocks}) when is_list(blocks) do
    Enum.any?(blocks, fn
      %{type: type} when type in ["tool_result", "server_tool_result"] -> true
      _ -> false
    end)
  end

  defp has_tool_results?(_), do: false

  defp extract_tool_results(%Message{content: blocks}) when is_list(blocks) do
    Map.new(blocks, fn
      %{type: type, tool_use_id: id} = block when type in ["tool_result", "server_tool_result"] ->
        {id,
         %{
           is_error: Map.get(block, :is_error, false),
           content: Map.get(block, :content),
           details: Map.get(block, :details, %{})
         }}

      %{"type" => type, "tool_use_id" => id} = block
      when type in ["tool_result", "server_tool_result"] ->
        {id,
         %{
           is_error: Map.get(block, "is_error", false),
           content: Map.get(block, "content"),
           details: Map.get(block, "details", %{})
         }}

      _ ->
        {:skip, nil}
    end)
    |> Enum.reject(fn {k, _} -> k == :skip end)
  end

  defp extract_tool_results(_), do: %{}

  # ── Helpers ──

  defp reject_empty(nil), do: nil
  defp reject_empty(""), do: nil
  defp reject_empty(str), do: str

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp scope_metadata(%State{} = state) do
    memory_scope = context_value(state, :memory_scope)
    workspace_id = context_value(state, :workspace_id)
    privacy_mode = context_value(state, :privacy_mode)

    scope =
      case memory_scope do
        scope when scope in [:global, "global"] -> "global"
        _ when is_binary(workspace_id) -> "workspace"
        _ -> nil
      end

    %{}
    |> maybe_put(:scope, scope)
    |> maybe_put(:workspace_id, if(scope == "workspace", do: workspace_id, else: nil))
    |> maybe_put(:privacy_mode, privacy_mode && to_string(privacy_mode))
  end

  defp context_value(%State{config: %{context: context}, run_metadata: run_metadata}, key) do
    map_value(context, key) || map_value(run_metadata, key)
  end

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_value(_map, _key), do: nil

  defp truncate(nil, _len), do: nil
  defp truncate(str, len) when is_binary(str), do: String.slice(str, 0, len)

  defp session_id(%State{run_metadata: %{session_id: sid}}) when is_binary(sid), do: sid
  defp session_id(_), do: nil
end
