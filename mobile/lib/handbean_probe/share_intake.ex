defmodule HandbeanProbe.ShareIntake do
  @moduledoc """
  Reads app-private share intake manifests. Kotlin owns URI copy; this module
  owns review list, merge, send-ack, and cleanup.
  """

  alias Handbean.Attachments
  alias Handbean.Security.PathValidator
  alias HandbeanProbe.Bridge.Payload
  alias HandbeanProbe.ShareCopy
  alias HandbeanProbe.ShareIntake.Lock

  @max_pending 8
  @review_states ~w(pending_review failed outcome_unknown)
  @terminal_states ~w(cancelled acknowledged)
  @uuid_re ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  def max_pending, do: @max_pending

  def root do
    Application.get_env(:handbean_probe, :share_intake_root) ||
      Path.join(Handbean.Host.data_dir(), "share_intake")
  end

  def receipts_root, do: Path.join(root(), "receipts")

  @spec list_review(keyword()) :: [map()]
  def list_review(opts \\ []) do
    limit = Keyword.get(opts, :limit, @max_pending)

    list_manifests()
    |> Enum.filter(fn rec -> rec["state"] in @review_states end)
    |> Enum.sort_by(&fifo_key/1, :asc)
    |> Enum.take(limit)
  end

  @spec restore_visible(keyword()) :: [map()]
  def restore_visible(opts \\ []) do
    _ = ShareCopy.reconcile(opts)
    list_review()
  end

  def list_confirming do
    list_manifests()
    |> Enum.filter(&(&1["state"] == "confirming"))
  end

  def list_copy_unresolved do
    list_manifests()
    |> Enum.filter(&(&1["state"] in ~w(confirming rolling_back)))
  end

  def busy?(intake_id) when is_binary(intake_id) do
    case get(intake_id) do
      {:ok, rec} ->
        rec["state"] == "rolling_back" or
          rec["copy_status"] in ~w(running ok rollback_failed) or
          rec["awaiting_ack"] == true

      _ ->
        false
    end
  end

  def terminal?(intake_id) when is_binary(intake_id) do
    case receipt(intake_id) do
      {:ok, rec} ->
        rec["state"] in @terminal_states

      _ ->
        case get(intake_id) do
          {:ok, rec} -> rec["state"] in @terminal_states
          _ -> false
        end
    end
  end

  def receipt(intake_id) when is_binary(intake_id) do
    with {:ok, id} <- cast_id(intake_id),
         {:ok, body} <- File.read(receipt_path(id)),
         {:ok, rec} <- Handbean.JSON.decode(body) do
      {:ok, rec}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get(String.t()) :: {:ok, map()} | {:error, term()}
  def get(intake_id) when is_binary(intake_id) do
    with {:ok, id} <- cast_id(intake_id),
         {:ok, body} <- File.read(manifest_path(id)),
         {:ok, rec} <- Handbean.JSON.decode(body) do
      {:ok, rec}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reviewability guard for a user confirmation. Read-only: returns the manifest
  when it is in a review state, otherwise `{:error, :not_reviewable}`.

  The state transition that makes a confirmation durable lives in
  `HandbeanProbe.ShareConfirm.begin/2` (`mark_confirming/2` for workspace copy,
  `mark_merged/1` for structured attachments). Callers must not treat a
  `{:ok, rec}` from this function as a confirmed intake.
  """
  @spec confirm(String.t()) :: {:ok, map()} | {:error, term()}
  def confirm(intake_id) when is_binary(intake_id) do
    with {:ok, rec} <- get(intake_id) do
      if rec["state"] in @review_states do
        {:ok, rec}
      else
        {:error, :not_reviewable}
      end
    end
  end

  def list_send_pending do
    list_manifests()
    |> Enum.filter(&(&1["state"] == "send_pending"))
  end

  @spec mark_merged(String.t()) :: :ok | {:error, term()}
  def mark_merged(intake_id), do: put_state(intake_id, "merged_current_process")

  @spec mark_confirming(String.t(), map()) :: :ok | {:error, term()}
  def mark_confirming(intake_id, rec \\ %{}) when is_binary(intake_id) do
    transact(intake_id, fn ->
      with {:ok, current} <- get(intake_id),
           :ok <- reject_busy_or_terminal(current) do
        extras =
          Map.take(rec, ["workspace_path", "workspace_id", "conversation_id", "copy_status"])

        do_write(
          intake_id,
          current
          |> Map.merge(extras)
          |> Map.put("state", "confirming")
        )
      end
    end)
  end

  def mark_copy_running(intake_id, target) when is_binary(intake_id) and is_map(target) do
    transact(intake_id, fn ->
      with {:ok, current} <- get(intake_id),
           :ok <- reject_busy_or_terminal(current) do
        do_write(
          intake_id,
          current
          |> Map.merge(Map.take(target, ["workspace_path", "workspace_id", "conversation_id"]))
          |> Map.put("state", "confirming")
          |> Map.put("copy_status", "running")
          |> Map.delete("awaiting_ack")
        )
      end
    end)
  end

  def mark_copy_outcome(intake_id, result) when is_binary(intake_id) do
    transact(intake_id, fn ->
      with {:ok, current} <- get(intake_id),
           :ok <- reject_terminal(current) do
        {status, extra} =
          case result do
            {:ok, paths} -> {"ok", %{"copy_paths" => paths}}
            {:error, reason} -> {"error", %{"copy_error" => inspect(reason)}}
          end

        do_write(intake_id, current |> Map.merge(extra) |> Map.put("copy_status", status))
      end
    end)
  end

  def mark_awaiting_ack(intake_id) when is_binary(intake_id) do
    transact(intake_id, fn ->
      with {:ok, current} <- get(intake_id),
           :ok <- reject_terminal(current) do
        do_write(intake_id, Map.put(current, "awaiting_ack", true))
      end
    end)
  end

  def mark_rolling_back(intake_id) when is_binary(intake_id) do
    transact(intake_id, fn ->
      with {:ok, current} <- get(intake_id),
           :ok <- reject_terminal(current) do
        do_write(
          intake_id,
          current
          |> Map.put("state", "rolling_back")
          |> Map.put("copy_status", "rolling_back")
          |> Map.delete("awaiting_ack")
        )
      end
    end)
  end

  def mark_rollback_failed(intake_id) when is_binary(intake_id) do
    transact(intake_id, fn ->
      with {:ok, current} <- get(intake_id),
           :ok <- reject_terminal(current) do
        do_write(
          intake_id,
          current
          |> Map.put("state", "rolling_back")
          |> Map.put("copy_status", "rollback_failed")
        )
      end
    end)
  end

  @spec cancel(String.t()) :: :ok | {:error, term()}
  def cancel(intake_id) when is_binary(intake_id) do
    transact(intake_id, fn ->
      with {:ok, rec} <- get(intake_id) do
        case do_write(intake_id, Map.put(rec, "state", "cancelled")) do
          :ok -> write_receipt(intake_id, "cancelled")
          other -> other
        end
      end
    end)
  end

  @spec schedule_cleanup(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def schedule_cleanup(intake_id, opts \\ []) when is_binary(intake_id) do
    supervisor = Keyword.get(opts, :supervisor, HandbeanProbe.TaskSupervisor)

    Task.Supervisor.start_child(supervisor, fn ->
      result = cleanup_retry(intake_id, opts)
      Enum.each(notify_pids(opts), &send(&1, {:share_cleanup, intake_id, result}))
      result
    end)
  end

  @spec cleanup_retry(String.t(), keyword()) :: :ok | {:error, term()}
  def cleanup_retry(intake_id, opts \\ []) when is_binary(intake_id) do
    attempts = Keyword.get(opts, :attempts, 3)
    rm = Keyword.get(opts, :rm, &default_rm/1)
    do_cleanup_retry(intake_id, rm, attempts)
  end

  @spec return_to_review(String.t()) :: :ok | {:error, term()}
  def return_to_review(intake_id) do
    transact(intake_id, fn ->
      cond do
        terminal?(intake_id) ->
          {:error, :terminal}

        true ->
          with {:ok, rec} <- get(intake_id),
               :ok <- reject_terminal(rec) do
            do_write(
              intake_id,
              rec
              |> Map.put("state", "pending_review")
              |> Map.drop(["copy_status", "copy_error", "copy_paths", "awaiting_ack"])
            )
          end
      end
    end)
  end

  @spec mark_send_pending(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def mark_send_pending(intake_id, inbound_id, conversation_id)
      when is_binary(intake_id) and is_binary(inbound_id) do
    transact(intake_id, fn ->
      with {:ok, rec} <- get(intake_id) do
        do_write(
          intake_id,
          rec
          |> Map.put("state", "send_pending")
          |> Map.put("send_attempt_id", inbound_id)
          |> Map.put("conversation_id", conversation_id)
        )
      end
    end)
  end

  @spec acknowledge(String.t()) :: :ok | {:error, term()}
  def acknowledge(intake_id) when is_binary(intake_id) do
    transact(intake_id, fn ->
      case get(intake_id) do
        {:ok, rec} ->
          case do_write(intake_id, Map.put(rec, "state", "acknowledged")) do
            :ok ->
              case write_receipt(intake_id, "acknowledged") do
                :ok ->
                  _ = schedule_cleanup(intake_id)
                  :ok

                {:error, reason} ->
                  {:error, reason}
              end

            other ->
              other
          end

        other ->
          other
      end
    end)
  end

  @spec revert_send(String.t()) :: :ok | {:error, term()}
  def revert_send(intake_id) do
    put_state(intake_id, "merged_current_process")
  end

  @spec mark_outcome_unknown(String.t()) :: :ok | {:error, term()}
  def mark_outcome_unknown(intake_id), do: put_state(intake_id, "outcome_unknown")

  @spec reconcile_send(map()) :: :acknowledged | :outcome_unknown | :pending
  def reconcile_send(%{"state" => "send_pending"} = rec) do
    conversation_id = rec["conversation_id"]
    inbound_id = rec["send_attempt_id"]

    cond do
      is_binary(conversation_id) and is_binary(inbound_id) and
          Attachments.inbound_ack(conversation_id, inbound_id) == :acknowledged ->
        _ = acknowledge(rec["intake_id"])
        :acknowledged

      true ->
        _ = mark_outcome_unknown(rec["intake_id"])
        :outcome_unknown
    end
  end

  def reconcile_send(_), do: :pending

  @spec discard(String.t(), keyword()) :: :ok | {:error, term()}
  def discard(intake_id, opts \\ []) when is_binary(intake_id) do
    rm = Keyword.get(opts, :rm, &default_rm/1)

    transact(intake_id, fn ->
      with {:ok, id} <- cast_id(intake_id),
           :ok <- persist_terminal_receipt(id) do
        dir = Path.expand(Path.join(root(), id))

        case PathValidator.validate_within_workspace(dir, Path.expand(root())) do
          :ok ->
            case rm.(dir) do
              {:ok, _} -> :ok
              :ok -> :ok
              {:error, reason, _} -> {:error, reason}
              {:error, reason} -> {:error, reason}
            end

          {:error, _} ->
            {:error, :outside_intake_root}
        end
      end
    end)
  end

  def append_share_text(current, added) do
    current = current || ""
    added = added || ""

    cond do
      String.trim(added) == "" -> current
      String.trim(current) == "" -> added
      true -> current <> "\n\n" <> added
    end
  end

  def compose_text(rec) when is_map(rec) do
    [rec["subject"], rec["text"]]
    |> Enum.map(&String.trim(to_string(&1 || "")))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.join("\n\n")
  end

  def write_receipt(intake_id, state) when is_binary(intake_id) and is_binary(state) do
    case Application.get_env(:handbean_probe, :share_receipt_write) do
      fun when is_function(fun, 2) -> fun.(intake_id, state)
      _ -> do_write_receipt(intake_id, state)
    end
  end

  def write(intake_id, rec) when is_binary(intake_id) and is_map(rec) do
    transact(intake_id, fn -> do_write(intake_id, rec) end)
  end

  # created_at survives process death; created_seq may reset in memory.
  defp fifo_key(rec) do
    {Payload.first(rec, ["created_at", "updated_at"]) || 0, rec["created_seq"] || 0}
  end

  defp transact(intake_id, fun), do: Lock.run(intake_id, fun)

  defp do_write_receipt(intake_id, state) do
    with {:ok, id} <- cast_id(intake_id) do
      dir = receipts_root()
      path = receipt_path(id)
      partial = path <> ".partial"
      body =
        Handbean.JSON.encode!(%{"intake_id" => id, "state" => state, "terminal" => true})

      case File.mkdir_p(dir) do
        :ok ->
          case File.write(partial, body) do
            :ok ->
              case File.rename(partial, path) do
                :ok ->
                  :ok

                {:error, reason} ->
                  _ = File.rm(partial)
                  {:error, reason}
              end

            {:error, reason} ->
              _ = File.rm(partial)
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_write(intake_id, rec) when is_binary(intake_id) and is_map(rec) do
    with {:ok, id} <- cast_id(intake_id),
         :ok <- reject_blind_resurrect(id, rec) do
      dir = Path.join(root(), id)
      path = Path.join(dir, "manifest.json")
      partial = path <> ".partial"
      body =
        Handbean.JSON.encode!(Map.put(rec, "updated_at", System.system_time(:millisecond)))

      case File.mkdir_p(dir) do
        :ok ->
          case File.write(partial, body) do
            :ok ->
              case File.rename(partial, path) do
                :ok ->
                  :ok

                {:error, reason} ->
                  _ = File.rm(partial)
                  {:error, reason}
              end

            {:error, reason} ->
              _ = File.rm(partial)
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp reject_terminal(rec) do
    if rec["state"] in @terminal_states do
      {:error, :terminal}
    else
      :ok
    end
  end

  defp reject_busy_or_terminal(rec) do
    cond do
      rec["state"] in @terminal_states -> {:error, :terminal}
      rec["state"] == "rolling_back" -> {:error, :busy}
      rec["copy_status"] in ~w(running ok rollback_failed) -> {:error, :busy}
      rec["awaiting_ack"] == true -> {:error, :busy}
      true -> :ok
    end
  end

  defp reject_blind_resurrect(id, rec) do
    next = rec["state"]

    cond do
      terminal?(id) and next not in @terminal_states ->
        {:error, :terminal}

      true ->
        :ok
    end
  end

  defp persist_terminal_receipt(id) do
    case receipt(id) do
      {:ok, rec} ->
        if rec["state"] in @terminal_states, do: :ok, else: {:error, :invalid_receipt}

      _ ->
        case get(id) do
          {:ok, %{"state" => state}} when state in @terminal_states ->
            write_receipt(id, state)

          {:ok, _} ->
            write_receipt(id, "cancelled")

          {:error, :not_found} ->
            {:error, :missing_receipt}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp receipt_path(id), do: Path.join(receipts_root(), id <> ".json")

  defp notify_pids(opts) do
    [Keyword.get(opts, :notify), Application.get_env(:handbean_probe, :share_io_notify)]
    |> Enum.filter(&(is_pid(&1) and Process.alive?(&1)))
    |> Enum.uniq()
  end

  defp do_cleanup_retry(intake_id, rm, attempts) when attempts > 1 do
    case discard(intake_id, rm: rm) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, _} -> do_cleanup_retry(intake_id, rm, attempts - 1)
    end
  end

  defp do_cleanup_retry(intake_id, rm, _attempts) do
    case discard(intake_id, rm: rm) do
      {:error, :not_found} -> :ok
      other -> other
    end
  end

  defp default_rm(dir) do
    case File.rm_rf(dir) do
      {:ok, _} -> :ok
      {:error, reason, _} -> {:error, reason}
    end
  end

  defp put_state(intake_id, state) do
    transact(intake_id, fn ->
      with {:ok, rec} <- get(intake_id),
           :ok <- reject_terminal(rec) do
        do_write(intake_id, Map.put(rec, "state", state))
      end
    end)
  end

  defp list_manifests do
    case File.ls(root()) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          case get(name) do
            {:ok, rec} -> [Map.put(rec, "intake_id", rec["intake_id"] || name)]
            {:error, _} -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp manifest_path(intake_id), do: Path.join([root(), intake_id, "manifest.json"])

  defp cast_id(intake_id) when is_binary(intake_id) do
    if Regex.match?(@uuid_re, intake_id) do
      {:ok, intake_id}
    else
      {:error, :invalid_intake_id}
    end
  end
end
