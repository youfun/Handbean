defmodule Handbean.Agent.OperationReceipt do
  @moduledoc """
  Durable reservation and receipt for one user operation.

  Receipts are stored in `Handbean.Repo`. `request_id` is an operation id, not
  a conversation or run id. The same id and fingerprint returns the stored
  receipt. The same id with different content is `:idempotency_conflict`.
  Concurrent reserves of a new id accept one writer; any replay of a pending
  reservation changes it to `unknown` so a possibly completed side effect is
  never run automatically again.

  This is not exactly-once. A local timeout does not prove the remote side did
  not act.
  """

  import Ecto.Query

  alias Handbean.Repo
  alias Handbean.Storage.OperationReceipt, as: StoredReceipt

  def reserve(scope, request_id, fingerprint, opts \\ [])

  def reserve(_scope, request_id, _fingerprint, _opts) when request_id in [nil, ""], do: :ok

  def reserve(scope, request_id, fingerprint, _opts) when is_binary(request_id) do
    key = key(scope, request_id)

    case fetch(key) do
      nil -> insert_reservation(key, fingerprint)
      receipt -> reserve_existing(receipt, fingerprint, false)
    end
  end

  def complete(scope, request_id, receipt, opts \\ [])

  def complete(_scope, request_id, _receipt, _opts) when request_id in [nil, ""], do: :ok

  def complete(scope, request_id, receipt, _opts)
      when is_binary(request_id) and is_map(receipt) do
    mutate(scope, request_id, "completed", receipt)
  end

  @doc """
  Drop a reservation that never started work.

  Succeeds only when the record is still `reserved` and the fingerprint matches.
  A missing, unknown, completed, or conflicting record is not released.
  """
  def release_reserved(scope, request_id, fingerprint, opts \\ [])

  def release_reserved(_scope, request_id, _fingerprint, _opts) when request_id in [nil, ""],
    do: :ok

  def release_reserved(scope, request_id, fingerprint, _opts) when is_binary(request_id) do
    key = key(scope, request_id)

    Repo.transaction(fn ->
      case fetch(key) do
        %StoredReceipt{fingerprint: ^fingerprint, status: "reserved"} ->
          case receipt_write_fault() do
            :ok ->
              case Repo.delete_all(reserved_query(key, fingerprint)) do
                {1, _} -> :ok
                {0, _} -> release_failure(key, fingerprint)
              end

            {:error, _reason} = error ->
              error
          end

        %StoredReceipt{fingerprint: other} when other != fingerprint ->
          {:error, :idempotency_conflict}

        _ ->
          {:error, :not_reserved}
      end
    end)
    |> transaction_result()
  end

  def mark_unknown(scope, request_id, opts \\ [])

  def mark_unknown(_scope, request_id, _opts) when request_id in [nil, ""], do: :ok

  def mark_unknown(scope, request_id, _opts) when is_binary(request_id) do
    mutate(scope, request_id, "unknown", nil)
  end

  def lookup(scope, request_id, opts \\ []) when is_binary(request_id) do
    _ = opts

    case scope |> key(request_id) |> fetch() do
      nil -> :error
      receipt -> {:ok, public_record(receipt)}
    end
  end

  def fingerprint(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)
  end

  defp insert_reservation(key, fingerprint) do
    ensure_write!()

    Repo.transaction(fn ->
      now = DateTime.utc_now()

      attrs =
        key
        |> Map.merge(%{
          fingerprint: fingerprint,
          status: "reserved",
          receipt: nil,
          inserted_at: now,
          updated_at: now
        })

      case Repo.insert_all(StoredReceipt, [attrs],
             on_conflict: :nothing,
             conflict_target: [:scope_kind, :scope_id, :request_id]
           ) do
        {1, _} -> :ok
        {0, _} -> key |> fetch() |> reserve_existing(fingerprint, true)
      end
    end)
    |> transaction_result()
  end

  defp reserve_existing(
         %StoredReceipt{fingerprint: fingerprint, status: "completed"} = receipt,
         fingerprint,
         _fault_checked?
       ) do
    {:replay, receipt.receipt}
  end

  defp reserve_existing(
         %StoredReceipt{fingerprint: fingerprint, status: "unknown"},
         fingerprint,
         _fault_checked?
       ) do
    {:unknown, :delivery_unknown}
  end

  defp reserve_existing(
         %StoredReceipt{fingerprint: fingerprint, status: "reserved"} = receipt,
         fingerprint,
         fault_checked?
       ) do
    unless fault_checked?, do: ensure_write!()

    query =
      from(row in StoredReceipt,
        where:
          row.scope_kind == ^receipt.scope_kind and row.scope_id == ^receipt.scope_id and
            row.request_id == ^receipt.request_id and row.fingerprint == ^fingerprint and
            row.status == "reserved"
      )

    case Repo.update_all(query,
           set: [status: "unknown", receipt: nil, updated_at: DateTime.utc_now()]
         ) do
      {1, _} -> {:unknown, :delivery_unknown}
      {0, _} -> receipt |> record_key() |> fetch() |> reserve_after_race(fingerprint)
    end
  end

  defp reserve_existing(%StoredReceipt{fingerprint: other}, fingerprint, _fault_checked?)
       when other != fingerprint,
       do: {:error, :idempotency_conflict}

  defp reserve_after_race(nil, _fingerprint), do: {:error, :delivery_unknown}

  defp reserve_after_race(receipt, fingerprint),
    do: reserve_existing(receipt, fingerprint, true)

  defp mutate(scope, request_id, status, receipt) do
    key = key(scope, request_id)

    case fetch(key) do
      nil ->
        :ok

      _stored ->
        case receipt_write_fault() do
          :ok ->
            key
            |> key_query()
            |> Repo.update_all(
              set: [status: status, receipt: receipt, updated_at: DateTime.utc_now()]
            )

            :ok

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp release_failure(key, fingerprint) do
    case fetch(key) do
      %StoredReceipt{fingerprint: other} when other != fingerprint ->
        {:error, :idempotency_conflict}

      _ ->
        {:error, :not_reserved}
    end
  end

  defp fetch(key), do: Repo.one(key_query(key))

  defp key_query(%{scope_kind: scope_kind, scope_id: scope_id, request_id: request_id}) do
    from(receipt in StoredReceipt,
      where:
        receipt.scope_kind == ^scope_kind and receipt.scope_id == ^scope_id and
          receipt.request_id == ^request_id
    )
  end

  defp reserved_query(key, fingerprint) do
    from(receipt in key_query(key),
      where: receipt.fingerprint == ^fingerprint and receipt.status == "reserved"
    )
  end

  defp key({kind, scope_id}, request_id) when is_binary(scope_id) do
    %{scope_kind: to_string(kind), scope_id: scope_id, request_id: request_id}
  end

  defp record_key(receipt) do
    %{
      scope_kind: receipt.scope_kind,
      scope_id: receipt.scope_id,
      request_id: receipt.request_id
    }
  end

  defp public_record(receipt) do
    %{
      "request_id" => receipt.request_id,
      "fingerprint" => receipt.fingerprint,
      "status" => receipt.status,
      "receipt" => receipt.receipt
    }
  end

  defp ensure_write! do
    case receipt_write_fault() do
      :ok -> :ok
      {:error, reason} -> raise "operation receipt write failed: #{inspect(reason)}"
    end
  end

  defp receipt_write_fault do
    case Application.get_env(:handbean, :operation_receipt_write_fault) do
      fun when is_function(fun, 0) ->
        case fun.() do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      _ ->
        :ok
    end
  end

  defp transaction_result({:ok, result}), do: result
  defp transaction_result({:error, reason}), do: {:error, reason}
end
