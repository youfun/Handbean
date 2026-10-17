defmodule Handbean.Agent.Tool.FileCommit do
  @moduledoc """
  Commit one workspace file through a same-directory temp file and a receipt.

  A crash before rename leaves the target untouched. A crash after rename but
  before the receipt is reconciled by the expected SHA: a matching target is
  committed and is not rewritten; a mismatch is unknown and is not overwritten.
  """

  alias Handbean.Agent.OperationReceipt
  alias Handbean.ChangeSnapshot

  @spec commit(String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, String.t(), map()}
  def commit(path, content, context, opts \\ []) do
    path = follow_symlink(path)
    operation_id = Keyword.get(opts, :operation_id) || new_id()
    expected = ChangeSnapshot.sha256(content)
    receipt = %{"path" => path, "after_sha256" => expected, "operation_id" => operation_id}
    fingerprint = OperationReceipt.fingerprint(receipt)

    case reserve(operation_id, fingerprint, context) do
      :ok ->
        commit_reserved(path, content, operation_id, expected, receipt, fingerprint, context)

      {:replay, stored} ->
        {:ok,
         %{
           operation_id: operation_id,
           after_sha256: stored["after_sha256"],
           side_effect: :committed,
           replayed: true
         }}

      {:unknown, _} ->
        reconcile(path, expected, operation_id)

      {:error, reason} ->
        commit_error(operation_id, reason)
    end
  end

  @spec reconcile(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t(), map()}
  def reconcile(path, expected, operation_id) do
    case File.read(path) do
      {:ok, body} ->
        if ChangeSnapshot.sha256(body) == expected do
          {:ok,
           %{
             operation_id: operation_id,
             after_sha256: expected,
             side_effect: :committed,
             reconciled: true
           }}
        else
          {:error, "file commit is unknown and the target does not match; not overwriting",
           %{operation_id: operation_id, side_effect: :unknown, code: :commit_conflict}}
        end

      {:error, :enoent} ->
        {:error, "file commit did not start",
         %{operation_id: operation_id, side_effect: :not_started, code: :commit_not_started}}

      {:error, reason} ->
        {:error, "file commit could not be reconciled: #{inspect(reason)}",
         %{operation_id: operation_id, side_effect: :unknown, code: :commit_unknown}}
    end
  end

  defp commit_reserved(path, content, operation_id, expected, receipt, fingerprint, context) do
    case write_temp(path, content) do
      {:ok, temp} ->
        with :ok <- File.rename(temp, path),
             :ok <- complete(operation_id, receipt, context) do
          {:ok, %{operation_id: operation_id, after_sha256: expected, side_effect: :committed}}
        else
          {:error, reason} ->
            _ = File.rm(temp)
            commit_error(operation_id, reason)
        end

      {:error, reason} ->
        _ = release_reserved(operation_id, fingerprint, context)
        commit_not_started(operation_id, reason)
    end
  end

  defp write_temp(path, content, attempts \\ 3)

  defp write_temp(_path, _content, 0), do: {:error, :eexist}

  defp write_temp(path, content, attempts) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      temp = random_temp_path(path)

      case File.open(temp, [:write, :binary, :exclusive], &IO.binwrite(&1, content)) do
        {:ok, :ok} ->
          {:ok, temp}

        {:ok, {:error, reason}} ->
          _ = File.rm(temp)
          {:error, reason}

        {:error, :eexist} ->
          write_temp(path, content, attempts - 1)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp random_temp_path(path) do
    Path.join(
      Path.dirname(path),
      ".#{Path.basename(path)}.handbean-#{Ecto.UUID.generate()}.tmp"
    )
  end

  defp commit_error(operation_id, reason) do
    {:error, "file commit failed: #{inspect(reason)}",
     %{operation_id: operation_id, side_effect: :unknown, code: :commit_unknown}}
  end

  defp commit_not_started(operation_id, reason) do
    {:error, "file commit failed before rename: #{inspect(reason)}",
     %{operation_id: operation_id, side_effect: :not_started, code: :commit_not_started}}
  end

  defp reserve(operation_id, fingerprint, context) do
    case conversation(context) do
      nil ->
        :ok

      conversation ->
        case OperationReceipt.reserve({:file_commit, conversation}, operation_id, fingerprint) do
          :ok -> :ok
          {:replay, stored} -> {:replay, stored}
          {:unknown, reason} -> {:unknown, reason}
          other -> other
        end
    end
  end

  defp release_reserved(operation_id, fingerprint, context) do
    case conversation(context) do
      nil ->
        :ok

      conversation ->
        OperationReceipt.release_reserved(
          {:file_commit, conversation},
          operation_id,
          fingerprint
        )
    end
  end

  defp complete(operation_id, receipt, context) do
    case conversation(context) do
      nil ->
        :ok

      conversation ->
        OperationReceipt.complete({:file_commit, conversation}, operation_id, receipt)
    end
  end

  defp follow_symlink(path) do
    case File.read_link(path) do
      {:ok, target} ->
        if Path.type(target) == :absolute,
          do: target,
          else: Path.expand(target, Path.dirname(path))

      _ ->
        path
    end
  end

  defp conversation(context),
    do: Handbean.Utils.SafeMap.get_any(context, [:conversation_id, "conversation_id"])

  defp new_id, do: "commit_" <> Integer.to_string(System.unique_integer([:positive]))
end
