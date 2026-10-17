defmodule Handbean.Agent.Coordinator do
  @moduledoc """
  Facade for agent run lifecycle operations.

  Entry points such as LiveView, CLI, webhook, MCP, or extension code should
  express intent here instead of directly starting `Handbean.Agent.run/2`.
  """

  require Logger

  alias Handbean.PubSub.Session

  @type source :: :live_view | :sns | :webhook | :cli | :mcp | atom()
  @type action :: :started | :enqueued
  @type ack :: %{action: action(), run_id: String.t() | nil, run_pid: pid() | nil}

  @required_opts [:model, :provider_config, :tools, :source]

  @spec add_message(String.t(), String.t() | Handbean.Agent.Message.t(), keyword()) ::
          {:ok, ack()} | {:error, term()}
  def add_message(conversation_id, content, opts \\ [])
      when is_binary(conversation_id) and
             (is_binary(content) or is_struct(content, Handbean.Agent.Message)) and
             is_list(opts) do
    {content, opts} = stamp_message_ids(content, opts)

    with :ok <- Handbean.Storage.Health.check_write(),
         :ok <- reserve_operation(conversation_id, content, opts),
         :ok <- validate_conversation_access(conversation_id, opts),
         :ok <- validate_required_opts(opts),
         :ok <- validate_model_policy(opts),
         :ok <- validate_advisor_policy(opts),
         opts <- ensure_run_id(opts),
         {:ok, _pid} <- Session.start_or_get(session_id: conversation_id, model: opts[:model]) do
      admit_message(conversation_id, content, opts, 2)
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
             result <- start_run(id, content, opts) do
          case result do
            {:error, :run_in_progress} -> release_idle_busy(id, content, opts)
            other -> other
          end
        end

      {:error, :not_found} ->
        case start_run(id, content, opts) do
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
            case start_run(id, content, opts) do
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
          case start_run(id, content, opts) do
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
    request_id = Keyword.get(opts, :request_id)

    case Handbean.Agent.OperationReceipt.release_reserved(
           {:message, conversation_id},
           request_id,
           operation_fingerprint(conversation_id, content, opts)
         ) do
      :ok -> {:error, :busy}
      {:error, _reason} -> {:error, :delivery_unknown}
    end
  end

  defp operation_fingerprint(conversation_id, content, opts) do
    Handbean.Agent.OperationReceipt.fingerprint({conversation_id, content, opts[:deliver_as]})
  end

  defp reserve_operation(conversation_id, content, opts) do
    request_id = Keyword.get(opts, :request_id)

    fingerprint = operation_fingerprint(conversation_id, content, opts)

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

  @spec start_run(String.t(), String.t() | Handbean.Agent.Message.t(), keyword()) ::
          {:ok, ack()} | {:error, :run_in_progress | term()}
  def start_run(conversation_id, content, opts \\ [])
      when is_binary(conversation_id) and
             (is_binary(content) or is_struct(content, Handbean.Agent.Message)) and
             is_list(opts) do
    with :ok <- Handbean.Storage.Health.check_write(),
         :ok <- validate_conversation_access(conversation_id, opts),
         :ok <- validate_required_opts(opts),
         :ok <- validate_model_policy(opts),
         :ok <- validate_advisor_policy(opts),
         opts <- ensure_run_id(opts),
         {:ok, _pid} <- Session.start_or_get(session_id: conversation_id, model: opts[:model]) do
      {content, opts} = stamp_message_ids(content, opts)
      run_opts = agent_run_opts(conversation_id, opts)

      with :ok <- runtime_checkout_available(run_opts) do
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
    with :ok <- Handbean.Storage.Health.check_write(),
         :ok <- validate_conversation_access(conversation_id, opts) do
      {content, opts} = stamp_message_ids(content, opts)
      opts = ensure_run_id(opts)

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
  end

  @spec enqueue_candidate(String.t(), String.t() | Handbean.Agent.Message.t(), keyword()) ::
          {:ok, ack()} | {:error, term()}
  def enqueue_candidate(conversation_id, content, opts \\ [])
      when is_binary(conversation_id) and
             (is_binary(content) or is_struct(content, Handbean.Agent.Message)) and
             is_list(opts) do
    {content, opts} = stamp_message_ids(content, opts)

    case Session.enqueue_candidate(conversation_id, content, opts) do
      :ok -> {:ok, %{action: :enqueued, run_id: nil, run_pid: nil}}
      {:ok, ack} -> {:ok, ack}
      {:error, reason} -> {:error, reason}
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

  defp runtime_checkout_available(opts) do
    if free_chat?(opts) do
      :ok
    else
      case Keyword.get(opts, :working_directory) do
        path when is_binary(path) and path != "" ->
          if File.dir?(path), do: :ok, else: {:error, :checkout_unavailable}

        _ ->
          {:error, :checkout_unavailable}
      end
    end
  end

  defp validate_required_opts(opts) do
    missing = Enum.reject(@required_opts, &Keyword.has_key?(opts, &1))

    missing =
      if free_chat?(opts) or present_workspace_path?(opts) do
        missing
      else
        [:workspace_path | missing]
      end

    if missing == [] do
      :ok
    else
      {:error, {:missing_opts, missing}}
    end
  end

  defp free_chat?(opts), do: Keyword.get(opts, :chat_scope) == :free

  defp present_workspace_path?(opts) do
    case Keyword.get(opts, :workspace_path) do
      path when is_binary(path) and path != "" -> true
      _ -> false
    end
  end

  defp validate_conversation_access(id, opts) do
    if Handbean.ConversationStore.internal?(id) and
         not (opts[:delegated?] == true and is_pid(opts[:delegation_owner]) and
                opts[:delegation_owner] == Process.whereis(Handbean.Agent.Delegation)) do
      {:error, :internal_conversation}
    else
      :ok
    end
  end

  defp validate_model_policy(opts) do
    cond do
      explicit_provider_with_raw_model?(opts) -> :ok
      free_chat?(opts) -> :ok
      true -> validate_workspace_model_policy(opts)
    end
  end

  defp explicit_provider_with_raw_model?(opts) do
    Keyword.has_key?(opts, :provider) and
      opts
      |> Keyword.fetch!(:model)
      |> String.contains?("/")
      |> Kernel.not()
  end

  defp validate_workspace_model_policy(opts) do
    workspace_path = Keyword.fetch!(opts, :workspace_path)
    model = Keyword.fetch!(opts, :model)

    if Handbean.Agent.ModelConfig.model_allowed_for_workspace?(workspace_path, model) do
      validate_om_model_policy(opts)
    else
      {:error,
       Gettext.dgettext(
         Handbean.Gettext,
         "errors",
         "Model %{model} is not allowed in this workspace. Check Settings → Model / AI → Default model.",
         model: model
       )}
    end
  end

  defp validate_om_model_policy(opts) do
    workspace_path = Keyword.fetch!(opts, :workspace_path)

    if Handbean.WorkspaceSettings.builtin_memory_enabled(workspace_path) do
      om = Keyword.get(opts, :om, %{})
      memory_model_allowed(workspace_path, om[:model] || om["model"])
    else
      :ok
    end
  end

  # A removed catalog entry is not a workspace restriction. "Unrestricted" and
  # an allowlist that simply does not name the model both mean "do not use it
  # for memory", so the chat model can still start. An explicit allowlist that
  # excludes a model still present in the catalog remains a hard error.
  defp memory_model_allowed(_workspace_path, model)
       when model in [nil, ""],
       do: :ok

  defp memory_model_allowed(workspace_path, model) do
    cond do
      Handbean.Agent.ModelConfig.model_allowed_for_workspace?(workspace_path, model) ->
        :ok

      Handbean.Agent.ModelConfig.model_in_catalog?(model) ->
        {:error, memory_model_rejected(model)}

      true ->
        :ok
    end
  end

  defp memory_model_rejected(model) do
    Gettext.dgettext(
      Handbean.Gettext,
      "errors",
      "Observational Memory model (%{model}) is not allowed in this workspace. Check Settings → Model / AI → Observational Memory → Memory model.",
      model: model
    )
  end

  defp validate_advisor_policy(opts) do
    if free_chat?(opts) do
      :ok
    else
      {:ok, _pin} =
        Handbean.Agent.Advisor.validate_start(Keyword.fetch!(opts, :workspace_path), opts)

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

  defp agent_run_opts(conversation_id, opts) do
    opts =
      case Handbean.ConversationStore.get_metadata(conversation_id) do
        {:ok, meta} ->
          opts =
            opts
            |> Keyword.put_new(:workspace_id, meta["workspace_id"])
            |> put_created_by(meta)
            |> put_checkout_path(meta)

          if get_in(meta, ["collaboration", "read_only"]) == true,
            do: Keyword.put(opts, :delegated_read_only, true),
            else: opts

        _ ->
          opts
      end

    opts
    |> Keyword.put(:session_id, conversation_id)
    |> Keyword.put(:conversation_id, conversation_id)
    |> ensure_run_id()
    |> put_saved_provider()
    |> put_transcript_history(conversation_id)
    |> put_working_directory()
    |> put_builtin_memory()
    |> put_skills()
    |> put_advisor_pin()
  end

  defp put_checkout_path(opts, meta) do
    if Keyword.has_key?(opts, :working_directory) do
      opts
    else
      case meta["checkout_path"] do
        path when is_binary(path) and path != "" ->
          case Handbean.ConversationStore.effective_checkout_path(meta) do
            {:ok, checkout_path} -> Keyword.put(opts, :working_directory, checkout_path)
            {:error, _reason} -> Keyword.put(opts, :working_directory, nil)
          end

        _missing ->
          opts
      end
    end
  end

  defp put_created_by(opts, meta) do
    case Handbean.ConversationStore.parent_conversation_id(meta) do
      parent_id when is_binary(parent_id) ->
        Keyword.put(opts, :created_by_conversation_id, parent_id)

      _ ->
        opts
    end
  end

  # A composite model id is the saved catalog entry. Load that provider so a
  # subscription adapter is selected from models.json, not from a caller that
  # only forwarded transport options such as a test plug.
  defp put_saved_provider(opts) do
    model = Keyword.get(opts, :model)

    with true <- is_binary(model) and String.contains?(model, "/"),
         {:ok, saved, model_id} <- saved_provider_config(opts, model) do
      caller = Keyword.get(opts, :provider_config, %{})

      opts
      |> Keyword.put(:model, model_id)
      |> Keyword.put(:provider_config, Map.merge(saved, caller))
    else
      _ -> opts
    end
  end

  defp saved_provider_config(opts, model) do
    cond do
      free_chat?(opts) ->
        Handbean.Agent.ModelConfig.resolve_global_model(model)

      match?({:ok, _}, Keyword.fetch(opts, :workspace_path)) ->
        Handbean.Agent.ModelConfig.resolve_model_for_workspace(opts[:workspace_path], model)

      true ->
        :error
    end
  end

  defp put_working_directory(opts) do
    cond do
      free_chat?(opts) ->
        Keyword.delete(opts, :working_directory)

      true ->
        case Keyword.fetch(opts, :working_directory) do
          {:ok, _value} -> opts
          :error -> Keyword.put(opts, :working_directory, Keyword.fetch!(opts, :workspace_path))
        end
    end
  end

  defp put_builtin_memory(opts) do
    enabled =
      if free_chat?(opts) do
        true
      else
        opts
        |> Keyword.fetch!(:workspace_path)
        |> Handbean.WorkspaceSettings.builtin_memory_enabled()
      end

    om =
      opts
      |> Keyword.get(:om, %{})
      |> then(&if(is_map(&1), do: &1, else: %{}))
      |> Map.delete("enabled")
      |> Map.put(:enabled, enabled)

    opts
    |> Keyword.put(:builtin_memory_enabled, enabled)
    |> Keyword.put(:om, om)
  end

  defp put_skills(opts) do
    if free_chat?(opts),
      do: Keyword.put(opts, :skills, false),
      else: Keyword.put(opts, :skills, true)
  end

  defp put_advisor_pin(opts) do
    if free_chat?(opts) do
      Keyword.put(opts, :advisor, Handbean.Agent.Advisor.unavailable())
    else
      {:ok, pin} =
        Handbean.Agent.Advisor.validate_start(Keyword.fetch!(opts, :workspace_path), opts)

      Keyword.put(opts, :advisor, pin)
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

  defp put_transcript_history(opts, conversation_id) do
    Keyword.put_new_lazy(opts, :history_messages, fn ->
      transcript_history_messages(
        conversation_id,
        Keyword.get(opts, :run_id),
        history_workspace_path(opts)
      )
    end)
  end

  defp history_workspace_path(opts) do
    if free_chat?(opts), do: nil, else: opts[:working_directory]
  end

  defp transcript_history_messages(conversation_id, current_run_id, workspace_path) do
    case Handbean.ConversationTranscriptStore.list(conversation_id) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(current_run_id && Map.get(&1, "run_id") == current_run_id))
        |> Handbean.Attachments.History.to_messages(workspace_path, conversation_id)

      {:error, reason} ->
        Logger.warning(fn ->
          "[Coordinator] failed to load transcript history conversation=#{conversation_id} " <>
            "reason=#{inspect(reason)}"
        end)

        []
    end
  end

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
