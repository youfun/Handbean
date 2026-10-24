defmodule Handbean.WorkspaceCommand do
  @moduledoc """
  Owns commands explicitly submitted with the `!` workspace shortcut.

  A direct command is a user action, not an Agent run or tool authorization. It
  therefore bypasses model invocation and conversation permission modes while
  retaining the Bash boundary's host declaration, sensitive-path precheck,
  sandbox policy, environment, timeout, output bound, and process cleanup.

  Commands may run alongside an Agent run. They are limited to one per
  conversation and eight globally, survive client navigation, and have a hard
  timeout. Agent Stop does not cancel them. If the owner or host stops, running
  commands are terminalized as interrupted and are never replayed because their
  side effects may already have happened.
  """

  use GenServer

  require Logger

  alias Handbean.ConversationTranscriptStore
  alias Handbean.Platform.ProcessSandbox
  alias Handbean.Tool.Builtin.Bash
  alias Handbean.WorkspaceCommand.AgentResponse

  @max_command_bytes 32_000
  @max_global 8
  @timeout_seconds 120
  @response_retry_ms 5_000
  @transient_agent_response_errors [
    :busy,
    :no_active_run,
    :persistence_unavailable,
    :queue_full,
    :run_in_progress,
    :sealed,
    :stale_run
  ]

  @type command :: String.t() | {:extension, String.t(), String.t()}

  @type reason ::
          :busy
          | :empty_command
          | :idempotency_conflict
          | :invalid_command
          | :not_available
          | :not_found
          | :not_workspace_conversation
          | :persistence_unavailable
          | :workspace_unavailable

  def child_specs do
    [
      {Task.Supervisor, name: Handbean.WorkspaceCommand.TaskSupervisor},
      __MODULE__
    ]
  end

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether this host explicitly declares direct shell execution support."
  @spec supported?() :: boolean()
  def supported?, do: validate_host() == :ok

  @doc "Classify a composer message without treating malformed `!` input as ordinary chat."
  @spec parse(term()) :: :not_command | {:ok, command()} | {:error, reason()}
  def parse(message) when is_binary(message) do
    message = String.trim(message)

    if String.starts_with?(message, "/ext:") do
      {:ok, Handbean.Extension.Command.parse(message)}
    else
      parse_shell(message)
    end
  end

  def parse(_message), do: :not_command

  @doc "List executable extension commands for a checkout."
  def list_commands(workspace), do: Handbean.Extension.Command.list(workspace)

  defp parse_shell(message) do
    if String.starts_with?(message, "!") do
      command = message |> String.slice(1..-1//1) |> String.trim()

      cond do
        command == "" -> {:error, :empty_command}
        byte_size(command) > @max_command_bytes -> {:error, :invalid_command}
        not String.valid?(command) -> {:error, :invalid_command}
        true -> {:ok, command}
      end
    else
      :not_command
    end
  end

  @spec active?(String.t()) :: boolean()
  def active?(conversation_id) when is_binary(conversation_id) do
    GenServer.call(__MODULE__, {:active?, conversation_id})
  catch
    :exit, _reason -> false
  end

  @spec cancel(String.t()) :: :ok
  def cancel(conversation_id) when is_binary(conversation_id) do
    GenServer.call(__MODULE__, {:cancel, conversation_id}, :infinity)
  catch
    :exit, _reason -> :ok
  end

  @doc "Submit one already-classified command for the conversation's immutable checkout."
  @spec submit(String.t(), command(), keyword()) :: {:ok, map()} | {:error, reason()}
  def submit(conversation_id, command, opts \\ [])

  def submit(conversation_id, command, opts)
      when is_binary(conversation_id) and (is_binary(command) or is_tuple(command)) and
             is_list(opts) do
    operation_id = Keyword.get(opts, :operation_id, Ecto.UUID.generate())
    source = Keyword.get(opts, :source, :unknown)

    request = {:submit, conversation_id, command, operation_id, source, opts}

    try do
      GenServer.call(__MODULE__, request, :infinity)
    catch
      :exit, _reason -> recover_submission(conversation_id, operation_id)
    end
  end

  def submit(_conversation_id, _command, _opts), do: {:error, :invalid_command}

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    case ConversationTranscriptStore.interrupt_workspace_commands(interrupted_text()) do
      {:ok, conversation_ids} ->
        Enum.each(conversation_ids, &broadcast_updated/1)
        send(self(), :recover_agent_responses)
        {:ok, %{operations: %{}, refs: %{}}}

      {:error, :unsupported} ->
        {:ok, %{operations: %{}, refs: %{}}}

      {:error, reason} ->
        {:stop, {:workspace_command_recovery_failed, reason}}
    end
  end

  @impl true
  def handle_call(
        {:submit, conversation_id, command, operation_id, source, opts},
        _from,
        state
      ) do
    with {:ok, command} <- normalize_command(command),
         :ok <- validate_operation_id(operation_id),
         {:ok, binding} <- workspace_binding(conversation_id),
         :ok <- validate_command_host(command, binding),
         :ok <- admit(state, conversation_id, operation_id),
         {:ok, admission} <- admit_operation(conversation_id, command, operation_id, source) do
      case admission do
        {:existing, entries} ->
          {:reply, {:ok, acknowledgement(operation_id, entries, :existing)}, state}

        {:new, entries} ->
          {reply, state} = start_operation(state, binding, command, operation_id, entries, opts)
          Enum.each(entries, &broadcast_updated(conversation_id, &1))
          {:reply, reply, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:active?, conversation_id}, _from, state) do
    active? =
      Enum.any?(state.operations, fn {_id, operation} ->
        operation.conversation_id == conversation_id
      end)

    {:reply, active?, state}
  end

  def handle_call({:cancel, conversation_id}, _from, state) do
    {cancelled, remaining} =
      Enum.split_with(state.operations, fn {_id, operation} ->
        operation.conversation_id == conversation_id
      end)

    Enum.each(cancelled, fn {_id, operation} ->
      if is_pid(operation.pid) do
        _ =
          Task.Supervisor.terminate_child(Handbean.WorkspaceCommand.TaskSupervisor, operation.pid)
      end
    end)

    cancelled_refs = MapSet.new(Enum.map(cancelled, fn {_id, operation} -> operation.ref end))
    refs = Map.reject(state.refs, fn {ref, _id} -> MapSet.member?(cancelled_refs, ref) end)

    {:reply, :ok, %{state | operations: Map.new(remaining), refs: refs}}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.fetch(state.refs, ref) do
      {:ok, operation_id} ->
        Process.demonitor(ref, [:flush])
        {:noreply, settle_and_drop(state, operation_id, result)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.fetch(state.refs, ref) do
      {:ok, operation_id} ->
        result = {:error, worker_error(reason)}
        {:noreply, settle_and_drop(state, operation_id, result)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:command_deadline, operation_id}, state) do
    case state.operations[operation_id] do
      %{pid: pid, ref: ref} when is_pid(pid) ->
        Process.demonitor(ref, [:flush])
        Task.Supervisor.terminate_child(Handbean.WorkspaceCommand.TaskSupervisor, pid)
        state = %{state | refs: Map.delete(state.refs, ref)}
        {:noreply, settle_and_drop(state, operation_id, {:error, "Command timed out"})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_terminal_persistence, operation_id}, state) do
    case Map.fetch(state.operations, operation_id) do
      {:ok, %{terminal_result: result, terminal_duration: duration}} ->
        {:noreply, settle_and_drop(state, operation_id, result, duration)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:recover_agent_responses, state) do
    retry? =
      case ConversationTranscriptStore.pending_workspace_command_responses() do
        {:ok, []} ->
          false

        {:ok, pending} ->
          Enum.each(pending, fn {conversation_id, entry} ->
            unless response_still_in_runtime?(conversation_id, entry) do
              deliver_agent_response(conversation_id, entry, &AgentResponse.deliver/2)
            end
          end)

          true

        {:error, :unsupported} ->
          false

        {:error, reason} ->
          Logger.warning("[WorkspaceCommand] response recovery failed: #{inspect(reason)}")
          true
      end

    if retry?, do: schedule_agent_response_recovery()
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp normalize_command({:extension, name, args} = command)
       when is_binary(name) and is_binary(args) do
    if byte_size(name) + byte_size(args) <= @max_command_bytes and String.valid?(name <> args),
      do: {:ok, command},
      else: {:error, :invalid_command}
  end

  defp normalize_command(command) when is_binary(command) do
    command = String.trim(command)

    cond do
      command == "" -> {:error, :empty_command}
      byte_size(command) > @max_command_bytes -> {:error, :invalid_command}
      not String.valid?(command) -> {:error, :invalid_command}
      true -> {:ok, command}
    end
  end

  defp normalize_command(_), do: {:error, :invalid_command}

  defp validate_command_host({:extension, name, _args}, binding) do
    case Handbean.Extension.Command.resolve(binding.checkout_path, name) do
      {:ok, _command} -> :ok
      {:error, _} = error -> error
    end
  end

  defp validate_command_host(_command, _binding), do: validate_host()

  defp validate_operation_id(id) when is_binary(id) and byte_size(id) in 1..200, do: :ok
  defp validate_operation_id(_id), do: {:error, :invalid_command}

  defp validate_host do
    cond do
      not Handbean.Host.shell?() -> {:error, :not_available}
      Handbean.Host.shell_isolation() == :none -> :ok
      ProcessSandbox.os_enforced?() -> :ok
      true -> {:error, :not_available}
    end
  end

  @spec workspace_binding(String.t()) :: {:ok, map()} | {:error, term()}
  def workspace_binding(conversation_id) do
    with {:ok, conversation} <- Handbean.ConversationStore.get_metadata(conversation_id),
         true <- conversation["scope"] == "workspace" and conversation["visibility"] == "user",
         {:ok, checkout_path} <- Handbean.ConversationStore.effective_checkout_path(conversation),
         {:ok, workspace} <- Handbean.WorkspaceStore.get_by_path(checkout_path),
         true <- workspace["id"] == conversation["workspace_id"] do
      {:ok,
       %{
         conversation_id: conversation_id,
         conversation: conversation,
         workspace_id: workspace["id"],
         workspace: workspace,
         workspace_path: workspace["path"],
         checkout_path: checkout_path
       }}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} -> {:error, :workspace_unavailable}
      false -> {:error, :not_workspace_conversation}
    end
  end

  defp admit(state, conversation_id, operation_id) do
    active_for_conversation =
      Enum.count(state.operations, fn {_id, operation} ->
        operation.conversation_id == conversation_id
      end)

    cond do
      match?(%{conversation_id: ^conversation_id}, state.operations[operation_id]) -> :ok
      Map.has_key?(state.operations, operation_id) -> {:error, :busy}
      map_size(state.operations) >= @max_global -> {:error, :busy}
      active_for_conversation >= 1 -> {:error, :busy}
      true -> :ok
    end
  end

  defp admit_operation(conversation_id, command, operation_id, source) do
    entries = start_entries(conversation_id, command, operation_id, source)
    input_command = persisted_command(command)

    case ConversationTranscriptStore.append_many(conversation_id, entries) do
      {:ok, persisted} ->
        {:ok, {:new, persisted}}

      {:error, :duplicate_id} ->
        case existing_entries(conversation_id, operation_id) do
          [_, %{"input" => %{"command" => ^input_command}}] = existing ->
            {:ok, {:existing, existing}}

          [_, _] ->
            {:error, :idempotency_conflict}

          _ ->
            {:error, :persistence_unavailable}
        end

      {:error, _reason} ->
        {:error, :persistence_unavailable}
    end
  end

  defp start_operation(state, binding, command, operation_id, entries, opts) do
    started_at = System.monotonic_time(:millisecond)

    operation = %{
      conversation_id: binding.conversation_id,
      operation_id: operation_id,
      ref: nil,
      pid: nil,
      started_at: started_at,
      responder: Keyword.get(opts, :responder, &AgentResponse.deliver/2),
      terminal_persister: Keyword.get(opts, :terminal_persister, &persist_terminal/4)
    }

    case start_worker(command, binding, operation_id, opts) do
      {:ok, task} ->
        timer =
          if is_tuple(command),
            do:
              Process.send_after(
                self(),
                {:command_deadline, operation_id},
                command_timeout_ms(opts)
              )

        operation = operation |> Map.merge(%{ref: task.ref, pid: task.pid, timer: timer})

        state = %{
          state
          | operations: Map.put(state.operations, operation_id, operation),
            refs: Map.put(state.refs, task.ref, operation_id)
        }

        {{:ok, acknowledgement(operation_id, entries, :started)}, state}

      {:error, result} ->
        operation =
          operation
          |> Map.put(:terminal_result, result)
          |> Map.put(:terminal_duration, 0)

        state = %{state | operations: Map.put(state.operations, operation_id, operation)}
        state = settle_and_drop(state, operation_id, result, 0)

        {{:ok,
          acknowledgement(
            operation_id,
            reload_entries(binding.conversation_id, operation_id),
            :failed
          )}, state}
    end
  end

  defp command_timeout_ms(opts) do
    case Keyword.get(opts, :timeout_ms, @timeout_seconds * 1_000) do
      value when is_integer(value) and value > 0 and value <= @timeout_seconds * 1_000 -> value
      _ -> @timeout_seconds * 1_000
    end
  end

  defp start_worker(command, binding, operation_id, opts) do
    executor = Keyword.get(opts, :executor, &execute/3)
    starter = Keyword.get(opts, :worker_starter, &default_worker_starter/1)

    task =
      starter.(fn ->
        invoke_executor(executor, command, binding, operation_id)
      end)

    if is_map(task) and is_pid(task.pid) and is_reference(task.ref) do
      {:ok, task}
    else
      {:error, {:error, "Command worker could not start"}}
    end
  rescue
    error -> {:error, {:error, "Command worker could not start: #{Exception.message(error)}"}}
  catch
    kind, reason ->
      {:error, {:error, "Command worker could not start: #{kind}: #{inspect(reason)}"}}
  end

  defp default_worker_starter(fun) do
    Task.Supervisor.async(Handbean.WorkspaceCommand.TaskSupervisor, fun)
  end

  defp invoke_executor(executor, command, binding, operation_id) do
    context = execution_context(binding, operation_id)

    try do
      case :erlang.fun_info(executor, :arity) do
        {:arity, 3} -> executor.(command, context, @timeout_seconds)
        {:arity, 2} -> executor.(command, context)
      end
    rescue
      error -> {:error, Exception.message(error)}
    catch
      kind, reason -> {:error, "Command worker stopped: #{kind}: #{inspect(reason)}"}
    end
  end

  defp execute({:extension, _name, _args} = command, context, _timeout_seconds),
    do: Handbean.Extension.Command.execute(command, context)

  defp execute(command, context, timeout_seconds) do
    Bash.execute(
      %{"command" => command, "timeout" => timeout_seconds, "job" => false},
      context
    )
  end

  defp execution_context(binding, operation_id) do
    %{
      conversation_id: binding.conversation_id,
      workspace_id: binding.workspace_id,
      workspace_path: binding.workspace_path,
      checkout_path: binding.checkout_path,
      working_directory: binding.checkout_path,
      tool_call_id: operation_id,
      direct_command: true
    }
  end

  defp settle_and_drop(state, operation_id, result) do
    operation = Map.fetch!(state.operations, operation_id)
    duration = max(System.monotonic_time(:millisecond) - operation.started_at, 0)
    settle_and_drop(state, operation_id, result, duration)
  end

  defp settle_and_drop(state, operation_id, result, duration) do
    operation = Map.fetch!(state.operations, operation_id)

    operation =
      if Map.has_key?(operation, :terminal_result) do
        operation
      else
        if timer = operation[:timer], do: Process.cancel_timer(timer)
        if is_reference(operation.ref), do: Process.demonitor(operation.ref, [:flush])

        Map.merge(operation, %{
          terminal_result: result,
          terminal_duration: duration,
          timer: nil,
          pid: nil
        })
      end

    result = operation.terminal_result
    duration = operation.terminal_duration

    state = %{
      state
      | operations: Map.put(state.operations, operation_id, operation),
        refs: Map.delete(state.refs, operation.ref)
    }

    case safe_persist_terminal(operation, result, duration) do
      {:ok, entry} ->
        deliver_agent_response(operation.conversation_id, entry, operation.responder)
        schedule_agent_response_recovery()
        drop_operation(state, operation_id, operation.ref)

      {:error, :not_found} ->
        drop_operation(state, operation_id, operation.ref)

      {:error, reason} ->
        Logger.warning(
          "[WorkspaceCommand] terminal persistence failed operation=#{operation_id}: #{inspect(reason)}"
        )

        Process.send_after(self(), {:retry_terminal_persistence, operation_id}, 250)

        operation =
          operation
          |> Map.put(:terminal_result, result)
          |> Map.put(:terminal_duration, duration)

        %{state | operations: Map.put(state.operations, operation_id, operation)}
    end
  end

  defp drop_operation(state, operation_id, ref) do
    if timer = state.operations[operation_id][:timer], do: Process.cancel_timer(timer)

    %{
      state
      | operations: Map.delete(state.operations, operation_id),
        refs: Map.delete(state.refs, ref)
    }
  end

  defp safe_persist_terminal(operation, result, duration) do
    operation.terminal_persister.(
      operation.conversation_id,
      operation.operation_id,
      result,
      duration
    )
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp persist_terminal(conversation_id, operation_id, result, duration) do
    patch = terminal_patch(result, duration)

    case ConversationTranscriptStore.update(
           conversation_id,
           tool_entry_id(operation_id),
           patch
         ) do
      {:ok, entry} ->
        broadcast_updated(conversation_id, entry)
        {:ok, entry}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp terminal_patch({:ok, output, metadata}, duration)
       when is_binary(output) and is_map(metadata) do
    exit_code = metadata[:exit_code] || metadata["exit_code"]
    timed_out? = metadata[:timed_out] == true or metadata["timed_out"] == true

    error =
      cond do
        timed_out? -> "Command timed out"
        is_integer(exit_code) and exit_code != 0 -> "Command exited with code #{exit_code}"
        true -> nil
      end

    %{
      "tool_status" => if(error, do: "error", else: "done"),
      "tool_error" => error,
      "output" => output,
      "details" => Handbean.Agent.Tool.ResultContract.project_details(metadata) || %{},
      "consumption" => "pending",
      "agent_response_status" => "pending",
      "tool_duration_ms" => duration,
      "completed_at" => now_iso8601()
    }
  end

  defp terminal_patch({:error, reason, metadata}, duration) when is_map(metadata) do
    terminal_patch({:error, reason}, duration)
    |> Map.put("details", Handbean.Agent.Tool.ResultContract.project_details(metadata) || %{})
  end

  defp terminal_patch({:error, reason}, duration) do
    %{
      "tool_status" => "error",
      "tool_error" => error_text(reason),
      "output" => nil,
      "consumption" => "pending",
      "agent_response_status" => "pending",
      "tool_duration_ms" => duration,
      "completed_at" => now_iso8601()
    }
  end

  defp terminal_patch(other, duration),
    do: terminal_patch({:error, "Unexpected command result: #{inspect(other)}"}, duration)

  defp persisted_command({:extension, name, args}), do: %{"name" => name, "arguments" => args}
  defp persisted_command(command), do: command
  defp command_label({:extension, name, args}), do: String.trim_trailing(name <> " " <> args)
  defp command_label(command), do: "!" <> command
  defp command_name({:extension, name, _args}), do: name
  defp command_name(_command), do: "bash"

  defp start_entries(_conversation_id, command, operation_id, source) do
    timestamp = now_iso8601()
    source = to_string(source)

    [
      %{
        "id" => user_entry_id(operation_id),
        "content_type" => "user_msg",
        "message_type" => "user",
        "role" => "user",
        "direction" => "inbound",
        "content" => command_label(command),
        "direct_command" => true,
        "command_operation_id" => operation_id,
        "source" => source,
        "created_at" => timestamp
      },
      %{
        "id" => tool_entry_id(operation_id),
        "content_type" => "tool",
        "message_type" => "tool",
        "role" => "tool",
        "direction" => "internal",
        "tool_use_id" => operation_id,
        "tool_name" => command_name(command),
        "tool_status" => "running",
        "input" => %{"command" => persisted_command(command)},
        "tool_input_summary" => command_label(command),
        "direct_command" => true,
        "command_operation_id" => operation_id,
        "source" => source,
        "started_at" => timestamp,
        "created_at" => timestamp
      }
    ]
  end

  defp existing_entries(conversation_id, operation_id) do
    reload_entries(conversation_id, operation_id)
  end

  defp reload_entries(conversation_id, operation_id) do
    ids = MapSet.new([user_entry_id(operation_id), tool_entry_id(operation_id)])

    case ConversationTranscriptStore.list(conversation_id) do
      {:ok, entries} -> Enum.filter(entries, &MapSet.member?(ids, &1["id"]))
      {:error, _reason} -> []
    end
  end

  defp acknowledgement(operation_id, entries, state) do
    %{operation_id: operation_id, entries: entries, state: state}
  end

  defp user_entry_id(operation_id), do: "workspace-command-user-#{operation_id}"
  defp tool_entry_id(operation_id), do: "workspace-command-tool-#{operation_id}"

  defp response_still_in_runtime?(conversation_id, entry) do
    case {Handbean.Agent.Coordinator.status(conversation_id),
          response_receipt(conversation_id, entry)} do
      {{:ok, %{running?: true, run_id: run_id}}, {:ok, %{"status" => "completed"} = receipt}}
      when is_binary(run_id) and run_id != "" ->
        receipt_run_id(receipt) == run_id

      _ ->
        false
    end
  end

  defp response_receipt(conversation_id, entry) do
    case entry["agent_response_request_id"] do
      request_id when is_binary(request_id) and request_id != "" ->
        Handbean.Agent.OperationReceipt.lookup({:message, conversation_id}, request_id)

      _ ->
        :error
    end
  end

  defp receipt_run_id(%{"receipt" => receipt}) when is_map(receipt) do
    Handbean.Utils.SafeMap.get_any(receipt, "run_id", :run_id)
  end

  defp receipt_run_id(_receipt), do: nil

  defp recover_submission(conversation_id, operation_id) do
    case reload_entries(conversation_id, operation_id) do
      [_, _] = entries -> {:ok, acknowledgement(operation_id, entries, :existing)}
      _ -> {:error, :not_available}
    end
  end

  defp deliver_agent_response(conversation_id, entry, responder) do
    attempt_id = response_attempt_id(conversation_id, entry)

    case safe_claim_agent_response(conversation_id, entry["id"], attempt_id) do
      {:ok, attempted_entry} ->
        persist_agent_response_result(
          conversation_id,
          attempted_entry,
          safe_respond(responder, conversation_id, attempted_entry)
        )

      {:error, :already_consumed} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[WorkspaceCommand] Agent response attempt was not persisted entry=#{entry["id"]}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp response_attempt_id(conversation_id, entry) do
    case entry["agent_response_request_id"] do
      request_id when is_binary(request_id) and request_id != "" ->
        case response_receipt(conversation_id, entry) do
          {:ok, %{"status" => "completed"}} -> new_response_attempt_id(entry)
          _ -> request_id
        end

      _ ->
        new_response_attempt_id(entry)
    end
  end

  defp new_response_attempt_id(entry) do
    "workspace-command-response-#{entry["command_operation_id"] || entry["id"]}-#{Ecto.UUID.generate()}"
  end

  defp persist_agent_response_result(conversation_id, entry, result) do
    patch =
      case result do
        {:ok, _ack} ->
          %{
            "agent_response_status" => "accepted",
            "agent_response_error" => nil
          }

        {:error, :delivery_unknown} ->
          %{
            "agent_response_status" => "unknown",
            "agent_response_error" => error_text(:delivery_unknown)
          }

        {:error, :idempotency_conflict} ->
          %{
            "agent_response_status" => "failed",
            "agent_response_error" => error_text(:idempotency_conflict)
          }

        {:error, reason} when reason in @transient_agent_response_errors ->
          %{
            "agent_response_status" => "pending",
            "agent_response_error" => error_text(reason)
          }

        {:error, reason} ->
          %{
            "agent_response_status" => "failed",
            "agent_response_error" => error_text(reason)
          }

        other ->
          %{
            "agent_response_status" => "failed",
            "agent_response_error" => "Unexpected Agent response result: #{inspect(other)}"
          }
      end

    case safe_transcript_update(conversation_id, entry["id"], patch) do
      {:ok, updated} ->
        broadcast_updated(conversation_id, updated)
        :ok

      {:error, reason} ->
        Logger.warning(
          "[WorkspaceCommand] Agent response status was not persisted entry=#{entry["id"]}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp safe_claim_agent_response(conversation_id, entry_id, attempt_id) do
    ConversationTranscriptStore.claim_workspace_command_response(
      conversation_id,
      entry_id,
      attempt_id
    )
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_transcript_update(conversation_id, entry_id, patch) do
    ConversationTranscriptStore.update(conversation_id, entry_id, patch)
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_respond(responder, conversation_id, entry) do
    responder.(conversation_id, entry)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp schedule_agent_response_recovery do
    if Keyword.get(Application.get_env(:handbean, __MODULE__, []), :response_recovery?, true) do
      Process.send_after(self(), :recover_agent_responses, @response_retry_ms)
    end
  end

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: inspect(reason)

  defp worker_error(:normal), do: "Command worker ended before returning a result"
  defp worker_error(:shutdown), do: interrupted_text()
  defp worker_error(reason), do: "Command worker stopped: #{inspect(reason)}"

  defp interrupted_text,
    do: "Host stopped before the command completed; side effects may already have occurred"

  defp broadcast_updated(conversation_id) do
    Handbean.ConversationStore.broadcast_updated(conversation_id)
  end

  defp broadcast_updated(conversation_id, entry) do
    Handbean.ConversationStore.broadcast_updated(conversation_id, entry)
  end

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
