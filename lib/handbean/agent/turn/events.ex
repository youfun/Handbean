defmodule Handbean.Agent.Turn.Events do
  @moduledoc false

  alias Handbean.Agent.Message
  alias Handbean.Agent.Tool.ResultContract
  alias Handbean.Utils.SafeMap

  require Logger

  @max_tool_event_output 16_000
  @turn_end_counter_key {Handbean.Agent.Turn, :turn_end_counter}

  def reset_turn_end_counter, do: Process.delete(@turn_end_counter_key)

  def run_end_payload(result, duration_ms) do
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

    case result.interrupt_data do
      %{signal: signal, evidence: evidence} ->
        payload |> Map.put(:signal, signal) |> Map.put(:evidence, evidence)

      _ ->
        payload
    end
  end

  def turn_end_count, do: Process.get(@turn_end_counter_key, 0)

  def emit_turn_end(opts, payload) do
    Process.put(@turn_end_counter_key, turn_end_count() + 1)
    emit(opts, :turn_end, payload)
  end

  def emit(opts, kind, payload) do
    log_emit(kind, payload)

    case Keyword.get(opts, :on_event) do
      nil -> :ok
      fun when is_function(fun, 1) -> fun.({kind, payload})
    end
  end

  def notify_progress(opts, kind) do
    case Keyword.get(opts, :on_progress) do
      fun when is_function(fun, 1) -> fun.(kind)
      _ -> :ok
    end
  end

  def emit_provider_items(opts, messages) do
    items =
      messages
      |> Enum.flat_map(fn
        %Message{content: blocks} when is_list(blocks) ->
          Enum.filter(blocks, fn
            %{type: "responses_reasoning"} ->
              true

            %{"type" => "responses_reasoning"} ->
              true

            %{type: "text", phase: phase} when phase in ["commentary", "final_answer"] ->
              true

            %{"type" => "text", "phase" => phase}
            when phase in ["commentary", "final_answer"] ->
              true

            _ ->
              false
          end)

        _ ->
          []
      end)

    if items != [], do: emit(opts, :provider_items, %{items: items})
  end

  def emit_assistant_messages(opts, messages) do
    Enum.each(messages, fn
      %Message{role: :assistant} = message ->
        text = Message.text(message)
        if is_binary(text) and text != "", do: emit(opts, :message_delta, %{chunk: text})

      _ ->
        :ok
    end)
  end

  def emit_denied_tool_ends(blocks, opts, turn_number) do
    Enum.each(blocks, fn block ->
      details = block[:details] || %{}

      emit(opts, :tool_end, %{
        tool_use_id: block[:tool_use_id],
        tool: SafeMap.get_any(details, [:tool, "tool"]) || "unknown",
        turn_number: turn_number,
        duration_ms: 0,
        timing_fidelity: "not_started",
        details: bounded_tool_details(details),
        error: bounded_tool_error(block[:content]),
        output: bounded_tool_output(block[:content])
      })
    end)
  end

  def emit_tool_ends(tool_calls, ui_blocks, opts, turn_number) do
    ui_block_by_id =
      Map.new(ui_blocks, fn block ->
        {SafeMap.get_any(block, [:tool_use_id, "tool_use_id"]), block}
      end)

    Enum.each(tool_calls, fn call ->
      call_id = SafeMap.get_any(call, [:id, "id"])
      ui_block = Map.get(ui_block_by_id, call_id)
      details = (ui_block && ui_block[:details]) || %{}

      payload =
        %{
          tool_use_id: call_id,
          tool: SafeMap.get_any(call, [:name, "name"]),
          parent_tool_call_id: nil,
          turn_number: turn_number,
          details: bounded_tool_details(details),
          file_path: tool_end_file_path(details, call),
          images: Handbean.Tool.Images.project(ui_block && ui_block[:images]),
          published_media: Handbean.Media.project(ui_block && ui_block[:published_media]),
          output: bounded_tool_output(ui_block && block_content(ui_block))
        }
        |> Map.merge(tool_timing_payload(details))

      payload =
        if ui_block && ui_block[:is_error],
          do: Map.put(payload, :error, bounded_tool_error(block_content(ui_block))),
          else: payload

      emit(opts, :tool_end, payload)
    end)
  end

  def emit_tool_starts(calls, opts, turn_number) do
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

  def emit_executed_tool_ends(state, allowed_calls, ui_blocks, opts, duration_ms) do
    ui_block_by_id = Map.new(ui_blocks, fn block -> {block[:tool_use_id], block} end)

    Enum.each(allowed_calls, fn call ->
      ui_block = Map.get(ui_block_by_id, call[:id])
      record_tool_receipt(state, call, ui_block)
      emit(opts, :tool_end, executed_tool_end_payload(call, ui_block, duration_ms, state.turn))
    end)
  end

  def bounded_tool_output(output) when is_binary(output),
    do: String.slice(output, 0, @max_tool_event_output)

  def bounded_tool_output(output), do: Handbean.JsonSafe.normalize(output)

  def bounded_tool_error(error) when is_binary(error),
    do: String.slice(error, 0, @max_tool_event_output)

  def bounded_tool_error(error), do: error

  def bounded_tool_details(details), do: ResultContract.project_details(details || %{})

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

    if ui_block && ui_block[:is_error],
      do: Map.put(payload, :error, bounded_tool_error(ui_block[:content])),
      else: payload
  end

  defp maybe_put_not_started_timing(payload, details) do
    permission = SafeMap.get_any(details, [:permission, "permission"])
    side_effect = SafeMap.get_any(details, [:side_effect, "side_effect"])

    if is_nil(payload[:timing_fidelity]) and
         (permission in [:denied, "denied"] or side_effect in [:not_started, "not_started"]) do
      Map.merge(payload, %{duration_ms: 0, timing_fidelity: "not_started"})
    else
      payload
    end
  end

  defp tool_timing_payload(details) do
    %{
      started_at: SafeMap.get_any(details, [:started_at, "started_at"]),
      completed_at: SafeMap.get_any(details, [:completed_at, "completed_at"]),
      duration_ms: SafeMap.get_any(details, [:duration_ms, "duration_ms"]),
      timing_fidelity: SafeMap.get_any(details, [:timing_fidelity, "timing_fidelity"])
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp tool_end_file_path(details, call) do
    input = SafeMap.get_any(call || %{}, [:input, "input"]) || %{}

    SafeMap.get_any(details || %{}, [:file_path, "file_path"]) ||
      SafeMap.get_any(input, [:file_path, "file_path"])
  end

  defp block_content(block), do: SafeMap.get_any(block, [:content, "content"])

  defp record_tool_receipt(state, call, ui_block) do
    conversation_id = state.config.context[:conversation_id]
    call_id = call[:id]

    if is_binary(conversation_id) and is_binary(call_id) do
      details = (ui_block && ui_block[:details]) || %{}
      side_effect = SafeMap.get_any(details, [:side_effect, "side_effect"]) || :unknown

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
          "operation_id" => SafeMap.get_any(details, [:operation_id, "operation_id"])
        }
      )
    end

    :ok
  end

  defp redact_tool_input("publish_media", input) when is_map(input),
    do: Handbean.Tool.Builtin.PublishMedia.public_input(input)

  defp redact_tool_input("browser", input) when is_map(input) do
    input = Handbean.Log.Redactor.redact(input)
    args = Map.get(input, "args") || Map.get(input, :args)

    if is_list(args) do
      input
      |> Map.put("args", Handbean.Browser.Redactor.redact_args(args))
      |> Map.delete(:args)
    else
      input
    end
  end

  defp redact_tool_input(_name, input), do: Handbean.Log.Redactor.redact(input)

  defp log_emit(:message_delta, %{chunk: _chunk}), do: :ok

  defp log_emit(kind, payload) do
    Logger.debug("[Turn] emit #{kind} keys=#{inspect(Map.keys(payload || %{}))}")
  end
end
