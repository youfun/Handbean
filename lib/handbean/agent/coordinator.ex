defmodule Handbean.Agent.Coordinator do
  @moduledoc """
  Facade for agent run lifecycle operations.

  Entry points such as LiveView, CLI, webhook, MCP, or extension code should
  express intent here instead of directly starting `Handbean.Agent.run/2`.
  """

  alias Handbean.Agent.Coordinator.RunOptions
  alias Handbean.PubSub.Session

  @type source :: :live_view | :sns | :webhook | :cli | :mcp | atom()
  @type action :: :started | :enqueued
  @type ack :: %{action: action(), run_id: String.t() | nil, run_pid: pid() | nil}

  @spec add_message(String.t(), String.t() | Handbean.Agent.Message.t(), keyword()) ::
          {:ok, ack()} | {:error, term()}
  def add_message(conversation_id, content, opts \\ [])
      when is_binary(conversation_id) and
             (is_binary(content) or is_struct(content, Handbean.Agent.Message)) and
             is_list(opts) do
    Handbean.ConversationStore.with_model_selection_lock(conversation_id, fn ->
      do_add_message(conversation_id, content, opts)
    end)
  end

  defp do_add_message(conversation_id, content, opts) do
    {content, opts} = stamp_message_ids(content, opts)

    with :ok <- Handbean.Storage.Health.check_write(),
         :ok <- RunOptions.validate(opts),
         :ok <- validate_conversation_access(conversation_id, opts),
         :ok <- reserve_operation(conversation_id, content, opts) do
      opts = ensure_run_id(opts)

      result =
        with {:ok, _pid} <- Session.start_or_get(session_id: conversation_id, model: opts[:model]) do
          admit_message(conversation_id, content, opts, 2)
        end

      maybe_release_unaccepted(result, conversation_id, content, opts)
    end
  end

  defp admit_message(_id, _content, _opts, 0), do: {:error, :run_in_progress}

  defp admit_message(id, content, opts, attempts) do
    if Keyword.get(opts, :require_idle?, false) do
      admit_idle_message(id, content, opts)
    else
      do_admit_message(id, content, opts, attempts)
    end
  end

  defp admit_idle_message(id, content, opts) do
    case Handbean.Agent.Runner.status(id) do
      {:ok, %{running?: true}} ->
        release_idle_busy(id, content, opts)

      {:ok, %{running?: false} = inactive} ->
        with :ok <- await_run_exit(inactive[:run_supervisor]),
             result <- do_start_run(id, content, opts) do
          case result do
            {:error, :run_in_progress} -> release_idle_busy(id, content, opts)
            other -> other
          end
        end

      {:error, :not_found} ->
        case do_start_run(id, content, opts) do
          {:error, :run_in_progress} -> release_idle_busy(id, content, opts)
          result -> result
        end

      error ->
        error
    end
  end

  defp do_admit_message(id, content, opts, attempts) do
    case status(id) do
      {:ok, %{running?: true} = active} ->
        cond do
          present_task_instructions?(opts) ->
            {:error, :run_in_progress}

          true ->
            admit_running(id, content, opts, attempts, active)
        end

      {:ok, %{running?: false} = inactive} ->
        if Keyword.get(opts, :require_running?, false) do
          {:error, :no_active_run}
        else
          with :ok <- await_run_exit(inactive[:run_supervisor]) do
            case do_start_run(id, content, opts) do
              {:error, :run_in_progress} ->
                admit_message(id, content, opts, attempts - 1)

              result ->
                result
            end
          end
        end

      {:error, :not_found} ->
        if Keyword.get(opts, :require_running?, false) do
          {:error, :no_active_run}
        else
          case do_start_run(id, content, opts) do
            {:error, :run_in_progress} ->
              admit_message(id, content, opts, attempts - 1)

            result ->
              result
          end
        end

      error ->
        error
    end
  end

  defp admit_running(id, content, opts, attempts, active) do
    candidate_opts =
      opts
      |> Keyword.put_new(:deliver_as, :steer)
      |> Keyword.put(:expected_run_id, active.run_id)
      |> Keyword.put(:persist_candidate?, Keyword.get(opts, :persist_inbound?, true))

    case enqueue_candidate(id, content, candidate_opts) do
      {:ok, ack} ->
        maybe_resume_stall(id)
        {:ok, ack}

      {:error, reason} when reason in [:sealed, :no_active_run, :stale_run] ->
        with :ok <- await_run_exit(active[:run_supervisor]) do
          admit_message(id, content, opts, attempts - 1)
        end

      error ->
        error
    end
  end

  # Wait for the exact old tree, not a timer or a lookup that could stop a new run.
  defp await_run_exit(pid) when is_pid(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      5_000 ->
        Process.demonitor(ref, [:flush])
        {:error, :run_in_progress}
    end
  end

  defp await_run_exit(_pid), do: :ok

  defp replay_ack(receipt) when is_map(receipt) do
    %{
      action: replay_action(Handbean.Utils.SafeMap.get_any(receipt, "action", :action)),
      run_id: Handbean.Utils.SafeMap.get_any(receipt, "run_id", :run_id),
      run_pid: nil,
      replayed: true
    }
  end

  defp replay_action("started"), do: :started
  defp replay_action(:started), do: :started
  defp replay_action("enqueued"), do: :enqueued
  defp replay_action(:enqueued), do: :enqueued
  defp replay_action(_other), do: :started

  defp release_idle_busy(conversation_id, content, opts) do
    release_unaccepted(conversation_id, content, opts, :busy)
  end

  defp maybe_release_unaccepted({:error, reason}, conversation_id, content, opts)
       when reason in [:queue_full, :run_in_progress, :no_active_run, :stale_run, :sealed] do
    release_unaccepted(conversation_id, content, opts, reason)
  end

  defp maybe_release_unaccepted(result, _conversation_id, _content, _opts), do: result

  defp release_unaccepted(conversation_id, content, opts, reason) do
    request_id = Keyword.get(opts, :request_id)

    case Handbean.Agent.OperationReceipt.release_reserved(
           {:message, conversation_id},
           request_id,
           operation_fingerprint(conversation_id, content, opts)
         ) do
      :ok -> {:error, reason}
      {:error, _reason} -> {:error, :delivery_unknown}
    end
  end

  defp operation_fingerprint(conversation_id, content, opts) do
    Handbean.Agent.OperationReceipt.fingerprint({conversation_id, content, opts[:deliver_as]})
  end

  defp reserve_operation(conversation_id, content, opts) do
    request_id = Keyword.get(opts, :request_id)
    fingerprint = operation_fingerprint(conversation_id, content, opts)

    with :ok <- maybe_release_retry_reservation(conversation_id, request_id, fingerprint, opts) do
      case Handbean.Agent.OperationReceipt.reserve(
             {:message, conversation_id},
             request_id,
             fingerprint
           ) do
        :ok -> :ok
        {:replay, receipt} -> {:ok, replay_ack(receipt)}
        {:unknown, reason} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp maybe_release_retry_reservation(conversation_id, request_id, fingerprint, opts) do
    if Keyword.get(opts, :retry_reserved?, false) do
      case Handbean.Agent.OperationReceipt.release_reserved(
             {:message, conversation_id},
             request_id,
             fingerprint
           ) do
        :ok -> :ok
        {:error, reason} when reason in [:not_reserved, :idempotency_conflict] -> :ok
        {:error, _reason} -> {:error, :delivery_unknown}
      end
    else
      :ok
    end
  end

  @spec start_run(String.t(), String.t() | Handbean.Agent.Message.t(), keyword()) ::
          {:ok, ack()} | {:error, :run_in_progress | term()}
  def start_run(conversation_id, content, opts \\ [])
      when is_binary(conversation_id) and
             (is_binary(content) or is_struct(content, Handbean.Agent.Message)) and
             is_list(opts) do
    Handbean.ConversationStore.with_model_selection_lock(conversation_id, fn ->
      do_start_run(conversation_id, content, opts)
    end)
  end

  defp do_start_run(conversation_id, content, opts) do
    {content, opts} = stamp_message_ids(content, ensure_run_id(opts))

    with :ok <- Handbean.Storage.Health.check_write(),
         :ok <- validate_conversation_access(conversation_id, opts) do
      run_opts = RunOptions.build(conversation_id, opts)

      with :ok <- RunOptions.validate(run_opts),
           :ok <- RunOptions.validate_checkout(run_opts),
           {:ok, _pid} <-
             Session.start_or_get(session_id: conversation_id, model: run_opts[:model]) do
        case Handbean.Agent.Runner.start_run(conversation_id, content, run_opts) do
          {:ok, pid} ->
            runner_pid = wait_until_registered(conversation_id)

            ack = %{
              action: :started,
              run_id: Keyword.fetch!(run_opts, :run_id),
              run_pid: runner_pid || pid
            }

            {:ok, ack}

          {:error, reason} ->
            normalize_start_run_error(reason)
        end
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec start_cli_run(
          String.t(),
          Handbean.Agent.CliAgent.input(),
          String.t(),
          keyword()
        ) :: {:ok, ack()} | {:error, term()}
  def start_cli_run(conversation_id, content, display_text, opts \\ [])
      when is_binary(conversation_id) and
             (is_binary(content) or is_struct(content, Handbean.Agent.Message)) and
             is_binary(display_text) and is_list(opts) do
    {content, opts} = stamp_message_ids(content, opts)

    with :ok <- Handbean.Storage.Health.check_write(),
         :ok <- validate_conversation_access(conversation_id, opts),
         {:ok, _module} <- Handbean.Agent.CliAgent.Run.validate_input(content, opts),
         :ok <- reserve_operation(conversation_id, content, opts) do
      opts = ensure_run_id(opts)
      result = admit_cli_run(conversation_id, content, display_text, opts, 2)
      maybe_release_unaccepted(result, conversation_id, content, opts)
    end
  end

  defp admit_cli_run(_conversation_id, _content, _display_text, _opts, 0),
    do: {:error, :run_in_progress}

  defp admit_cli_run(conversation_id, content, display_text, opts, attempts) do
    requested_backend = Keyword.get(opts, :backend)

    case Handbean.Agent.Runner.status(conversation_id) do
      {:ok,
       %{
         running?: true,
         status: status,
         loop_owner: :cli_agent,
         backend: backend
       } = active}
      when status in [:starting, :running, :awaiting_approval] and backend == requested_backend ->
        enqueue_cli_follow_up(conversation_id, content, display_text, opts, attempts, active)

      {:ok, %{running?: true, status: :cancelling} = active} ->
        with :ok <- await_run_exit(active[:run_supervisor]) do
          admit_cli_run(conversation_id, content, display_text, opts, attempts - 1)
        end

      {:ok, %{running?: true}} ->
        {:error, :run_in_progress}

      {:ok, %{running?: false} = inactive} ->
        with :ok <- await_run_exit(inactive[:run_supervisor]) do
          start_or_retry_cli_run(conversation_id, content, display_text, opts, attempts)
        end

      {:error, :not_found} ->
        start_or_retry_cli_run(conversation_id, content, display_text, opts, attempts)

      error ->
        error
    end
  end

  defp enqueue_cli_follow_up(
         conversation_id,
         content,
         display_text,
         opts,
         attempts,
         active
       ) do
    candidate_opts =
      opts
      |> Keyword.put(:deliver_as, :follow_up)
      |> Keyword.put(:expected_run_id, active.run_id)
      |> Keyword.put(:persist_candidate?, Keyword.get(opts, :persist_inbound?, true))

    case enqueue_candidate(conversation_id, content, candidate_opts) do
      {:error, reason} when reason in [:sealed, :no_active_run, :stale_run] ->
        with :ok <- await_run_exit(active[:run_supervisor]) do
          admit_cli_run(conversation_id, content, display_text, opts, attempts - 1)
        end

      result ->
        result
    end
  end

  defp start_or_retry_cli_run(conversation_id, content, display_text, opts, attempts) do
    case start_cli_runner(conversation_id, content, display_text, opts) do
      {:error, :run_in_progress} ->
        admit_cli_run(conversation_id, content, display_text, opts, attempts - 1)

      result ->
        result
    end
  end

  defp start_cli_runner(conversation_id, content, display_text, opts) do
    opts =
      case Keyword.get(opts, :session_id) do
        session_id when is_binary(session_id) and session_id != "" ->
          opts

        _ ->
          backend = Keyword.get(opts, :backend)

          session_id =
            Handbean.Agent.CliAgent.Binding.resumable_session_id(
              conversation_id,
              backend,
              opts
            )

          Keyword.put(opts, :session_id, session_id)
      end

    Handbean.Agent.CliAgent.Runner.start(conversation_id, content, display_text, opts)
  end

  @spec enqueue_candidate(String.t(), String.t() | Handbean.Agent.Message.t(), keyword()) ::
          {:ok, ack()} | {:error, term()}
  def enqueue_candidate(conversation_id, content, opts \\ [])
      when is_binary(conversation_id) and
             (is_binary(content) or is_struct(content, Handbean.Agent.Message)) and
             is_list(opts) do
    with true <- Handbean.ConversationStore.active?(conversation_id),
         {content, opts} <- stamp_message_ids(content, opts),
         result <- Session.enqueue_candidate(conversation_id, content, opts) do
      case result do
        :ok -> {:ok, %{action: :enqueued, run_id: nil, run_pid: nil}}
        {:ok, ack} -> {:ok, ack}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :not_found}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(conversation_id) when is_binary(conversation_id) do
    case Handbean.Agent.Runner.status(conversation_id) do
      {:ok, status} ->
        {:ok, status}

      {:error, :not_found} ->
        session_status(conversation_id)

      {:error, _reason} ->
        session_status(conversation_id)
    end
  end

  @spec cancel(String.t(), keyword()) :: :ok | {:error, :not_running | term()}
  def cancel(conversation_id, opts \\ []) when is_binary(conversation_id) and is_list(opts) do
    with :ok <- bind_control(conversation_id, :cancel, opts) do
      result = do_cancel(conversation_id, opts)
      finish_control(conversation_id, :cancel, opts, result)
      result
    end
  end

  @spec promote_pending_message(String.t(), String.t()) :: :ok | {:error, term()}
  def promote_pending_message(conversation_id, message_id)
      when is_binary(conversation_id) and is_binary(message_id) do
    with {:ok, _info} <- Session.promote_pending_message(conversation_id, message_id) do
      maybe_resume_stall(conversation_id)
      :ok
    end
  catch
    :exit, reason -> {:error, reason}
  end

  @spec delete_pending_message(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_pending_message(conversation_id, message_id)
      when is_binary(conversation_id) and is_binary(message_id) do
    with {:ok, _info} <- Session.delete_pending_message(conversation_id, message_id), do: :ok
  end

  @spec resume(
          String.t(),
          [map()] | {:permission, String.t()} | {:ask_user, [map()]},
          keyword()
        ) :: :ok | {:error, term()}
  def resume(conversation_id, decisions, opts \\ [])

  def resume(conversation_id, {kind, _value} = decision, opts)
      when is_binary(conversation_id) and kind in [:permission, :ask_user] and is_list(opts) do
    with :ok <- bind_control(conversation_id, :resume, opts),
         {:ok, approval} <- validate_cli_approval(conversation_id, opts) do
      control_opts =
        opts
        |> Keyword.put_new(:expected_run_id, approval[:run_id])
        |> Keyword.put_new(:approval_batch_id, approval[:approval_batch_id])

      result = do_resume(conversation_id, decision, control_opts)
      finish_control(conversation_id, :resume, opts, result)
      result
    end
  end

  def resume(conversation_id, decisions, opts)
      when is_binary(conversation_id) and is_list(decisions) and is_list(opts) do
    with :ok <- bind_control(conversation_id, :resume, opts),
         {:ok, approval} <- validate_approval(conversation_id, decisions, opts) do
      control_opts =
        opts
        |> Keyword.put_new(:expected_run_id, approval[:run_id])
        |> Keyword.put_new(:approval_batch_id, approval[:approval_batch_id])

      result = do_resume(conversation_id, decisions, control_opts)
      finish_control(conversation_id, :resume, opts, result)
      result
    end
  end

  @spec resume_cli(
          String.t(),
          {:permission, String.t()} | {:ask_user, [map()]},
          keyword()
        ) :: :ok | {:error, term()}
  def resume_cli(conversation_id, decision, opts \\ []) do
    resume(conversation_id, decision, opts)
  end

  defp do_cancel(conversation_id, opts) do
    Handbean.Agent.Runner.cancel(conversation_id, opts[:expected_run_id])
  end

  defp runner_awaiting?(conversation_id) do
    case Handbean.Agent.Runner.status(conversation_id) do
      {:ok, %{status: :awaiting_approval}} -> true
      _ -> false
    end
  end

  defp do_resume(conversation_id, decisions, opts) do
    cond do
      not Handbean.ConversationStore.active?(conversation_id) ->
        {:error, :not_found}

      Handbean.ConversationStore.internal?(conversation_id) ->
        {:error, :internal_conversation}

      not runner_awaiting?(conversation_id) ->
        {:error, :not_awaiting_approval}

      true ->
        Handbean.Agent.Runner.resume(
          conversation_id,
          decisions,
          opts[:expected_run_id],
          opts[:approval_batch_id]
        )
    end
  end

  defp bind_control(conversation_id, kind, opts) do
    request_id = Keyword.get(opts, :request_id)

    fingerprint =
      Handbean.Agent.OperationReceipt.fingerprint({
        kind,
        conversation_id,
        Keyword.get(opts, :expected_run_id),
        Keyword.get(opts, :approval_batch_id)
      })

    case Handbean.Agent.OperationReceipt.reserve({kind, conversation_id}, request_id, fingerprint) do
      :ok -> :ok
      {:replay, receipt} -> {:ok, replay_ack(receipt)}
      {:unknown, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_control(conversation_id, kind, opts, result) do
    request_id = Keyword.get(opts, :request_id)

    case result do
      :ok ->
        Handbean.Agent.OperationReceipt.complete({kind, conversation_id}, request_id, %{
          status: :ok
        })

      {:error, reason} ->
        Handbean.Agent.OperationReceipt.mark_unknown({kind, conversation_id}, request_id)
        {:error, reason}
    end
  end

  defp expected_run(conversation_id, opts) do
    case Keyword.get(opts, :expected_run_id) do
      nil ->
        :ok

      run_id when is_binary(run_id) ->
        case Handbean.Agent.Runner.status(conversation_id) do
          {:ok, %{run_id: ^run_id, status: :awaiting_approval}} -> :ok
          {:ok, %{run_id: ^run_id}} -> :ok
          {:ok, %{run_id: other}} -> {:error, {:run_mismatch, other}}
          _ -> {:error, :not_awaiting_approval}
        end
    end
  end

  defp validate_approval(conversation_id, decisions, opts) do
    awaiting =
      if runner_awaiting?(conversation_id), do: :ok, else: {:error, :not_awaiting_approval}

    with :ok <- expected_run(conversation_id, opts),
         :ok <- awaiting,
         {:ok, info} <- status(conversation_id) do
      pending = pending_tool_ids(info)

      cond do
        opts[:approval_batch_id] && opts[:approval_batch_id] != info[:approval_batch_id] ->
          {:error, :stale_approval}

        Enum.any?(decisions, fn decision ->
          id = Handbean.Utils.SafeMap.get_any(decision, "tool_call_id", :tool_call_id)
          pending != [] and id not in pending
        end) ->
          {:error, :approval_mismatch}

        true ->
          {:ok, info}
      end
    end
  end

  defp validate_cli_approval(conversation_id, opts) do
    awaiting =
      if runner_awaiting?(conversation_id), do: :ok, else: {:error, :not_awaiting_approval}

    with :ok <- expected_run(conversation_id, opts),
         :ok <- awaiting,
         {:ok, info} <- status(conversation_id) do
      if opts[:approval_batch_id] && opts[:approval_batch_id] != info[:approval_batch_id] do
        {:error, :stale_approval}
      else
        {:ok, info}
      end
    end
  end

  defp pending_tool_ids(%{interrupt_data: %{action_requests: requests}}) when is_list(requests) do
    Enum.map(
      requests,
      &Handbean.Utils.SafeMap.get_any(&1, :tool_call_id, "tool_call_id")
    )
  end

  defp pending_tool_ids(_info), do: []

  defp validate_conversation_access(id, opts) do
    case Handbean.ConversationStore.lifecycle_status(id) do
      :pending_delete ->
        {:error, :not_found}

      :active ->
        if Handbean.ConversationStore.internal?(id) and
             not (opts[:delegated?] == true and is_pid(opts[:delegation_owner]) and
                    opts[:delegation_owner] == Process.whereis(Handbean.Agent.Delegation)) do
          {:error, :internal_conversation}
        else
          :ok
        end

      :missing ->
        :ok
    end
  end

  defp maybe_resume_stall(conversation_id) do
    case status(conversation_id) do
      {:ok, %{running?: true, interrupt_type: :stall_check}} ->
        Handbean.Agent.Runner.resume(conversation_id, %{"action" => "continue"})

      _ ->
        :ok
    end
  end

  defp present_task_instructions?(opts) do
    case Keyword.get(opts, :task_instructions) do
      text when is_binary(text) -> String.trim(text) != ""
      _ -> false
    end
  end

  defp normalize_start_run_error({:already_started, _pid}), do: {:error, :run_in_progress}

  defp normalize_start_run_error({:inbound_persist_failed, reason}),
    do: {:error, reason}

  defp normalize_start_run_error({:shutdown, {:failed_to_start_child, _mod, reason}}),
    do: normalize_start_run_error(reason)

  defp normalize_start_run_error(reason), do: {:error, reason}

  defp ensure_run_id(opts), do: Keyword.put_new(opts, :run_id, Ecto.UUID.generate())

  defp stamp_message_ids(content, opts) do
    struct_id = message_id(content)
    opt_message_id = present_id(Keyword.get(opts, :message_id))
    opt_transcript_id = present_id(Keyword.get(opts, :transcript_id))

    canonical = opt_message_id || opt_transcript_id || struct_id || Ecto.UUID.generate()

    content =
      case content do
        %Handbean.Agent.Message{} = message -> %{message | id: canonical}
        other -> other
      end

    inbound_id = present_id(Keyword.get(opts, :inbound_id)) || canonical

    opts =
      opts
      |> Keyword.put(:message_id, canonical)
      |> Keyword.put(:transcript_id, canonical)
      |> Keyword.put(:inbound_id, inbound_id)

    {content, opts}
  end

  defp present_id(id) when is_binary(id) and id != "", do: id
  defp present_id(_), do: nil

  defp message_id(%Handbean.Agent.Message{id: id}) when is_binary(id) and id != "", do: id
  defp message_id(_), do: nil

  defp session_status(conversation_id) do
    case Session.whereis(conversation_id) do
      nil ->
        {:error, :not_found}

      _pid ->
        %{meta: meta} = Session.snapshot(conversation_id)
        binding = Handbean.Agent.CliAgent.Binding.get(conversation_id)

        {:ok,
         %{
           conversation_id: conversation_id,
           running?: Map.get(meta, :running?, false),
           run_pid: Map.get(meta, :agent_pid),
           run_id: Map.get(meta, :run_id),
           run_supervisor: Map.get(meta, :run_supervisor),
           queue_pid: Map.get(meta, :queue_pid),
           status: Map.get(meta, :status),
           cli_binding: binding
         }}
    end
  end

  defp wait_until_registered(conversation_id, attempts \\ 20)

  defp wait_until_registered(_conversation_id, 0), do: nil

  defp wait_until_registered(conversation_id, attempts) do
    case Registry.lookup(Handbean.AgentRunRegistry, conversation_id) do
      [{pid, _metadata}] ->
        pid

      _ ->
        Process.sleep(1)
        wait_until_registered(conversation_id, attempts - 1)
    end
  end
end
