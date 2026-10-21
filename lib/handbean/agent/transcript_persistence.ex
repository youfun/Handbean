defmodule Handbean.Agent.TranscriptPersistence do
  @moduledoc """
  Persists runtime events into the cross-channel conversation transcript.

  This module is runtime-side, not UI-side. LiveView, SNS, webhook, CLI, and
  future channels should all be able to recover conversation history from the
  transcript without needing a LiveView process to have been alive.
  """

  require Logger

  alias Handbean.Agent.TranscriptPersistence.{Entry, StateKey}

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
      Entry.inbound(
        conversation_id,
        content,
        opts,
        Process.get(StateKey.turn(conversation_id)),
        transcript_id
      )

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
          Entry.replace_message_id(content, id),
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

    if Code.ensure_loaded?(store) and function_exported?(store, :append_with_receipt, 5) do
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
    with :ok <-
           record_lifecycle(:run_start, conversation_id, Entry.lifecycle_attrs(payload, opts)),
         :ok <- consume_inbound(conversation_id, opts) do
      clear_process_state(conversation_id)
      Process.put(StateKey.run_opts(conversation_id), opts)
      Process.put(StateKey.run_payload(conversation_id), payload)

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
    turn_number = Entry.payload_value(payload, :turn)

    attrs =
      payload
      |> Entry.lifecycle_attrs(opts)
      |> Map.put(:turn_number, turn_number)

    with :ok <- record_lifecycle(:turn_start, conversation_id, attrs) do
      Process.put(StateKey.turn(conversation_id), turn_number)
      :ok
    end
  end

  def handle_event(conversation_id, {:turn_end, payload}, opts)
      when is_binary(conversation_id) do
    flush!(conversation_id, opts)

    turn_number =
      Entry.payload_value(payload, :turn) || Process.get(StateKey.turn(conversation_id))

    attrs =
      payload
      |> Entry.lifecycle_attrs(opts)
      |> Map.put(:turn_number, turn_number)

    with :ok <- record_lifecycle(:turn_end, conversation_id, attrs) do
      Process.delete(StateKey.turn(conversation_id))
      :ok
    end
  end

  def handle_event(conversation_id, {:tool_start, payload}, opts)
      when is_binary(conversation_id) do
    flush!(conversation_id, opts)
    :ok = finalize_assistant(conversation_id, "commentary", opts)
    Process.put(StateKey.assistant(conversation_id), nil)

    redacted_input =
      payload
      |> Entry.payload_value(:input, %{})
      |> Handbean.Log.Redactor.redact()

    started_at = Entry.payload_value(payload, :started_at) || now_iso8601()

    entry =
      conversation_id
      |> Entry.tool_start(
        payload,
        opts,
        Process.get(StateKey.turn(conversation_id)),
        redacted_input,
        started_at
      )
      |> maybe_put_provider_items(conversation_id)

    with {:ok, _saved} <- append_or_update(conversation_id, entry, opts), do: :ok
  end

  def handle_event(conversation_id, {:tool_end, payload}, opts) when is_binary(conversation_id) do
    flush!(conversation_id, opts)

    {entry, published_media, tool_use_id, status} =
      Entry.tool_end(conversation_id, payload, opts, Process.get(StateKey.turn(conversation_id)))

    media_entry =
      Entry.media(
        conversation_id,
        tool_use_id,
        status,
        published_media,
        payload,
        opts,
        Process.get(StateKey.turn(conversation_id))
      )

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
      Process.put(StateKey.assistant(conversation_id), nil)
    end

    consume_messages(conversation_id, ids, opts)
  end

  def handle_event(conversation_id, {:stall_check_requested, payload}, opts)
      when is_binary(conversation_id) do
    evidence = Entry.payload_value(payload, :evidence) || "检测到没有进展"
    write_notice(conversation_id, "msg-stall-#{opts[:run_id] || "legacy"}", evidence, opts)
  end

  def handle_event(conversation_id, {:run_end, payload}, opts) when is_binary(conversation_id) do
    flush!(conversation_id, opts)

    with :ok <- record_stop_notice(conversation_id, payload, opts) do
      run_error = Entry.payload_value(payload, :error)
      terminal_opts = Keyword.put(opts, :terminal_usage, Entry.terminal_usage(payload))

      result =
        cond do
          Entry.cancelled_run?(payload) ->
            settle_unfinished(conversation_id, "cancelled", nil, terminal_opts)

          is_nil(run_error) and
              Entry.payload_value(payload, :status) in [:error, "error", :timeout, "timeout"] ->
            settle_unfinished(conversation_id, "error", nil, terminal_opts)

          not is_nil(run_error) ->
            with :ok <- persist_run_error(conversation_id, run_error, opts) do
              settle_unfinished(conversation_id, "error", run_error, terminal_opts)
            end

          true ->
            finalize_successful_run(conversation_id, terminal_opts)
        end

      with :ok <- result,
           :ok <-
             record_lifecycle(:run_end, conversation_id, Entry.lifecycle_attrs(payload, opts)) do
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
      Entry.blank?(run_id) ->
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

  defp patch_running_tools_cancelled(conversation_id, entries, run_id, opts) do
    errors =
      entries
      |> Enum.filter(&Entry.running_tool_for_run?(&1, conversation_id, run_id))
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

  # Runner persists this before Session broadcasts, so every channel records
  # the same terminal total whether or not a LiveView is connected.
  # `:interrupted` is approval wait, not a finished run; the resumed run_end
  # carries the cumulative usage for the same run_id.
  defp record_stop_notice(conversation_id, payload, opts) do
    text = Entry.stop_notice_text(payload)

    if is_binary(text) and text != "" do
      write_notice(conversation_id, "msg-run-stop-#{opts[:run_id] || "legacy"}", text, opts)
    else
      :ok
    end
  end

  defp write_notice(conversation_id, id, text, opts) do
    entry =
      Entry.notice(
        conversation_id,
        id,
        text,
        opts,
        Process.get(StateKey.turn(conversation_id))
      )

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
        patch = Entry.settlement_patch(entry, status, error)

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
      Entry.run_error(
        conversation_id,
        error,
        opts,
        Process.get(StateKey.turn(conversation_id))
      )

    with {:ok, saved} <- append_or_update(conversation_id, entry, opts) do
      deliver(saved, opts)
      :ok
    end
  end

  defp append_to_buffer(_conversation_id, ""), do: :ok

  defp append_to_buffer(conversation_id, chunk) do
    current = Process.get(StateKey.buffer(conversation_id), [])
    Process.put(StateKey.buffer(conversation_id), [chunk | current])
    :ok
  end

  defp append_thinking(_conversation_id, ""), do: :ok

  defp append_thinking(conversation_id, text) do
    current = Process.get(StateKey.thinking(conversation_id), [])
    Process.put(StateKey.thinking(conversation_id), [text | current])
    :ok
  end

  defp thinking_buffer(conversation_id),
    do: Process.get(StateKey.thinking_buffer(conversation_id), "")

  defp put_thinking_buffer(conversation_id, buffer) do
    Process.put(StateKey.thinking_buffer(conversation_id), buffer)
    :ok
  end

  defp clear_thinking_buffer(conversation_id) do
    Process.delete(StateKey.thinking_buffer(conversation_id))
    Process.delete(StateKey.thinking(conversation_id))
    :ok
  end

  defp buffered_text(conversation_id) do
    case Process.get(StateKey.buffer(conversation_id)) do
      nil -> ""
      list when is_list(list) -> list |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp clear_buffer(conversation_id) do
    Process.delete(StateKey.buffer(conversation_id))
    Process.delete(StateKey.last_flush(conversation_id))
    :ok
  end

  defp open_segment(conversation_id, payload, opts) do
    {phase, index} = Entry.stream_segment(payload)
    segment = {phase, index}
    segments = Process.get(StateKey.assistant_segments(conversation_id), %{})
    current = Process.get(StateKey.assistant(conversation_id))

    cond do
      is_nil(index) and is_nil(phase) ->
        :ok

      segments[segment] == current and not is_nil(current) ->
        :ok

      true ->
        flush!(conversation_id, opts)
        entry_id = unique_id("msg-assistant")
        Process.put(StateKey.assistant(conversation_id), entry_id)
        Process.put(StateKey.assistant_phase(conversation_id), phase)
        remember_segment_phase(conversation_id, entry_id, phase)

        Process.put(
          StateKey.assistant_segments(conversation_id),
          Map.put(segments, segment, entry_id)
        )
    end
  end

  defp flush!(conversation_id, opts) do
    case buffered_text(conversation_id) do
      "" ->
        :ok

      buffered ->
        entry_id =
          Process.get(StateKey.assistant(conversation_id)) || unique_id("msg-assistant")

        Process.put(StateKey.assistant(conversation_id), entry_id)
        phase = Process.get(StateKey.assistant_phase(conversation_id))

        entry =
          Entry.assistant(
            conversation_id,
            entry_id,
            buffered,
            phase,
            opts,
            Process.get(StateKey.turn(conversation_id))
          )
          |> maybe_put_provider_items(conversation_id)

        case persist_assistant_delta(conversation_id, entry_id, entry, opts) do
          {:ok, persisted} ->
            Process.delete(StateKey.buffer(conversation_id))

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
            if match?({:queued, _}, reason), do: Process.delete(StateKey.buffer(conversation_id))

            raise "Assistant transcript persistence failed for #{conversation_id}: #{inspect(reason)}"
        end

        Process.put(StateKey.last_flush(conversation_id), System.monotonic_time(:millisecond))

        Logger.debug(
          "[TranscriptPersistence] flush conversation=#{conversation_id} bytes=#{byte_size(buffered)}"
        )

        :ok
    end
  end

  defp maybe_put_provider_items(entry, conversation_id) do
    case take_provider_items(conversation_id) do
      [] -> entry
      items -> Map.put(entry, "content_blocks", items)
    end
  end

  defp remember_segment_phase(conversation_id, entry_id, phase)
       when phase in ["commentary", "final_answer"] do
    phases = Process.get(StateKey.segment_phases(conversation_id), %{})
    Process.put(StateKey.segment_phases(conversation_id), Map.put(phases, entry_id, phase))
  end

  defp remember_segment_phase(_conversation_id, _entry_id, _phase), do: :ok

  defp recorded_phase?(conversation_id, entry_id) do
    phases = Process.get(StateKey.segment_phases(conversation_id), %{})
    phases[entry_id] in ["commentary", "final_answer"]
  end

  defp remember_provider_items(conversation_id, items) do
    kept = Enum.filter(items, &Entry.provider_item?/1)
    current = Process.get(StateKey.provider_items(conversation_id), [])
    Process.put(StateKey.provider_items(conversation_id), current ++ kept)
    :ok
  end

  defp take_provider_items(conversation_id) do
    items = Process.get(StateKey.provider_items(conversation_id), [])
    Process.delete(StateKey.provider_items(conversation_id))
    items
  end

  # Streaming text is flushed before the completed provider response is available.
  # Attach opaque provider items to the already-open assistant entry as soon as
  # they arrive; otherwise they would be discarded at run_end and same-model
  # continuation after transcript reconstruction would lose its reasoning state.
  defp persist_provider_items(conversation_id, opts) do
    items = Process.get(StateKey.provider_items(conversation_id), [])
    entry_id = Process.get(StateKey.assistant(conversation_id))

    if items == [] or not is_binary(entry_id) do
      :ok
    else
      patch = %{"content_blocks" => Entry.stringify_value(items)}

      case Handbean.ConversationTranscriptStore.update(conversation_id, entry_id, patch, opts) do
        {:ok, _entry} ->
          Process.delete(StateKey.provider_items(conversation_id))
          :ok

        {:error, :not_found} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp persist_assistant_delta(conversation_id, entry_id, entry, opts) do
    case append_assistant_content(conversation_id, entry_id, entry["content"], opts) do
      {:ok, persisted} ->
        {:ok, persisted}

      {:error, :not_found} ->
        case Handbean.ConversationTranscriptStore.append(conversation_id, entry, opts) do
          {:ok, saved} ->
            {:ok, Entry.delta_summary(saved, saved)}

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
    if Entry.delivery_channel?(opts) do
      case Handbean.ConversationTranscriptStore.update(
             conversation_id,
             entry_id,
             %{"content" => Entry.append_patch(content), "status" => "streaming"},
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

  defp finalize_assistant(conversation_id, phase, opts) do
    segments = Process.get(StateKey.assistant_segments(conversation_id), %{})
    current = Process.get(StateKey.assistant(conversation_id))
    ids = segments |> Map.values() |> Enum.reject(&is_nil/1)
    ids = if current && current not in ids, do: [current | ids], else: ids

    if ids == [] do
      :ok
    else
      Enum.reduce_while(ids, :ok, fn id, :ok ->
        patch =
          Entry.completion_patch(
            id,
            current,
            phase,
            recorded_phase?(conversation_id, id)
          )

        case Handbean.ConversationTranscriptStore.update(conversation_id, id, patch, opts) do
          {:ok, _} -> {:cont, :ok}
          {:error, :not_found} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp deliver(entry, opts) do
    if Entry.delivery_channel?(opts) do
      Handbean.Delivery.deliver(entry, opts)
    else
      :ok
    end
  end

  defp deliver_delta(entry, delta, opts) do
    if Entry.delivery_channel?(opts) do
      entry
      |> Map.put("delivery_delta", delta)
      |> Handbean.Delivery.deliver(opts)
    else
      :ok
    end
  end

  defp record_lifecycle(_kind, _conversation_id, %{run_id: run_id})
       when not is_binary(run_id) or run_id == "",
       do: :ok

  defp record_lifecycle(:run_start, conversation_id, attrs),
    do: Handbean.ConversationStore.record_run_start(conversation_id, attrs)

  defp record_lifecycle(:run_end, conversation_id, attrs) do
    with :ok <- Handbean.ConversationStore.record_run_end(conversation_id, attrs) do
      checkpoint_wal()
    end
  end

  defp record_lifecycle(:turn_start, conversation_id, attrs),
    do: Handbean.ConversationStore.record_turn_start(conversation_id, attrs)

  defp record_lifecycle(:turn_end, conversation_id, attrs) do
    with :ok <- Handbean.ConversationStore.record_turn_end(conversation_id, attrs) do
      checkpoint_wal()
    end
  end

  # With synchronous :normal, committed frames stay in the WAL — durable
  # across process crashes — until a checkpoint copies them into the database
  # file and syncs it. Checkpointing at turn/run boundaries bounds what a
  # power loss can lose to the streaming deltas since the last boundary.
  defp checkpoint_wal do
    Handbean.Repo.checkpoint_wal()
    :ok
  end

  defp clear_process_state(conversation_id) do
    Process.delete(StateKey.assistant(conversation_id))
    Process.delete(StateKey.assistant_segments(conversation_id))
    Process.delete(StateKey.assistant_phase(conversation_id))
    Process.delete(StateKey.segment_phases(conversation_id))
    Process.delete(StateKey.provider_items(conversation_id))
    Process.delete(StateKey.turn(conversation_id))
    Process.delete(StateKey.run_opts(conversation_id))
    Process.delete(StateKey.run_payload(conversation_id))
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

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
  end

  defp unique_id(prefix), do: "#{prefix}-#{Ecto.UUID.generate()}"
end
