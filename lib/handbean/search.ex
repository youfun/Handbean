defmodule Handbean.Search do
  @moduledoc """
  Entry point for workspace file inventory and fuzzy path search.

  Starting an inventory is asynchronous. Searches return the paths indexed so
  far and expose `status: :indexing` until the background scan completes.
  """

  @default_backend Handbean.Search.ExFffBackend

  def ensure_started(workspace) when is_binary(workspace) do
    backend().ensure_started(workspace)
  end

  def await(index, timeout \\ 5_000) when is_integer(timeout) and timeout > 0 do
    backend().await(index, timeout)
  end

  def search(index, query, opts \\ []) when is_binary(query) and is_list(opts) do
    backend = backend()
    started_at = System.monotonic_time(:millisecond)
    result = backend.search(index, query, opts)
    emit_query_telemetry(backend, result, started_at)
    result
  end

  def files(index, opts \\ []) when is_list(opts) do
    backend().files(index, opts)
  end

  def touch(workspace, path) when is_binary(workspace) and is_binary(path) do
    with {:ok, index} <- ensure_started(workspace) do
      backend().touch(index, path)
    end
  end

  def touch(_workspace, _path), do: :ok

  def notify_path(workspace, path) when is_binary(workspace) and is_binary(path) do
    Handbean.Search.Watcher.notify_path(workspace, path)
  end

  def notify_path(_workspace, _path), do: :ok

  def prewarm(workspace) when is_binary(workspace) do
    case ensure_started(workspace) do
      {:ok, _index} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def prewarm(_workspace), do: :ok

  defp backend do
    Application.get_env(:handbean, :search_backend, @default_backend)
  end

  defp emit_query_telemetry(backend, result, started_at) do
    elapsed = System.monotonic_time(:millisecond) - started_at

    {status, file_count, result_count} =
      case result do
        {:ok, data} ->
          {Map.get(data, :status, :ready), Map.get(data, :indexed_count, 0),
           length(Map.get(data, :paths, []))}

        {:error, _reason} ->
          {:error, 0, 0}
      end

    :telemetry.execute(
      [:handbean, :search, :query],
      %{duration_ms: elapsed, file_count: file_count, result_count: result_count},
      %{backend: backend, status: status}
    )
  end
end
