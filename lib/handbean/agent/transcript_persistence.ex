defmodule Handbean.Agent.TranscriptPersistence do
  @moduledoc """
  Persists runtime events into the cross-channel conversation transcript.

  This module is runtime-side, not UI-side. LiveView, SNS, webhook, CLI, and
  future channels should all be able to recover conversation history from the
  transcript without needing a LiveView process to have been alive.
  """

  require Logger

  @assistant_completed_patch %{"status" => "completed"}

  @spec append_inbound(String.t(), String.t() | Handbean.Agent.Message.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def append_inbound(conversation_id, content, opts)
      when is_binary(conversation_id) and is_list(opts) do
    append_inbound(conversation_id, content, opts, nil, 3)
  end

  @doc "Persist an accepted inbound message and complete its operation receipt together."
  @spec accept_inbound(String.t(), String.t() | Handbean.Agent.Message.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def accept_inbound(conversation_id, content, receipt, opts)
      when is_binary(conversation_id) and is_map(receipt) and is_list(opts) do
    append_inbound(conversation_id, content, opts, receipt, 3)
  end

  defp append_inbound(conversation_id, content, opts, receipt, attempts) do
    transcript_id = Keyword.get(opts, :transcript_id) || unique_id("msg-user")

    entry =
      base_entry(conversation_id, opts)
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

    case persist_inbound(conversation_id, entry, receipt, opts) do
      {:error, :duplicate_id} when attempts > 1 ->
        id = unique_id("msg-user")

        opts =
          opts
          |> Keyword.put(:transcript_id, id)
          |> Keyword.put(:message_id, id)
          |> Keyword.put(:inbound_id, id)

        append_inbound(
          conversation_id,
          replace_message_id(content, id),
          opts,
          receipt,
          attempts - 1
        )

      other ->
        other
    end
  end

  defp persist_inbound(conversation_id, entry, nil, opts) do
    Handbean.ConversationTranscriptStore.append(conversation_id, entry, opts)
  end

  defp persist_inbound(conversation_id, entry, receipt, opts) do
    store = Handbean.ConversationTranscriptStore.impl(opts)
    request_id = Keyword.get(opts, :request_id)

    if function_exported?(store, :append_with_receipt, 5) do
      store.append_with_receipt(conversation_id, entry, request_id, receipt, opts)
    else
      with {:ok, persisted} <-
             Handbean.ConversationTranscriptStore.append(conversation_id, entry, opts),
           :ok <-
             Handbean.Agent.OperationReceipt.complete(
               {:message, conversation_id},
               request_id,
               receipt
             ) do
        {:ok, persisted}
      end
    end
  end

  @spec handle_event(String.t(), {atom(), map()}, keyword()) :: :ok | {:error, term()}
  def handle_event(conversation_id, event, opts \\ [])

  def handle_event(conversation_id, {:run_start, payload}, opts)
      when is_binary(conversation_id) do
    with :ok <- record_lifecycle(:run_start, conversation_id, lifecycle_attrs(payload, opts)),
         :ok <- consume_inbound(conversation_id, opts) do
      clear_process_state(conversation_id)
      Process.put(run_opts_key(conversation_id), opts)
      Process.put(run_payload_key(conversation_id), payload)

      Handbean.Agent.TranscriptRecovery.mark(conversation_id)
      Logger.debug("[TranscriptPersistence] run_start conversation=#{conversation_id}")
      :ok
    end
  end

  def handle_event(conversation_id, {:message_delta, %{chunk: chunk} = payload}, opts)
      when is_binary(conversation_id) and is_binary(chunk) and chunk != "" do
    Process.delete({__MODULE__, :text_patch, conversation_id})

    {thinking_text, clean_chunk, new_buffer} =
      Handbean.Agent.ThinkingFilter.strip(thinking_buffer(conversation_id), chunk)

    put_thinking_buffer(conversation_id, new_buffer)
    append_thinking(conversation_id, thinking_text)
    open_segment(conversation_id, payload, opts)
    append_to_buffer(conversation_id, clean_chunk)
    # The journal syncs each drained batch before Runner projects or broadcasts
    # it; accepting a chunk into an in-memory batch is an earlier boundary.
    flush!(conversation_id, opts)
    :ok
  end

  def handle_event(conversation_id, {:message_delta, payload}, opts)
      when is_binary(conversation_id) and is_map(payload) do
    Process.delete({__MODULE__, :text_patch, conversation_id})
    flush!(conversation_id, opts)
    :ok
  end

  # Explicit handler for thinking_delta: don't flush (unlike the catch-all).
  # thinking_delta is a high-frequency streaming event emitted by Anthropic
  # and StepFun providers during extended thinking. It should not trigger
  # transcript writes — the thinking buffer accumulates alongside assistant
  # text and is flushed at the next message boundary.
  def handle_event(conversation_id, {:thinking_delta, _payload}, _opts)
      when is_binary(conversation_id) do
    :ok
  end

  def handle_event(conversation_id, {:provider_items, %{items: items}}, opts)
      when is_binary(conversation_id) and is_list(items) do
    remember_provider_items(conversation_id, items)
    persist_provider_items(conversation_id, opts)
  end

  def handle_event(conversation_id, {:turn_start, payload}, opts)
      when is_binary(conversation_id) do
    flush!(conversation_id, opts)
    turn_number = payload_value(payload, :turn)

    attrs =
      payload
      |> lifecycle_attrs(opts)
      |> Map.put(:turn_number, turn_number)

    with :ok <- record_lifecycle(:turn_start, conversation_id, attrs) do
      Process.put(turn_key(conversation_id), turn_number)
      :ok
    end
  end

  def handle_event(conversation_id, {:turn_end, payload}, opts)
      when is_binary(conversation_id) do
    flush!(conversation_id, opts)
    turn_number = payload_value(payload, :turn) || Process.get(turn_key(conversation_id))

    attrs =
      payload
      |> lifecycle_attrs(opts)
      |> Map.put(:turn_number, turn_number)

    with :ok <- record_lifecycle(:turn_end, conversation_id, attrs) do
      Process.delete(turn_key(conversation_id))
      :ok
    end
  end

  def handle_event(conversation_id, {:tool_start, payload}, opts)
      when is_binary(conversation_id) do
    flush!(conversation_id, opts)
    :ok = finalize_assistant(conversation_id, "commentary", opts)
    Process.put(assistant_key(conversation_id), nil)

    tool_name = payload_value(payload, :tool, payload_value(payload, :name, "unknown"))
    tool_use_id = payload_value(payload, :tool_use_id, tool_name)

    entry =
      base_entry(conversation_id, opts)
      |> Map.merge(%{
        "id" => tool_entry_id(tool_use_id, tool_name),
        "content_type" => "tool",
        "message_type" => "tool",
        "role" => "tool",
        "direction" => "internal",
        "turn_number" =>
          payload_value(payload, :turn_number) || Process.get(turn_key(conversation_id)),
        "tool_use_id" => tool_use_id,
        "parent_tool_call_id" => payload_value(payload, :parent_tool_call_id),
        "tool_name" => tool_name,
        "tool_status" => "running",
        "input" => Handbean.Log.Redactor.redact(payload_value(payload, :input, %{})),
        "started_at" => payload_value(payload, :started_at) || now_iso8601(),
        "timing_fidelity" => payload_value(payload, :timing_fidelity)
      })
      |> maybe_put_provider_items(conversation_id)

    with {:ok, _saved} <- append_or_update(conversation_id, entry, opts), do: :ok
  end

  def handle_event(conversation_id, {:tool_end, payload}, opts) when is_binary(conversation_id) do
    flush!(conversation_id, opts)

    tool_name = payload_value(payload, :tool) || payload_value(payload, :name)
    tool_use_id = payload_value(payload, :tool_use_id) || tool_name
    error = payload_value(payload, :error)
    status = tool_status(payload, error)
    published_media = Handbean.Media.project(payload_value(payload, :published_media, []))

    details =
      payload
      |> payload_value(:details, %{})
      |> Handbean.Agent.Tool.ResultContract.project_details()
      |> Handbean.JsonSafe.normalize()

    raw_output = payload_value(payload, :output)

    output =
      raw_output
      |> bound_persisted_output()
      |> Handbean.JsonSafe.normalize()

    patch =
      %{
        "tool_status" => status,
        "tool_duration_ms" => payload_value(payload, :duration_ms),
        "tool_error" => error,
        "output" => output,
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
      base_entry(conversation_id, opts)
      |> Map.merge(%{
        "id" => tool_entry_id(tool_use_id, usable_tool_name(tool_name) || "unknown"),
        "content_type" => "tool",
        "message_type" => "tool",
        "role" => "tool",
        "direction" => "internal",
        "turn_number" =>
          payload_value(payload, :turn_number) || Process.get(turn_key(conversation_id)),
        "tool_use_id" => tool_use_id,
        "parent_tool_call_id" => payload_value(payload, :parent_tool_call_id)
      })
      |> Map.merge(patch)

    media_entry =
      media_entry(conversation_id, tool_use_id, status, published_media, payload, opts)

    with {:ok, result} <-
           complete_tool_call(
             conversation_id,
             entry,
             media_entry,
             Handbean.Media.ids(published_media),
             opts
           ),
         :ok <- maybe_deliver_media(result.media_entry, opts) do
      :ok
    end
  end

  def handle_event(conversation_id, {:candidate_message_injected, %{message_ids: ids}}, opts)
      when is_list(ids) do
    flush!(conversation_id, opts)

    # Text after an injected message answers it, so it must not extend the
    # assistant entry written before the injection.
    if ids != [] do
      :ok = finalize_assistant(conversation_id, "commentary", opts)
      Process.put(assistant_key(conversation_id), nil)
    end

    consume_messages(conversation_id, ids, opts)
  end

  def handle_event(conversation_id, {:stall_check_requested, payload}, opts)
      when is_binary(conversation_id) do
    evidence = payload_value(payload, :evidence) || "检测到没有进展"
    write_notice(conversation_id, "msg-stall-#{opts[:run_id] || "legacy"}", evidence, opts)
  end

  def handle_event(conversation_id, {:run_end, payload}, opts) when is_binary(conversation_id) do
    flush!(conversation_id, opts)

    with :ok <- record_stop_notice(conversation_id, payload, opts) do
      run_error = payload_value(payload, :error)
      terminal_opts = Keyword.put(opts, :terminal_usage, terminal_usage(payload))

      result =
        cond do
          cancelled_run?(payload) ->
            settle_unfinished(conversation_id, "cancelled", nil, terminal_opts)

          is_nil(run_error) and
              payload_value(payload, :status) in [:error, "error", :timeout, "timeout"] ->
            settle_unfinished(conversation_id, "error", nil, terminal_opts)

          not is_nil(run_error) ->
            with :ok <- persist_run_error(conversation_id, run_error, opts) do
              settle_unfinished(conversation_id, "error", run_error, terminal_opts)
            end

          true ->
            finalize_successful_run(conversation_id, terminal_opts)
        end

      with :ok <- result,
           :ok <- record_lifecycle(:run_end, conversation_id, lifecycle_attrs(payload, opts)) do
        clear_process_state(conversation_id)
        Handbean.Agent.TranscriptRecovery.clear(conversation_id)
        :ok
      end
    end
  end

  def handle_event(conversation_id, _event, opts) when is_binary(conversation_id) do
    flush!(conversation_id, opts)
    :ok
  end

  def handle_event(_conversation_id, _event, _opts), do: :ok

  @doc "Attach the exact persisted text position to a delta before Session broadcasts it."
  def project_event(conversation_id, {:message_delta, payload}) do
    patch = Process.get({__MODULE__, :text_patch, conversation_id}, %{})
    {:message_delta, Map.merge(payload, patch)}
  end

  def project_event(_conversation_id, event), do: event

  @doc false
  def discard_pending(conversation_id) when is_binary(conversation_id) do
    clear_buffer(conversation_id)
    Process.delete({__MODULE__, :text_patch, conversation_id})
    :ok
  end

  @doc """
  Marks durable in-flight tools for this conversation+run as cancelled.

  Scans the transcript store rather than the agent-task process dictionary, so
  Runner can seal a killed run before broadcasting `run_end`. Terminal tool
  statuses and other runs are left unchanged. `:interrupted` is not cancel.
  """
  @spec cancel_running_tools(String.t(), keyword()) :: :ok | {:error, term()}
  def cancel_running_tools(conversation_id, opts \\ []) when is_binary(conversation_id) do
    run_id = Keyword.get(opts, :run_id)

    cond do
      blank?(run_id) ->
        Logger.error(
          "[TranscriptPersistence] cancel_running_tools missing run_id conversation=#{conversation_id}"
        )

        {:error, :missing_run_id}

      true ->
        store = Handbean.ConversationTranscriptStore.impl(opts)

        if function_exported?(store, :cancel_running_tools, 3) do
          store.cancel_running_tools(conversation_id, run_id, opts)
        else
          cancel_running_tools_with_store(conversation_id, run_id, opts)
        end
    end
  end

  defp append_or_update(conversation_id, %{"id" => id} = entry, opts) do
    case Handbean.ConversationTranscriptStore.update(conversation_id, id, entry, opts) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, :not_found} ->
        Handbean.ConversationTranscriptStore.append(conversation_id, entry, opts)

      {:error, reason} ->
        Logger.warning(fn ->
          "[TranscriptPersistence] failed to update transcript entry conversation=#{conversation_id} " <>
            "id=#{id} reason=#{inspect(reason)}"
        end)

        {:error, reason}
    end
  end

  defp media_entry(_conversation_id, _tool_use_id, status, _media, _payload, _opts)
       when status != "done",
       do: nil

  defp media_entry(_conversation_id, _tool_use_id, "done", [], _payload, _opts), do: nil

  defp media_entry(conversation_id, tool_use_id, "done", media, payload, opts)
       when is_binary(tool_use_id) do
    base_entry(conversation_id, opts)
    |> Map.merge(%{
      "id" => "msg-media-#{tool_use_id}",
      "content_type" => "assistant_msg",
      "message_type" => "assistant",
      "role" => "assistant",
      "direction" => "outbound",
      "phase" => "commentary",
      "status" => "completed",
      "content" => "",
      "turn_number" =>
        payload_value(payload, :turn_number) || Process.get(turn_key(conversation_id)),
      "tool_call_id" => tool_use_id,
      "parent_tool_call_id" => payload_value(payload, :parent_tool_call_id),
      "attachments" => media
    })
  end

  defp media_entry(_conversation_id, _tool_use_id, _status, _media, _payload, _opts), do: nil

  defp complete_tool_call(conversation_id, tool_entry, nil, [], opts) do
    with {:ok, saved_tool} <- persist_tool_end(conversation_id, tool_entry, opts) do
      {:ok, %{tool_entry: saved_tool, media_entry: nil}}
    end
  end

  defp complete_tool_call(conversation_id, tool_entry, media_entry, media_ids, opts) do
    store = Handbean.ConversationTranscriptStore.impl(opts)

    if function_exported?(store, :complete_tool_call, 5) do
      store.complete_tool_call(conversation_id, tool_entry, media_entry, media_ids, opts)
    else
      complete_tool_call_fallback(conversation_id, tool_entry, media_entry, media_ids, opts)
    end
  end

  defp complete_tool_call_fallback(conversation_id, tool_entry, media_entry, media_ids, opts) do
    tool_use_id = tool_entry["tool_use_id"]

    with {:ok, saved_tool} <- persist_tool_end(conversation_id, tool_entry, opts),
         {:ok, _ready} <-
           Handbean.Media.mark_ready(
             conversation_id,
             tool_use_id,
             media_entry["id"],
             media_ids
           ),
         {:ok, saved_media} <- append_or_update(conversation_id, media_entry, opts) do
      {:ok, %{tool_entry: saved_tool, media_entry: saved_media}}
    end
  end

  defp maybe_deliver_media(nil, _opts), do: :ok
  defp maybe_deliver_media(entry, opts), do: deliver(entry, opts)

  # CLI backends such as Droid emit tool_result without a name. Updating the
  # existing row must not replace the start name with the "unknown" placeholder.
  defp persist_tool_end(conversation_id, %{"id" => id} = entry, opts) do
    case Handbean.ConversationTranscriptStore.update(conversation_id, id, entry, opts) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, :not_found} ->
        Handbean.ConversationTranscriptStore.append(
          conversation_id,
          Map.put_new(entry, "tool_name", "unknown"),
          opts
        )

      {:error, reason} ->
        Logger.warning(fn ->
          "[TranscriptPersistence] failed to update transcript entry conversation=#{conversation_id} " <>
            "id=#{id} reason=#{inspect(reason)}"
        end)

        {:error, reason}
    end
  end

  defp consume_messages(conversation_id, ids, opts) do
    Handbean.ConversationTranscriptStore.consume(
      conversation_id,
      ids,
      %{"consumption" => "consumed", "consumed_run_id" => opts[:run_id]},
      opts
    )
  end

  defp buffer_key(conversation_id), do: {__MODULE__, :buffer, conversation_id}
  defp last_flush_key(conversation_id), do: {__MODULE__, :last_flush, conversation_id}
  defp thinking_buffer_key(conversation_id), do: {__MODULE__, :thinking_buffer, conversation_id}
  defp thinking_key(conversation_id), do: {__MODULE__, :thinking, conversation_id}
  defp assistant_key(conversation_id), do: {__MODULE__, :assistant_entry_id, conversation_id}
  defp run_opts_key(conversation_id), do: {__MODULE__, :run_opts, conversation_id}
  defp run_payload_key(conversation_id), do: {__MODULE__, :run_payload, conversation_id}

  defp patch_running_tools_cancelled(conversation_id, entries, run_id, opts) do
    errors =
      entries
      |> Enum.filter(&running_tool_for_run?(&1, conversation_id, run_id))
      |> Enum.reduce([], fn entry, acc ->
        id = Handbean.Utils.SafeMap.get_any(entry, "id", :id)

        cond do
          not is_binary(id) ->
            Logger.warning(fn ->
              "[TranscriptPersistence] cancel_running_tools missing entry id conversation=#{conversation_id}"
            end)

            [{:invalid_entry_id, id} | acc]

          true ->
            case Handbean.ConversationTranscriptStore.update(
                   conversation_id,
                   id,
                   %{"tool_status" => "cancelled"},
                   opts
                 ) do
              {:ok, _} ->
                acc

              {:error, :not_found} ->
                Logger.warning(fn ->
                  "[TranscriptPersistence] cancel_running_tools entry vanished conversation=#{conversation_id} " <>
                    "id=#{inspect(id)}"
                end)

                acc

              {:error, reason} ->
                Logger.warning(fn ->
                  "[TranscriptPersistence] cancel_running_tools update failed conversation=#{conversation_id} " <>
                    "id=#{inspect(id)} reason=#{inspect(reason)}"
                end)

                [reason | acc]
            end
        end
      end)

    case errors do
      [] -> :ok
      _ -> {:error, {:cancel_running_tools, Enum.reverse(errors)}}
    end
  end

  defp cancel_running_tools_with_store(conversation_id, run_id, opts) do
    case Handbean.ConversationTranscriptStore.list(conversation_id, opts) do
      {:ok, entries} ->
        patch_running_tools_cancelled(conversation_id, entries, run_id, opts)

      {:error, reason} ->
        Logger.error(
          "[TranscriptPersistence] cancel_running_tools list failed conversation=#{conversation_id} " <>
            "reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp running_tool_for_run?(entry, conversation_id, run_id) do
    tool_entry?(entry) and
      same_conversation?(entry, conversation_id) and
      same_run?(entry, run_id) and
      running_tool_status?(Handbean.TranscriptEntry.tool_status(entry))
  end

  defp tool_entry?(entry) when is_map(entry) do
    entry["content_type"] == "tool" or entry["message_type"] == "tool" or
      entry["role"] == "tool"
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

  defp running_tool_status?(status) when status in [:running, "running"], do: true
  defp running_tool_status?(_status), do: false

  defp cancelled_run?(payload) do
    payload_value(payload, :status) in [:cancelled, "cancelled"]
  end

  # Runner persists this before Session broadcasts, so every channel records
  # the same terminal total whether or not a LiveView is connected.
  # `:interrupted` is approval wait, not a finished run; the resumed run_end
  # carries the cumulative usage for the same run_id.
  defp record_stop_notice(conversation_id, payload, opts) do
    status = payload_value(payload, :status)
    error = payload_value(payload, :error)

    text =
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

    if is_binary(text) and text != "" do
      write_notice(conversation_id, "msg-run-stop-#{opts[:run_id] || "legacy"}", text, opts)
    else
      :ok
    end
  end

  defp write_notice(conversation_id, id, text, opts) do
    entry =
      base_entry(conversation_id, opts)
      |> Map.merge(%{
        "id" => id,
        "content_type" => "system_msg",
        "message_type" => "system",
        "role" => "system",
        "direction" => "outbound",
        "content" => text,
        "status" => "final"
      })

    case append_or_update(conversation_id, entry, opts) do
      {:ok, saved} ->
        deliver(saved, opts)
        :ok

      {:error, reason} ->
        Logger.error(
          "[TranscriptPersistence] stop notice failed conversation=#{conversation_id} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp terminal_usage(payload) do
    status = payload_value(payload, :status)

    if Handbean.PubSub.AgentEvent.terminal_status?(status) do
      case payload_value(payload, :usage) do
        usage when is_map(usage) -> usage
        _ -> %{}
      end
    end
  end

  defp record_terminal_usage(conversation_id, usage, opts) do
    run_id = opts[:run_id]

    cond do
      is_nil(usage) ->
        :ok

      not is_binary(run_id) or run_id == "" ->
        :ok

      true ->
        case Handbean.ConversationStore.record_run_usage(conversation_id, run_id, usage) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error(
              "[TranscriptPersistence] run usage not recorded conversation=#{conversation_id} " <>
                "run_id=#{run_id} reason=#{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  defp finalize_successful_run(conversation_id, opts) do
    store = Handbean.ConversationTranscriptStore.impl(opts)

    if store == Handbean.ConversationTranscriptStore.ConversationStore do
      Handbean.Repo.transaction(
        fn ->
          with :ok <- finalize_assistant(conversation_id, "final", opts),
               :ok <- record_terminal_usage(conversation_id, opts[:terminal_usage], opts) do
            :ok
          else
            {:error, reason} -> Handbean.Repo.rollback(reason)
          end
        end,
        mode: :immediate
      )
      |> case do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      with :ok <- finalize_assistant(conversation_id, "final", opts),
           :ok <- record_terminal_usage(conversation_id, opts[:terminal_usage], opts),
           do: :ok
    end
  end

  defp blank?(value) when value in [nil, ""], do: true
  defp blank?(_value), do: false

  defp settle_unfinished(conversation_id, status, error, opts) do
    store = Handbean.ConversationTranscriptStore.impl(opts)

    if function_exported?(store, :settle_run, 5) do
      store.settle_run(conversation_id, opts[:run_id], status, error, opts)
    else
      settle_unfinished_with_store(conversation_id, status, error, opts)
    end
  end

  defp settle_unfinished_with_store(conversation_id, status, error, opts) do
    with {:ok, entries} <- Handbean.ConversationTranscriptStore.list(conversation_id, opts) do
      entries
      |> Enum.filter(&(Map.get(&1, "run_id") == opts[:run_id]))
      |> Enum.reduce_while(:ok, fn entry, :ok ->
        patch =
          cond do
            tool_entry?(entry) and
                running_tool_status?(Handbean.TranscriptEntry.tool_status(entry)) ->
              %{
                "tool_status" => status,
                "tool_error" => error
              }

            entry["role"] == "assistant" and entry["status"] == "streaming" ->
              %{
                "status" => status,
                "phase" => settled_phase(entry, status),
                "error" => error
              }

            true ->
              nil
          end

        if patch do
          case Handbean.ConversationTranscriptStore.update(
                 conversation_id,
                 entry["id"],
                 patch,
                 opts
               ) do
            {:ok, _} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        else
          {:cont, :ok}
        end
      end)
    end
  end

  defp persist_run_error(conversation_id, error, opts) do
    # Stable across retries and boot recovery; do not append duplicate errors.
    entry =
      base_entry(conversation_id, opts)
      |> Map.merge(%{
        "id" => "msg-run-error-#{opts[:run_id] || "legacy"}",
        "content_type" => "system_msg",
        "message_type" => "error",
        "role" => "system",
        "direction" => "outbound",
        "content" => "Run error: #{error}",
        "status" => "final"
      })

    with {:ok, saved} <- append_or_update(conversation_id, entry, opts) do
      deliver(saved, opts)
      :ok
    end
  end

  defp append_to_buffer(_conversation_id, ""), do: :ok

  defp append_to_buffer(conversation_id, chunk) do
    current = Process.get(buffer_key(conversation_id), [])
    Process.put(buffer_key(conversation_id), [chunk | current])
    :ok
  end

  defp append_thinking(_conversation_id, ""), do: :ok

  defp append_thinking(conversation_id, text) do
    current = Process.get(thinking_key(conversation_id), [])
    Process.put(thinking_key(conversation_id), [text | current])
    :ok
  end

  defp thinking_buffer(conversation_id), do: Process.get(thinking_buffer_key(conversation_id), "")

  defp put_thinking_buffer(conversation_id, buffer) do
    Process.put(thinking_buffer_key(conversation_id), buffer)
    :ok
  end

  defp clear_thinking_buffer(conversation_id) do
    Process.delete(thinking_buffer_key(conversation_id))
    Process.delete(thinking_key(conversation_id))
    :ok
  end

  defp buffered_text(conversation_id) do
    case Process.get(buffer_key(conversation_id)) do
      nil -> ""
      list when is_list(list) -> list |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp clear_buffer(conversation_id) do
    Process.delete(buffer_key(conversation_id))
    Process.delete(last_flush_key(conversation_id))
    :ok
  end

  defp open_segment(conversation_id, payload, opts) do
    phase = stream_phase(payload)
    index = stream_index(payload)
    segment = {phase, index}
    segments = Process.get(assistant_segments_key(conversation_id), %{})
    current = Process.get(assistant_key(conversation_id))

    cond do
      is_nil(index) and is_nil(phase) ->
        :ok

      segments[segment] == current and not is_nil(current) ->
        :ok

      true ->
        flush!(conversation_id, opts)
        entry_id = unique_id("msg-assistant")
        Process.put(assistant_key(conversation_id), entry_id)
        Process.put(assistant_phase_key(conversation_id), phase)
        remember_segment_phase(conversation_id, entry_id, phase)

        Process.put(
          assistant_segments_key(conversation_id),
          Map.put(segments, segment, entry_id)
        )
    end
  end

  defp stream_phase(%{phase: phase}) when phase in ["commentary", "final_answer"], do: phase
  defp stream_phase(%{"phase" => phase}) when phase in ["commentary", "final_answer"], do: phase
  defp stream_phase(_), do: nil

  defp stream_index(%{output_index: index}) when is_integer(index), do: index
  defp stream_index(%{"output_index" => index}) when is_integer(index), do: index
  defp stream_index(_), do: nil

  defp flush!(conversation_id, opts) do
    case buffered_text(conversation_id) do
      "" ->
        :ok

      buffered ->
        entry_id = Process.get(assistant_key(conversation_id)) || unique_id("msg-assistant")
        Process.put(assistant_key(conversation_id), entry_id)
        phase = Process.get(assistant_phase_key(conversation_id))

        entry =
          base_entry(conversation_id, opts)
          |> Map.merge(%{
            "id" => entry_id,
            "content_type" => "assistant_msg",
            "message_type" => "assistant",
            "role" => "assistant",
            "direction" => "outbound",
            "content" => buffered,
            "status" => "streaming"
          })
          |> maybe_put_stream_phase(phase)
          |> maybe_put_provider_items(conversation_id)

        case persist_assistant_delta(conversation_id, entry_id, entry, opts) do
          {:ok, persisted} ->
            Process.delete(buffer_key(conversation_id))

            Process.put({__MODULE__, :text_patch, conversation_id}, %{
              transcript_id: persisted.id,
              text_offset: persisted.text_bytes - byte_size(buffered),
              text: buffered
            })

            if persisted.entry, do: deliver_delta(persisted.entry, buffered, opts)

          {:error, reason} ->
            # Do not advance the message boundary or report a successful run.
            # A retry intent now owns this delta; retaining it here would
            # append it twice when a same-process retry drains the durable queue.
            if match?({:queued, _}, reason), do: Process.delete(buffer_key(conversation_id))

            raise "Assistant transcript persistence failed for #{conversation_id}: #{inspect(reason)}"
        end

        Process.put(last_flush_key(conversation_id), System.monotonic_time(:millisecond))

        Logger.debug(
          "[TranscriptPersistence] flush conversation=#{conversation_id} bytes=#{byte_size(buffered)}"
        )

        :ok
    end
  end

  defp maybe_put_stream_phase(entry, phase) when phase in ["commentary", "final_answer"],
    do: Map.put(entry, "phase", phase)

  defp maybe_put_stream_phase(entry, _phase), do: entry

  defp maybe_put_provider_items(entry, conversation_id) do
    case take_provider_items(conversation_id) do
      [] -> entry
      items -> Map.put(entry, "content_blocks", items)
    end
  end

  defp append_patch(buffered), do: %{"$append" => buffered}

  defp assistant_segments_key(conversation_id),
    do: {:handbean_transcript_assistant_segments, conversation_id}

  defp assistant_phase_key(conversation_id),
    do: {:handbean_transcript_assistant_phase, conversation_id}

  defp segment_phases_key(conversation_id),
    do: {:handbean_transcript_segment_phases, conversation_id}

  defp remember_segment_phase(conversation_id, entry_id, phase)
       when phase in ["commentary", "final_answer"] do
    phases = Process.get(segment_phases_key(conversation_id), %{})
    Process.put(segment_phases_key(conversation_id), Map.put(phases, entry_id, phase))
  end

  defp remember_segment_phase(_conversation_id, _entry_id, _phase), do: :ok

  defp recorded_phase?(conversation_id, entry_id) do
    phases = Process.get(segment_phases_key(conversation_id), %{})
    phases[entry_id] in ["commentary", "final_answer"]
  end

  defp provider_items_key(conversation_id),
    do: {:handbean_transcript_provider_items, conversation_id}

  defp remember_provider_items(conversation_id, items) do
    kept = Enum.filter(items, &provider_item?/1)
    current = Process.get(provider_items_key(conversation_id), [])
    Process.put(provider_items_key(conversation_id), current ++ kept)
    :ok
  end

  defp take_provider_items(conversation_id) do
    items = Process.get(provider_items_key(conversation_id), [])
    Process.delete(provider_items_key(conversation_id))
    items
  end

  # Streaming text is flushed before the completed provider response is available.
  # Attach opaque provider items to the already-open assistant entry as soon as
  # they arrive; otherwise they would be discarded at run_end and same-model
  # continuation after transcript reconstruction would lose its reasoning state.
  defp persist_provider_items(conversation_id, opts) do
    items = Process.get(provider_items_key(conversation_id), [])
    entry_id = Process.get(assistant_key(conversation_id))

    if items == [] or not is_binary(entry_id) do
      :ok
    else
      patch = %{"content_blocks" => stringify_value(items)}

      case Handbean.ConversationTranscriptStore.update(conversation_id, entry_id, patch, opts) do
        {:ok, _entry} ->
          Process.delete(provider_items_key(conversation_id))
          :ok

        {:error, :not_found} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp provider_item?(%{type: "responses_reasoning", item: item}) when is_map(item), do: true

  defp provider_item?(%{"type" => "responses_reasoning", "item" => item}) when is_map(item),
    do: true

  defp provider_item?(_), do: false

  defp persist_assistant_delta(conversation_id, entry_id, entry, opts) do
    case append_assistant_content(conversation_id, entry_id, entry["content"], opts) do
      {:ok, persisted} ->
        {:ok, persisted}

      {:error, :not_found} ->
        case Handbean.ConversationTranscriptStore.append(conversation_id, entry, opts) do
          {:ok, saved} ->
            {:ok,
             %{
               id: saved["id"],
               text_bytes: byte_size(saved["content"] || ""),
               entry: saved
             }}

          {:error, _reason} = error ->
            error
        end

      {:error, reason} ->
        Logger.warning(fn ->
          "[TranscriptPersistence] assistant delta persist failed conversation=#{conversation_id} " <>
            "id=#{entry_id} reason=#{inspect(reason)}"
        end)

        {:error, reason}
    end
  end

  defp append_assistant_content(conversation_id, entry_id, content, opts) do
    if delivery_channel?(opts) do
      case Handbean.ConversationTranscriptStore.update(
             conversation_id,
             entry_id,
             %{"content" => append_patch(content), "status" => "streaming"},
             opts
           ) do
        {:ok, saved} ->
          {:ok,
           %{
             id: saved["id"],
             text_bytes: byte_size(saved["content"] || ""),
             entry: saved
           }}

        {:error, _reason} = error ->
          error
      end
    else
      case Handbean.ConversationTranscriptStore.append_content(
             conversation_id,
             entry_id,
             content,
             "streaming",
             opts
           ) do
        {:ok, summary} -> {:ok, Map.put(summary, :entry, nil)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp base_entry(conversation_id, opts) do
    %{
      "conversation_id" => conversation_id,
      "run_id" => Keyword.get(opts, :run_id),
      "turn_number" => Process.get(turn_key(conversation_id)),
      "channel" => channel(opts),
      "source" => opts |> Keyword.get(:source, :unknown) |> to_string(),
      "delivery_ref" => Keyword.get(opts, :delivery_ref),
      "metadata" => transcript_metadata(opts)
    }
  end

  defp put_inbound_delivery(entry, opts) do
    delivery = inbound_delivery(opts)

    entry
    |> Map.put("delivery", delivery)
    |> Map.put("interrupts_work", delivery == "steer")
  end

  defp inbound_delivery(opts) do
    case Keyword.get(opts, :deliver_as) do
      :steer -> "steer"
      :follow_up -> "follow_up"
      :new_run -> "new_run"
      :next_turn -> "next_turn"
      "steer" -> "steer"
      "follow_up" -> "follow_up"
      "new_run" -> "new_run"
      "next_turn" -> "next_turn"
      _ -> "new_run"
    end
  end

  defp settled_phase(%{"phase" => phase}, _status) when phase in ["commentary", "final_answer"],
    do: phase

  defp settled_phase(_entry, _status), do: "final"

  defp completion_patch(id, current, "commentary" = phase) when id == current do
    Map.put(@assistant_completed_patch, "phase", phase)
  end

  defp completion_patch(id, current, phase) when id == current and is_binary(phase) do
    if phase == "final_answer",
      do: @assistant_completed_patch,
      else: Map.put(@assistant_completed_patch, "phase", phase)
  end

  defp completion_patch(_id, _current, _phase), do: @assistant_completed_patch

  defp finalize_assistant(conversation_id, phase, opts) do
    segments = Process.get(assistant_segments_key(conversation_id), %{})
    current = Process.get(assistant_key(conversation_id))
    ids = segments |> Map.values() |> Enum.reject(&is_nil/1)
    ids = if current && current not in ids, do: [current | ids], else: ids

    if ids == [] do
      :ok
    else
      Enum.reduce_while(ids, :ok, fn id, :ok ->
        patch =
          if recorded_phase?(conversation_id, id) do
            @assistant_completed_patch
          else
            completion_patch(id, current, phase)
          end

        case Handbean.ConversationTranscriptStore.update(conversation_id, id, patch, opts) do
          {:ok, _} -> {:cont, :ok}
          {:error, :not_found} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp tool_status(payload, error) do
    case payload_value(payload, :status) do
      status when status in [:cancelled, "cancelled"] -> "cancelled"
      status when status in [:failed, "failed", :interrupted, "interrupted"] -> "error"
      _status when not is_nil(error) -> "error"
      _status -> "done"
    end
  end

  defp transcript_metadata(opts) do
    opts
    |> Keyword.take([:workspace_id, :model, :source, :chat_scope])
    |> Map.new(fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp channel(opts),
    do: opts |> Keyword.get(:channel, Keyword.get(opts, :source, :unknown)) |> to_string()

  defp deliver(entry, opts) do
    if delivery_channel?(opts) do
      Handbean.Delivery.deliver(entry, opts)
    else
      :ok
    end
  end

  defp deliver_delta(entry, delta, opts) do
    if delivery_channel?(opts) do
      entry
      |> Map.put("delivery_delta", delta)
      |> Handbean.Delivery.deliver(opts)
    else
      :ok
    end
  end

  defp delivery_channel?(opts) do
    Keyword.has_key?(opts, :delivery) or Keyword.get(opts, :source) in [:sns, :webhook, :cli]
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
        %{
          "text" => message_text(content),
          "attachments" => attachments
        }

      match?(%Handbean.Agent.Message{content: list} when is_list(list), content) ->
        content.content
        |> Enum.map(&sanitize_block/1)
        |> stringify_value()

      true ->
        content
    end
  end

  defp sanitize_block(block) when is_map(block) do
    block
    |> stringify_value()
    |> Map.drop(["data", "uri"])
  end

  defp sanitize_block(block), do: block

  defp persisted_output_truncated?(output) when is_binary(output), do: byte_size(output) > 16_000
  defp persisted_output_truncated?(_output), do: false

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp usable_tool_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    if trimmed == "" or trimmed == "unknown", do: nil, else: name
  end

  defp usable_tool_name(_), do: nil

  defp bound_persisted_output(output) when is_binary(output) and byte_size(output) > 16_000 do
    String.slice(output, 0, 15_900) <> "\n[truncated]"
  end

  defp bound_persisted_output(output), do: output

  defp payload_value(payload, key, default \\ nil)

  defp payload_value(payload, key, default) when is_map(payload) and is_atom(key) do
    Map.get(payload, key, Map.get(payload, Atom.to_string(key), default))
  end

  defp payload_value(_payload, _key, default), do: default

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp map_value(_map, _key), do: nil

  defp stringify_value(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value) when is_atom(value), do: to_string(value)
  defp stringify_value(value), do: value

  defp tool_entry_id(tool_use_id, tool_name) do
    if is_binary(tool_use_id) and tool_use_id != "" do
      "tool-#{tool_use_id}"
    else
      "tool-event-#{tool_name}"
    end
  end

  defp inbound_origin(opts) do
    opts[:origin] ||
      if opts[:source] in [:webhook, :sns, :schedule, :scheduler],
        do: %{"kind" => "automatic", "source" => to_string(opts[:source])}
  end

  defp turn_key(conversation_id),
    do: {__MODULE__, :turn_number, conversation_id}

  defp record_lifecycle(_kind, _conversation_id, %{run_id: run_id})
       when not is_binary(run_id) or run_id == "",
       do: :ok

  defp record_lifecycle(:run_start, conversation_id, attrs),
    do: Handbean.ConversationStore.record_run_start(conversation_id, attrs)

  defp record_lifecycle(:run_end, conversation_id, attrs),
    do: Handbean.ConversationStore.record_run_end(conversation_id, attrs)

  defp record_lifecycle(:turn_start, conversation_id, attrs),
    do: Handbean.ConversationStore.record_turn_start(conversation_id, attrs)

  defp record_lifecycle(:turn_end, conversation_id, attrs),
    do: Handbean.ConversationStore.record_turn_end(conversation_id, attrs)

  defp clear_process_state(conversation_id) do
    Process.delete(assistant_key(conversation_id))
    Process.delete(assistant_segments_key(conversation_id))
    Process.delete(assistant_phase_key(conversation_id))
    Process.delete(segment_phases_key(conversation_id))
    Process.delete(provider_items_key(conversation_id))
    Process.delete(turn_key(conversation_id))
    Process.delete(run_opts_key(conversation_id))
    Process.delete(run_payload_key(conversation_id))
    Process.delete({__MODULE__, :text_patch, conversation_id})
    clear_buffer(conversation_id)
    clear_thinking_buffer(conversation_id)
    :ok
  end

  defp consume_inbound(conversation_id, opts) do
    if opts[:origin] && opts[:transcript_id] do
      consume_messages(conversation_id, [opts[:transcript_id]], opts)
    else
      :ok
    end
  end

  defp lifecycle_attrs(payload, opts) do
    %{
      run_id: payload_value(payload, :run_id) || Keyword.get(opts, :run_id),
      turn_number: payload_value(payload, :turn),
      status: payload_value(payload, :status),
      stop_reason:
        payload_value(payload, :stop_reason) || payload_value(payload, :provider_finish_reason),
      loop_owner: payload_value(payload, :loop_owner) || :handbean,
      backend: payload_value(payload, :backend),
      model: payload_value(payload, :model) || Keyword.get(opts, :model),
      error: payload_value(payload, :error),
      turns: payload_value(payload, :turns),
      duration_ms: payload_value(payload, :duration_ms)
    }
  end

  defp now_iso8601,
    do: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

  defp unique_id(prefix) do
    "#{prefix}-#{Ecto.UUID.generate()}"
  end

  defp replace_message_id(%Handbean.Agent.Message{} = message, id), do: %{message | id: id}
  defp replace_message_id(content, _id), do: content
end
