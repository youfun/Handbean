defmodule Handbean.Agent.Runner.Events do
  @moduledoc """
  Connects run callbacks to transcript persistence and session events.

  Installed callbacks run hooks in the provider task, then synchronously route
  writes to the Runner. `persist/3`, `persist_terminal/3`, and `compact/3` execute
  directly in the calling Runner process, preserving its transcript buffers and
  the order of persistence, user callbacks, projection, and broadcast.
  """

  alias Handbean.Agent.{CompactionCheckpoint, TranscriptPersistence}
  alias Handbean.PubSub.Session

  require Logger

  @progress_events [
    :message_delta,
    :thinking_delta,
    :provider_items,
    :provider_retry,
    :tool_start,
    :tool_end,
    :turn_start,
    :turn_end,
    :candidate_message_injected,
    :tool_approval_requested,
    :stall_check_requested
  ]

  @spec install(keyword(), String.t(), pid()) :: keyword()
  def install(opts, conversation_id, runner) do
    opts
    |> put_compaction_callback(runner)
    |> put_persistence_callback(conversation_id)
  end

  @spec progress_event?(atom()) :: boolean()
  def progress_event?(kind), do: kind in @progress_events

  @spec persist(String.t(), {atom(), term()}, keyword()) ::
          {:ok, {atom(), term()}} | {:error, term()}
  def persist(conversation_id, event, opts) do
    opts = Keyword.put(opts, :runner_pid, self())

    result =
      try do
        persist_and_callback(conversation_id, event, opts, opts[:on_event])
      rescue
        error -> {:error, {:exception, Exception.message(error)}}
      catch
        :exit, reason -> {:error, {:exit, reason}}
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:error, _reason} = error ->
        # A failed write may leave a staged entry. Terminal persistence must not
        # replay that hidden buffer and prevent the error record from being saved.
        TranscriptPersistence.discard_pending(conversation_id)
        error

      success ->
        success
    end
  end

  @spec persist_terminal(String.t(), map(), keyword()) :: :ok
  def persist_terminal(conversation_id, payload, opts) do
    case TranscriptPersistence.handle_event(conversation_id, {:run_end, payload}, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[Runner] terminal transcript persist failed conversation=#{conversation_id} " <>
            "reason=#{inspect(reason)}"
        )
    end
  rescue
    error ->
      # An unavailable disk must not restart Runner and execute the run again.
      Logger.error("[Runner] terminal transcript persist failed: #{Exception.message(error)}")
  catch
    :exit, reason ->
      Logger.error("[Runner] terminal transcript owner unavailable: #{inspect(reason)}")
  end

  @spec compact(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def compact(conversation_id, event, opts) do
    reply = CompactionCheckpoint.persist(conversation_id, event, opts)

    case reply do
      {:ok, checkpoint} ->
        Handbean.Memory.Reflector.maybe_trigger(
          conversation_id,
          checkpoint,
          reflection_opts(opts)
        )

      _other ->
        :ok
    end

    reply
  end

  defp put_persistence_callback(opts, conversation_id) do
    user_on_event = Keyword.get(opts, :on_event)
    progress = fn kind -> notify_progress_owner({kind, %{}}, opts) end
    opts = Keyword.put(opts, :on_progress, progress)

    Keyword.put(opts, :on_event, fn {kind, payload} = event ->
      hook_result =
        if Keyword.get(opts, :delegated?, false),
          do: :ok,
          else: Handbean.Extension.HookPipeline.run(conversation_id, event)

      case hook_result do
        {:block, reason} ->
          if Handbean.Extension.Event.blockable?(kind) do
            Logger.debug(
              "[Runner] event blocked by extension hook kind=#{kind} conversation=#{conversation_id} reason=#{reason}"
            )
          else
            Logger.warning(
              "[Runner] extension hook attempted to block read-only event kind=#{kind} conversation=#{conversation_id} reason=#{reason} — ignoring block"
            )

            route_event!(conversation_id, event, opts, user_on_event)
          end

        {:transform, transformed_payload} ->
          if Handbean.Extension.Event.blockable?(kind) do
            transformed_event = {kind, Map.merge(payload, transformed_payload)}
            route_event!(conversation_id, transformed_event, opts, user_on_event)
          else
            Logger.debug(
              "[Runner] extension hook attempted to transform read-only event kind=#{kind} conversation=#{conversation_id} — ignoring transform"
            )

            route_event!(conversation_id, event, opts, user_on_event)
          end

        :ok ->
          route_event!(conversation_id, event, opts, user_on_event)
      end
    end)
  end

  defp put_compaction_callback(opts, runner) when is_pid(runner) do
    Keyword.put(opts, :on_compaction_complete, fn event, state ->
      event =
        Map.merge(event, %{
          context_edited: state.context_edited,
          context_generation: state.context_generation,
          context_window: state.config.max_tokens,
          model: state.config.model,
          run_id: state.config.run_id
        })

      GenServer.call(runner, {:persist_compaction, event}, 30_000)
    end)
  end

  defp reflection_opts(opts) do
    Keyword.take(opts, [
      :builtin_memory_enabled,
      :workspace_id,
      :workspace_path,
      :working_directory,
      :model,
      :reasoning_level,
      :provider_config,
      :om,
      :transcript_store
    ])
  end

  defp persist_and_callback(conversation_id, event, opts, user_on_event) do
    track_search_access(event, opts)
    log_runner_event(conversation_id, event)

    with :ok <- TranscriptPersistence.handle_event(conversation_id, event, opts) do
      if is_function(user_on_event, 1), do: user_on_event.(event)

      projected = TranscriptPersistence.project_event(conversation_id, event)
      broadcast_session_event(conversation_id, projected, opts)
      {:ok, projected}
    end
  end

  defp route_event!(conversation_id, event, opts, user_on_event) do
    notify_progress_owner(event, opts)

    case Keyword.get(opts, :runner_pid) do
      pid when is_pid(pid) ->
        case GenServer.call(pid, {:persist_event, event}, :infinity) do
          :ok -> :ok
          {:error, reason} -> persistence_error!(conversation_id, reason)
        end

      _missing ->
        case persist_and_callback(conversation_id, event, opts, user_on_event) do
          {:ok, _projected} -> :ok
          {:error, reason} -> persistence_error!(conversation_id, reason)
        end
    end
  end

  defp persistence_error!(conversation_id, reason) do
    raise "Transcript persistence failed: #{inspect(reason)} conversation=#{conversation_id}"
  end

  defp track_search_access({:tool_end, payload}, opts) do
    tool = Handbean.Utils.SafeMap.get_any(payload, :tool, "tool")
    path = Handbean.Utils.SafeMap.get_any(payload, :file_path, "file_path")
    workspace = opts[:working_directory]
    successful? = is_nil(payload[:error]) and is_nil(payload["error"])
    normalized_tool = if is_binary(tool), do: String.downcase(tool), else: ""

    if successful? and normalized_tool in ["read", "edit", "write"] and
         is_binary(workspace) and is_binary(path) do
      Handbean.Search.touch(workspace, path)

      if normalized_tool in ["edit", "write"] do
        Handbean.Search.notify_path(workspace, path)
      end
    end

    :ok
  end

  defp track_search_access(_event, _opts), do: :ok

  defp notify_progress_owner({kind, _payload}, opts) when kind in @progress_events do
    case Keyword.get(opts, :runner_pid) do
      pid when is_pid(pid) -> send(pid, {:run_progress, Keyword.get(opts, :run_id), kind})
      _ -> :ok
    end
  end

  defp notify_progress_owner(_event, _opts), do: :ok

  defp broadcast_session_event(conversation_id, {kind, payload}, opts) do
    payload = stamp_run_id(payload, opts)
    Session.broadcast_event(conversation_id, kind, payload)
  end

  defp stamp_run_id(payload, opts) when is_map(payload) do
    Map.put_new(payload, :run_id, Keyword.get(opts, :run_id))
  end

  defp stamp_run_id(payload, _opts), do: payload

  defp log_runner_event(_conversation_id, {:message_delta, %{chunk: chunk}})
       when is_binary(chunk),
       do: :ok

  defp log_runner_event(_conversation_id, {:thinking_delta, _payload}), do: :ok

  defp log_runner_event(conversation_id, {kind, _payload}) do
    if kind not in [:message_delta, :user_on_chunk] do
      Logger.debug("[Runner] persistence callback #{kind} conversation=#{conversation_id}")
    end
  end
end
