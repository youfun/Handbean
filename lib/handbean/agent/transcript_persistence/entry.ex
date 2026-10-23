defmodule Handbean.Agent.TranscriptPersistence.Entry do
  @moduledoc false

  @assistant_completed_patch %{"status" => "completed"}

  def inbound(conversation_id, content, opts, turn_number, transcript_id) do
    base(conversation_id, opts, turn_number)
    |> Map.merge(%{
      "id" => transcript_id,
      "content_type" => "user_msg",
      "message_type" => "user",
      "role" => "user",
      "direction" => "inbound",
      "content" => message_text(content),
      "attachments" => persistable_attachments(content, opts),
      "raw_content" => persistable_raw_content(content, opts),
      "inbound_id" => Keyword.get(opts, :inbound_id) || transcript_id,
      "origin" => inbound_origin(opts),
      "consumption" =>
        if(inbound_delivery(opts) in ["steer", "follow_up"] or opts[:origin],
          do: "pending",
          else: nil
        )
    })
    |> put_inbound_delivery(opts)
  end

  def tool_start(conversation_id, payload, opts, turn_number, redacted_input, started_at) do
    tool_name = payload_value(payload, :tool, payload_value(payload, :name, "unknown"))
    tool_use_id = payload_value(payload, :tool_use_id, tool_name)

    base(conversation_id, opts, turn_number)
    |> Map.merge(%{
      "id" => tool_entry_id(tool_use_id, tool_name),
      "content_type" => "tool",
      "message_type" => "tool",
      "role" => "tool",
      "direction" => "internal",
      "turn_number" => payload_value(payload, :turn_number) || turn_number,
      "tool_use_id" => tool_use_id,
      "parent_tool_call_id" => payload_value(payload, :parent_tool_call_id),
      "tool_name" => tool_name,
      "tool_status" => "running",
      "input" => redacted_input,
      "started_at" => started_at,
      "timing_fidelity" => payload_value(payload, :timing_fidelity)
    })
  end

  def tool_end(conversation_id, payload, opts, turn_number) do
    tool_name = payload_value(payload, :tool) || payload_value(payload, :name)
    tool_use_id = payload_value(payload, :tool_use_id) || tool_name
    error = payload_value(payload, :error)
    raw_output = payload_value(payload, :output)

    details =
      payload
      |> payload_value(:details, %{})
      |> Handbean.Agent.Tool.ResultContract.project_details()
      |> Handbean.JsonSafe.normalize()

    patch =
      %{
        "tool_status" => tool_status(payload, error),
        "tool_duration_ms" => payload_value(payload, :duration_ms),
        "tool_error" => error,
        "output" => raw_output |> bound_persisted_output() |> Handbean.JsonSafe.normalize(),
        "output_truncated" => persisted_output_truncated?(raw_output),
        "details" => details,
        "images" => Handbean.Tool.Images.project(payload_value(payload, :images, [])),
        "file_path" => payload_value(payload, :file_path) || map_value(details, :file_path),
        "diff_lines" => map_value(details, :diff_lines)
      }
      |> put_if_present("tool_name", usable_tool_name(tool_name))
      |> put_if_present("started_at", payload_value(payload, :started_at))
      |> put_if_present("completed_at", payload_value(payload, :completed_at))
      |> put_if_present("timing_fidelity", payload_value(payload, :timing_fidelity))

    entry =
      base(conversation_id, opts, turn_number)
      |> Map.merge(%{
        "id" => tool_entry_id(tool_use_id, usable_tool_name(tool_name) || "unknown"),
        "content_type" => "tool",
        "message_type" => "tool",
        "role" => "tool",
        "direction" => "internal",
        "turn_number" => payload_value(payload, :turn_number) || turn_number,
        "tool_use_id" => tool_use_id,
        "parent_tool_call_id" => payload_value(payload, :parent_tool_call_id)
      })
      |> Map.merge(patch)

    published_media = Handbean.Media.project(payload_value(payload, :published_media, []))
    {entry, published_media, tool_use_id, entry["tool_status"]}
  end

  def media(_conversation_id, _tool_use_id, status, _media, _payload, _opts, _turn_number)
      when status != "done",
      do: nil

  def media(_conversation_id, _tool_use_id, "done", [], _payload, _opts, _turn_number), do: nil

  def media(conversation_id, tool_use_id, "done", media, payload, opts, turn_number)
      when is_binary(tool_use_id) do
    base(conversation_id, opts, turn_number)
    |> Map.merge(%{
      "id" => "msg-media-#{tool_use_id}",
      "content_type" => "assistant_msg",
      "message_type" => "assistant",
      "role" => "assistant",
      "direction" => "outbound",
      "phase" => "commentary",
      "status" => "completed",
      "content" => "",
      "turn_number" => payload_value(payload, :turn_number) || turn_number,
      "tool_call_id" => tool_use_id,
      "parent_tool_call_id" => payload_value(payload, :parent_tool_call_id),
      "attachments" => media
    })
  end

  def media(_conversation_id, _tool_use_id, _status, _media, _payload, _opts, _turn_number),
    do: nil

  def assistant(conversation_id, entry_id, content, phase, opts, turn_number) do
    base(conversation_id, opts, turn_number)
    |> Map.merge(%{
      "id" => entry_id,
      "content_type" => "assistant_msg",
      "message_type" => "assistant",
      "role" => "assistant",
      "direction" => "outbound",
      "content" => content,
      "status" => "streaming"
    })
    |> maybe_put_stream_phase(phase)
  end

  def notice(conversation_id, id, text, opts, turn_number) do
    base(conversation_id, opts, turn_number)
    |> Map.merge(%{
      "id" => id,
      "content_type" => "system_msg",
      "message_type" => "system",
      "role" => "system",
      "direction" => "outbound",
      "content" => text,
      "status" => "final"
    })
  end

  def run_error(conversation_id, error, opts, turn_number) do
    base(conversation_id, opts, turn_number)
    |> Map.merge(%{
      "id" => "msg-run-error-#{opts[:run_id] || "legacy"}",
      "content_type" => "system_msg",
      "message_type" => "error",
      "role" => "system",
      "direction" => "outbound",
      "content" => "Run error: #{error}",
      "status" => "final"
    })
  end

  def base(conversation_id, opts, turn_number) do
    %{
      "conversation_id" => conversation_id,
      "run_id" => Keyword.get(opts, :run_id),
      "turn_number" => turn_number,
      "channel" => channel(opts),
      "source" => opts |> Keyword.get(:source, :unknown) |> to_string(),
      "delivery_ref" => Keyword.get(opts, :delivery_ref),
      "metadata" => transcript_metadata(opts)
    }
  end

  def stop_notice_text(payload) do
    status = payload_value(payload, :status)
    error = payload_value(payload, :error)

    cond do
      status in [:max_turns, "max_turns"] ->
        "已达到 #{payload_value(payload, :turns, 0)} 轮上限，发送消息可继续。"

      status in [:stalled, "stalled"] ->
        "检测到没有进展：#{payload_value(payload, :evidence) || error}。运行已停止。"

      status in [:budget_exceeded, "budget_exceeded"] ->
        "已达到预算上限。运行已停止。"

      status in [:halted, "halted"] ->
        "运行已停止。#{error}"

      is_binary(error) and String.contains?(error, "尚未通过验收") ->
        error

      true ->
        nil
    end
  end

  def terminal_usage(payload) do
    if Handbean.PubSub.AgentEvent.terminal_status?(payload_value(payload, :status)) do
      case payload_value(payload, :usage) do
        usage when is_map(usage) -> usage
        _ -> %{}
      end
    end
  end

  def settlement_patch(entry, status, error) do
    cond do
      tool_entry?(entry) and running_tool_status?(Handbean.TranscriptEntry.tool_status(entry)) ->
        %{"tool_status" => status, "tool_error" => error}

      entry["role"] == "assistant" and entry["status"] == "streaming" ->
        %{"status" => status, "phase" => settled_phase(entry), "error" => error}

      true ->
        nil
    end
  end

  def running_tool_for_run?(entry, conversation_id, run_id) do
    tool_entry?(entry) and same_conversation?(entry, conversation_id) and same_run?(entry, run_id) and
      running_tool_status?(Handbean.TranscriptEntry.tool_status(entry))
  end

  def completion_patch(id, current, phase, recorded_phase?) do
    cond do
      recorded_phase? ->
        @assistant_completed_patch

      id == current and phase == "commentary" ->
        Map.put(@assistant_completed_patch, "phase", phase)

      id == current and is_binary(phase) and phase != "final_answer" ->
        Map.put(@assistant_completed_patch, "phase", phase)

      true ->
        @assistant_completed_patch
    end
  end

  def lifecycle_attrs(payload, opts) do
    %{
      run_id: payload_value(payload, :run_id) || Keyword.get(opts, :run_id),
      turn_number: payload_value(payload, :turn),
      status: payload_value(payload, :status),
      stop_reason:
        payload_value(payload, :stop_reason) || payload_value(payload, :provider_finish_reason),
      loop_owner: payload_value(payload, :loop_owner) || :handbean,
      backend: payload_value(payload, :backend),
      model: payload_value(payload, :model) || Keyword.get(opts, :model),
      provider: payload_value(payload, :provider),
      reasoning_level:
        payload_value(payload, :reasoning_level) || Keyword.get(opts, :reasoning_level),
      config_revision: payload_value(payload, :config_revision, 0),
      permission_mode: Keyword.get(opts, :permission_mode),
      permission_revision: Keyword.get(opts, :permission_revision),
      approval_mode: Keyword.get(opts, :approval_mode),
      approvals_reviewer: Keyword.get(opts, :approvals_reviewer),
      permission_source: Keyword.get(opts, :permission_source),
      delegated_approval: Keyword.get(opts, :delegated_approval),
      orphan_recovery?: Keyword.get(opts, :orphan_recovery?, false),
      code_baseline: payload_value(payload, :code_baseline) || Keyword.get(opts, :code_baseline),
      error: payload_value(payload, :error),
      turns: payload_value(payload, :turns),
      duration_ms: payload_value(payload, :duration_ms)
    }
  end

  def stream_segment(payload) do
    {stream_phase(payload), stream_index(payload)}
  end

  def delta_summary(saved, entry) do
    %{id: saved["id"], text_bytes: byte_size(saved["content"] || ""), entry: entry}
  end

  def delivery_channel?(opts) do
    Keyword.has_key?(opts, :delivery) or Keyword.get(opts, :source) in [:sns, :webhook, :cli]
  end

  def provider_item?(%{type: "responses_reasoning", item: item}) when is_map(item), do: true

  def provider_item?(%{"type" => "responses_reasoning", "item" => item}) when is_map(item),
    do: true

  def provider_item?(_), do: false

  def payload_value(payload, key, default \\ nil)

  def payload_value(payload, key, default) when is_map(payload) and is_atom(key) do
    Map.get(payload, key, Map.get(payload, Atom.to_string(key), default))
  end

  def payload_value(_payload, _key, default), do: default

  def stringify_value(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), stringify_value(item)} end)
  end

  def stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  def stringify_value(value) when is_atom(value), do: to_string(value)
  def stringify_value(value), do: value

  def append_patch(buffered), do: %{"$append" => buffered}
  def cancelled_run?(payload), do: payload_value(payload, :status) in [:cancelled, "cancelled"]
  def blank?(value), do: value in [nil, ""]
  def replace_message_id(%Handbean.Agent.Message{} = message, id), do: %{message | id: id}
  def replace_message_id(content, _id), do: content

  defp stream_phase(%{phase: phase}) when phase in ["commentary", "final_answer"], do: phase
  defp stream_phase(%{"phase" => phase}) when phase in ["commentary", "final_answer"], do: phase
  defp stream_phase(_), do: nil

  defp stream_index(%{output_index: index}) when is_integer(index), do: index
  defp stream_index(%{"output_index" => index}) when is_integer(index), do: index
  defp stream_index(_), do: nil

  defp tool_entry?(entry) when is_map(entry) do
    entry["content_type"] == "tool" or entry["message_type"] == "tool" or entry["role"] == "tool"
  end

  defp tool_entry?(_entry), do: false

  defp same_conversation?(entry, conversation_id) do
    case Handbean.Utils.SafeMap.get_any(entry, "conversation_id", :conversation_id) do
      nil -> true
      id -> to_string(id) == to_string(conversation_id)
    end
  end

  defp same_run?(entry, run_id) do
    entry_run = Handbean.Utils.SafeMap.get_any(entry, "run_id", :run_id)
    not blank?(entry_run) and to_string(entry_run) == to_string(run_id)
  end

  defp running_tool_status?(status), do: status in [:running, "running"]

  defp settled_phase(%{"phase" => phase}) when phase in ["commentary", "final_answer"],
    do: phase

  defp settled_phase(_entry), do: "final"

  defp maybe_put_stream_phase(entry, phase) when phase in ["commentary", "final_answer"],
    do: Map.put(entry, "phase", phase)

  defp maybe_put_stream_phase(entry, _phase), do: entry

  defp put_inbound_delivery(entry, opts) do
    delivery = inbound_delivery(opts)

    entry
    |> Map.put("delivery", delivery)
    |> Map.put("interrupts_work", delivery == "steer")
  end

  defp inbound_delivery(opts) do
    case Keyword.get(opts, :deliver_as) do
      value when value in [:steer, "steer"] -> "steer"
      value when value in [:follow_up, "follow_up"] -> "follow_up"
      value when value in [:next_turn, "next_turn"] -> "next_turn"
      _ -> "new_run"
    end
  end

  defp inbound_origin(opts) do
    opts[:origin] ||
      if opts[:source] in [:webhook, :sns, :schedule, :scheduler],
        do: %{"kind" => "automatic", "source" => to_string(opts[:source])}
  end

  defp message_text(%Handbean.Agent.Message{} = message),
    do: Handbean.Agent.Message.text(message) || ""

  defp message_text(content) when is_binary(content), do: content
  defp message_text(_content), do: ""

  defp persistable_attachments(_content, opts) do
    case Keyword.get(opts, :attachments) do
      list when is_list(list) and list != [] ->
        Enum.map(list, &Handbean.Attachments.persistable/1)

      _ ->
        []
    end
  end

  defp persistable_raw_content(content, opts) do
    attachments = persistable_attachments(content, opts)

    cond do
      attachments != [] ->
        %{"text" => message_text(content), "attachments" => attachments}

      match?(%Handbean.Agent.Message{content: list} when is_list(list), content) ->
        content.content |> Enum.map(&sanitize_block/1) |> stringify_value()

      true ->
        content
    end
  end

  defp sanitize_block(block) when is_map(block) do
    block |> stringify_value() |> Map.drop(["data", "uri"])
  end

  defp sanitize_block(block), do: block

  defp tool_status(payload, error) do
    case payload_value(payload, :status) do
      status when status in [:cancelled, "cancelled"] -> "cancelled"
      status when status in [:failed, "failed", :interrupted, "interrupted"] -> "error"
      _status when not is_nil(error) -> "error"
      _status -> "done"
    end
  end

  defp tool_entry_id(tool_use_id, tool_name) do
    if is_binary(tool_use_id) and tool_use_id != "",
      do: "tool-#{tool_use_id}",
      else: "tool-event-#{tool_name}"
  end

  defp usable_tool_name(name) when is_binary(name) do
    if String.trim(name) in ["", "unknown"], do: nil, else: name
  end

  defp usable_tool_name(_), do: nil

  defp persisted_output_truncated?(output) when is_binary(output), do: byte_size(output) > 16_000
  defp persisted_output_truncated?(_output), do: false

  defp bound_persisted_output(output) when is_binary(output) and byte_size(output) > 16_000 do
    String.slice(output, 0, 15_900) <> "\n[truncated]"
  end

  defp bound_persisted_output(output), do: output

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp map_value(_map, _key), do: nil

  defp transcript_metadata(opts) do
    opts
    |> Keyword.take([:workspace_id, :model, :source, :chat_scope])
    |> Map.new(fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp channel(opts) do
    opts |> Keyword.get(:channel, Keyword.get(opts, :source, :unknown)) |> to_string()
  end
end
